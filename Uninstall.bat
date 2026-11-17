@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dlopt.ps1" -Action Uninstall
echo.
pause
