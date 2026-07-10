# JARVIS control script for Windows — mirror of ./jarvisctl on macOS.
# Usage:  .\jarvisctl.ps1 status|start|restart|stop|logs|test

param([Parameter(Position = 0)][string]$Cmd = "status")

$JarvisDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script = Join-Path $JarvisDir "jarvis.py"
$Log = Join-Path $JarvisDir "logs\jarvis.log"

function Get-JarvisProcess {
    Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
        Where-Object { $_.CommandLine -like "*jarvis.py*" }
}

switch ($Cmd) {
    "status" {
        $p = Get-JarvisProcess
        if ($p) { Write-Host "JARVIS is running (PID $($p.ProcessId))." }
        else    { Write-Host "JARVIS is not running." }
    }
    "start" {
        if (Get-JarvisProcess) { Write-Host "Already running."; break }
        $pyw = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
        if (-not $pyw) { $pyw = (Get-Command python).Source }
        Start-Process $pyw -ArgumentList "`"$Script`"" -WorkingDirectory $JarvisDir -WindowStyle Hidden
        Write-Host "JARVIS started."
    }
    "stop" {
        $p = Get-JarvisProcess
        if ($p) { $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Write-Host "JARVIS stopped." }
        else    { Write-Host "JARVIS is not running." }
    }
    "restart" {
        & $MyInvocation.MyCommand.Path stop
        Start-Sleep 1
        & $MyInvocation.MyCommand.Path start
    }
    "logs" {
        if (Test-Path $Log) { Get-Content $Log -Tail 50 -Wait }
        else { Write-Host "No log file yet at $Log" }
    }
    "test" {
        python "$Script"
    }
    default {
        Write-Host "Usage: .\jarvisctl.ps1 status|start|restart|stop|logs|test"
    }
}
