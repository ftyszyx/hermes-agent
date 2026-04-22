@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "ROOT_DIR=%~dp0"
set "PS_SCRIPT=%ROOT_DIR%scripts\gateway-task.ps1"
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

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
