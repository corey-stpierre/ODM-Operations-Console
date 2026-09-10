@echo off
setlocal EnableExtensions
set "PSEXE="

if defined PROCESSOR_ARCHITEW6432 if exist "%WINDIR%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%WINDIR%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSEXE if exist "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not defined PSEXE (
    echo 64-bit Windows PowerShell 5.1 was not found.
    pause
    endlocal & exit /b 1
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0QuestODMConsole.ps1"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
    echo.
    echo Quest ODM Operations Console exited with code %EXITCODE%.
    echo Review the startup dialog for the exact bootstrap log path.
    echo The default per-user log folder is:
    echo   %LOCALAPPDATA%\QuestODMConsole\Logs
    pause
)
endlocal & exit /b %EXITCODE%
