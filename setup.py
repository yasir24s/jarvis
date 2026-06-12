"""
py2app build config for JARVIS.

Build (alias mode — fast, uses the existing interpreter + installed packages):
    python3 setup.py py2app -A

The resulting dist/jarvis.app runs as bundle id `com.jarvis.assistant` with an
embedded interpreter context, so macOS attributes microphone access to JARVIS
(not raw Python) and lists "JARVIS" in System Settings > Privacy > Microphone.
"""
from setuptools import setup

APP = ["jarvis.py"]

OPTIONS = {
    "argv_emulation": False,
    "plist": {
        "CFBundleName": "JARVIS",
        "CFBundleDisplayName": "JARVIS",
        "CFBundleIdentifier": "com.jarvis.assistant",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1.0",
        "LSMinimumSystemVersion": "11.0",
        "NSMicrophoneUsageDescription":
            "JARVIS listens for your voice commands so it can respond and control your Mac.",
        "NSSpeechRecognitionUsageDescription":
            "JARVIS transcribes your spoken commands.",
    },
}

setup(
    app=APP,
    name="JARVIS",
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
