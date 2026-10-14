@echo off
setlocal
rem Builds the read-only update plan for an audit report: drag the report onto this file,
rem or run: Run-Plan.cmd <report.json>
if "%~1"=="" (
    echo Usage: Run-Plan.cmd ^<audit-report.json^>
    echo Drag an audit report onto this file, or pass its path.
    pause
    exit /b 2
)
set "OUT=%~dp0reports\update-plan"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Plan-WorkstationUpdate.ps1" -Report "%~1" -OutputDirectory "%OUT%" > nul
if errorlevel 1 (
    echo Planning failed.
    pause
    exit /b 1
)
type "%OUT%\update-plan.txt"
echo.
echo Structured output: %OUT%\update-plan.json
pause
