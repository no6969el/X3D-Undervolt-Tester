@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "SCRIPT=%~dp0Test-UndervoltStability.ps1"
title HEAVY test
where pwsh >nul 2>nul || (echo PowerShell 7 ^(pwsh.exe^) not found. Install: winget install Microsoft.PowerShell ^& pause ^& exit /b 1)
if not exist "%SCRIPT%" (echo Test-UndervoltStability.ps1 not found next to this .bat. ^& pause ^& exit /b 1)
echo Running HEAVY profile...  (extra args after the filename are passed through)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Heavy %*
echo.
pause
