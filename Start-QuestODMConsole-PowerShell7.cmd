@echo off
setlocal EnableExtensions
if defined ProgramW6432 (set "QODM_PROGRAMFILES64=%ProgramW6432%") else (set "QODM_PROGRAMFILES64=%ProgramFiles%")
set "PSEXE="

if exist "%QODM_PROGRAMFILES64%\PowerShell\7\pwsh.exe" set "PSEXE=%QODM_PROGRAMFILES64%\PowerShell\7\pwsh.exe"
if not defined PSEXE for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PSEXE set "PSEXE=%%I"

if not defined PSEXE (
    echo 64-bit PowerShell 7 was not found.
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
