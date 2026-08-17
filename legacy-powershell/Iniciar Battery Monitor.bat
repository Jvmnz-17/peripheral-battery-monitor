@echo off
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0battery-monitor.ps1"
timeout /t 2 /nobreak >nul
start "" "http://localhost:8765/"
