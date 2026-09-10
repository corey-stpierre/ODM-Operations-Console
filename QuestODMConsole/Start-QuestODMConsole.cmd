@echo off
setlocal EnableExtensions
if defined ProgramW6432 (set "QODM_PROGRAMFILES64=%ProgramW6432%") else (set "QODM_PROGRAMFILES64=%ProgramFiles%")
set "PSEXE="

rem Prefer 64-bit Windows PowerShell 5.1 for the Quest OdmApi module and WPF.
if defined PROCESSOR_ARCHITEW6432 if exist "%WINDIR%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%WINDIR%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSEXE if exist "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSEXE if exist "%QODM_PROGRAMFILES64%\PowerShell\7\pwsh.exe" set "PSEXE=%QODM_PROGRAMFILES64%\PowerShell\7\pwsh.exe"

if not defined PSEXE (
    echo Quest ODM Operations Console could not find a supported 64-bit PowerShell host.
    echo Install PowerShell 7 or repair Windows PowerShell 5.1.
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
