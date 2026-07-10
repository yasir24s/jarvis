# JARVIS — fully local, self-hosted installer for Windows 10/11.
# Brain: Ollama.  Voice: Piper.  STT: Google online / Whisper offline.
#
# Run from PowerShell (no admin needed for most steps):
#   Set-ExecutionPolicy -Scope Process Bypass -Force; .\install.ps1
#
# Prerequisites: Python 3.10+ from python.org (with "py" launcher / on PATH).

$ErrorActionPreference = "Stop"
$JarvisDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Model = if ($env:JARVIS_MODEL) { $env:JARVIS_MODEL } else { "qwen2.5:3b" }

$Py = Get-Command python -ErrorAction SilentlyContinue
if (-not $Py) { Write-Host "No python found. Install Python 3 from python.org first."; exit 1 }
Write-Host "Using Python: $($Py.Source)"

Write-Host "> 1/6  Ollama (winget)..."
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    winget install --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements
}
# ffmpeg is optional — only used for the deeper voice-pitch effect
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    try { winget install --id Gyan.FFmpeg -e --accept-package-agreements --accept-source-agreements }
    catch { Write-Host "   (ffmpeg skipped — voice pitch effect disabled)" }
}

Write-Host "> 2/6  Python packages..."
python -m pip install --upgrade pip -q
python -m pip install -q SpeechRecognition pyaudio faster-whisper piper-tts pywebview certifi pillow numpy
# audioop was removed from the stdlib in Python 3.13
python -m pip install -q "audioop-lts; python_version >= '3.13'"
Write-Host "   (optional) speaker recognition — pulls torch and is large:"
try { python -m pip install -q resemblyzer } catch { Write-Host "   resemblyzer skipped (speaker-ID disabled)" }
Write-Host "   (optional) screen OCR — also install Tesseract: winget install UB-Mannheim.TesseractOCR"
try { python -m pip install -q pytesseract } catch { }

Write-Host "> 3/6  Start Ollama and pull the local model ($Model)..."
$OllamaApp = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
if (Test-Path $OllamaApp) { Start-Process $OllamaApp } else { Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden }
Start-Sleep 5
ollama pull $Model

Write-Host "> 4/6  Piper voice (British male)..."
$Voices = Join-Path $JarvisDir "voices"
New-Item -ItemType Directory -Force -Path $Voices | Out-Null
$Base = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium"
foreach ($f in "en_GB-alan-medium.onnx", "en_GB-alan-medium.onnx.json") {
    $dest = Join-Path $Voices $f
    if (-not (Test-Path $dest)) { Invoke-WebRequest "$Base/$f" -OutFile $dest }
}

Write-Host "> 5/6  Cache offline Whisper model..."
python -c "from faster_whisper import WhisperModel; WhisperModel('base.en', device='cpu', compute_type='int8')"

Write-Host "> 6/6  Install auto-start (Startup shortcut)..."
New-Item -ItemType Directory -Force -Path (Join-Path $JarvisDir "logs") | Out-Null
$Pythonw = Join-Path (Split-Path $Py.Source) "pythonw.exe"
if (-not (Test-Path $Pythonw)) { $Pythonw = $Py.Source }
$Startup = [Environment]::GetFolderPath("Startup")
$Shell = New-Object -ComObject WScript.Shell
$Lnk = $Shell.CreateShortcut((Join-Path $Startup "JARVIS.lnk"))
$Lnk.TargetPath = $Pythonw
$Lnk.Arguments = "`"$(Join-Path $JarvisDir 'jarvis.py')`""
$Lnk.WorkingDirectory = $JarvisDir
$Lnk.Save()

Write-Host ""
Write-Host "Done. Start JARVIS now with:  .\jarvisctl.ps1 start"
Write-Host "Reminder: allow microphone access for desktop apps in"
Write-Host "Settings > Privacy & security > Microphone."
