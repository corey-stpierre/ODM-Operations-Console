@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
  echo Windows PowerShell was not found: %POWERSHELL%
  pause
  exit /b 1
)
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_DIR%MappingCollisionUtility.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
