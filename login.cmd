@echo off
if not exist "%~dp0CampusAutoLogin.exe" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1"
  if errorlevel 1 (
    pause
    exit /b 1
  )
)
start "" "%~dp0CampusAutoLogin.exe"
