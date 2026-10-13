@echo off
setlocal
rem Compares two audit reports: drag the reference report and then the target report onto this file,
rem or run: Run-Compare.cmd <reference.json> <target.json>
if "%~2"=="" (
    echo Usage: Run-Compare.cmd ^<reference-report.json^> ^<target-report.json^>
    echo Drag the reference report and the target report onto this file, or pass both paths.
    pause
    exit /b 2
)
set "OUT=%~dp0reports\comparison"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Compare-Workstations.ps1" -Reference "%~1" -Target "%~2" -OutputDirectory "%OUT%" > nul
if errorlevel 1 (
    echo Comparison failed.
    pause
    exit /b 1
)
type "%OUT%\comparison.txt"
echo.
echo Structured output: %OUT%\comparison.json
pause
