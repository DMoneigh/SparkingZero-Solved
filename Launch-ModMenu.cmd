@echo off
powershell.exe -NoProfile -STA -File "%~dp0native\Start-ModMenu.ps1"
if errorlevel 1 pause
