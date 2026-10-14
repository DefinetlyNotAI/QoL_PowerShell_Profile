@echo off
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell.exe -NoProfile -Command "Start-Process wt.exe -Verb RunAs -ArgumentList 'cmd.exe /k ""%~f0""'"
    exit /b
)

title Startup Maintenance

echo Running as Administrator...
echo.

echo Running GPG startup script...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Shahm Najeeb\.custom\gpg-startup.ps1"

echo.
echo Updating WinGet sources...
winget source update

echo.
echo Updating all WinGet-managed applications...
winget upgrade --all --silent --accept-source-agreements --accept-package-agreements 2>&1 | findstr /V /C:"have version numbers that cannot be determined"

echo.
echo Startup maintenance complete.

endlocal
exit /b
