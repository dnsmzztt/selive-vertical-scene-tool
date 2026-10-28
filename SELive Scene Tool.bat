@echo off
rem Opens the SE.Live Scene Tool window without leaving a console window behind:
rem conhost --headless (Windows 10 1809+ / 11) runs PowerShell with no window at all.
start "" conhost.exe --headless powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0SELive-Vertical-Scene-Tool.ps1"
