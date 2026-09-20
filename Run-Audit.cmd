@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Audit-Workstation.ps1" -IncludeWingetInventory
pause
