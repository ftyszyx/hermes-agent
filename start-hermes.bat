@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "ROOT_DIR=%~dp0"
set "PS_SCRIPT=%ROOT_DIR%scripts\start-windows.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS_SCRIPT%" (
    echo [ERROR] Cannot find "%PS_SCRIPT%".
    echo Please run this script from the Hermes repository root.
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
    echo [ERROR] Windows PowerShell was not found.
    exit /b 1
)

if "%~1"=="" goto run_default

if /I "%~1"=="gateway" (
    set "TARGET_MODE=gateway"
    shift
    goto run_mode
)

if /I "%~1"=="dashboard" (
    set "TARGET_MODE=dashboard"
    shift
    goto run_mode
)

if /I "%~1"=="setup" (
    set "TARGET_MODE=setup"
    shift
    goto run_mode
)

if /I "%~1"=="doctor" (
    set "TARGET_MODE=doctor"
    shift
    goto run_mode
)

if /I "%~1"=="model" (
    set "TARGET_MODE=model"
    shift
    goto run_mode
)

if /I "%~1"=="config" (
    set "TARGET_MODE=config"
    shift
    goto run_mode
)

if /I "%~1"=="custom" (
    set "TARGET_MODE=custom"
    shift
    goto run_mode
)

echo [INFO] Unknown mode "%~1", forwarding as custom Hermes arguments.
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode custom %*
exit /b %ERRORLEVEL%

:run_default
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
exit /b %ERRORLEVEL%

:run_mode
setlocal EnableDelayedExpansion
set "FORWARD_ARGS="

:run_mode_loop
if "%~1"=="" goto run_mode_exec
set "FORWARD_ARGS=!FORWARD_ARGS! "%~1""
shift
goto run_mode_loop

:run_mode_exec
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode %TARGET_MODE% !FORWARD_ARGS!
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%
