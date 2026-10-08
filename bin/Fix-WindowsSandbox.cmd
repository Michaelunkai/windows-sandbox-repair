@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "PROJECT_DIR=%SCRIPT_DIR%.."
set "REPAIR_SCRIPT=%PROJECT_DIR%\src\Repair-WindowsSandbox.ps1"

if not exist "%REPAIR_SCRIPT%" (
  echo Missing repair script: "%REPAIR_SCRIPT%"
  exit /b 2
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%REPAIR_SCRIPT%" %*
exit /b %ERRORLEVEL%
