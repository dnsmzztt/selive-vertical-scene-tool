@echo off
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0SELive-Vertical-Scene-Tool.ps1"
if errorlevel 1 pause
