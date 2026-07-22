@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "SCRIPT=%~dp0Test-UndervoltStability.ps1"

where pwsh >nul 2>nul || (
  echo.
  echo PowerShell 7 ^(pwsh.exe^) was not found.
  echo Install it with:  winget install Microsoft.PowerShell
  echo.
  pause & exit /b 1
)
if not exist "%SCRIPT%" (
  echo.
  echo Could not find Test-UndervoltStability.ps1 next to this file.
  echo Put this .bat in the SAME folder as the script.
  echo.
  pause & exit /b 1
)

:menu
cls
echo ==================================================================
echo    X3D Undervolt Stability Tester
echo ==================================================================
echo    1.  BOOST      - max-boost / lowest-voltage corner (idle crashes)
echo    2.  TRANSIENT  - di/dt load-step killer (the nasty one)
echo    3.  HEAVY      - sustained AVX-512, max current
echo    4.  ALL THREE  - full per-core sweep (recommended)
echo    5.  EXTREME    - all + AVX2 mid + period sweep + 2-thread heavy
echo    6.  Exit
echo ==================================================================
echo.
set "choice="
set /p "choice=Select [1-6]: "

if "%choice%"=="1" ( set "ARGS=-Mode Boost"        & goto run )
if "%choice%"=="2" ( set "ARGS=-Mode Transient"    & goto run )
if "%choice%"=="3" ( set "ARGS=-Mode Heavy"        & goto run )
if "%choice%"=="4" ( set "ARGS=-Mode All"          & goto run )
if "%choice%"=="5" ( set "ARGS=-Preset Extreme -Shuffle" & goto run )
if "%choice%"=="6" ( exit /b 0 )
goto menu

:run
echo.
echo Launching:  pwsh %ARGS%
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %ARGS%
echo.
echo ---- test finished ----
pause
goto menu
