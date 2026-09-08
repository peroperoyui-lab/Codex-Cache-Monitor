@echo off
setlocal
set "SCRIPT=%~dp0CodexCacheMonitor.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
endlocal
