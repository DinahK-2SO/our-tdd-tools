@echo off
setlocal

where winget.exe >nul 2>nul
if errorlevel 1 (
    echo winget is required for the one-shot installer.
    echo Install App Installer, or install PowerShell 7, Git, Rustup, Pester, and Microsoft.WinAppCli manually.
    exit /b 1
)

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    winget install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity
    if errorlevel 1 exit /b 1
)

where git.exe >nul 2>nul
if errorlevel 1 (
    winget install --id Git.Git --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity
    if errorlevel 1 exit /b 1
)

where cargo.exe >nul 2>nul
if errorlevel 1 (
    winget install --id Rustlang.Rustup --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity
    if errorlevel 1 exit /b 1
)

set "PATH=%ProgramFiles%\PowerShell\7;%ProgramFiles%\Git\cmd;%USERPROFILE%\.cargo\bin;%PATH%"
set "PWSH="
where pwsh.exe >nul 2>nul && set "PWSH=pwsh.exe"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH (
    echo PowerShell 7 was installed but is not yet available. Open a new terminal and rerun this script.
    exit /b 1
)

"%PWSH%" -NoProfile -File "%~dp0bootstrap.ps1"
exit /b %errorlevel%