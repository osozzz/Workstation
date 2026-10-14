@echo off
setlocal
rem Evaluates an audit report against config\workstation.policy.json: drag the report onto this file,
rem or run: Run-Evaluate.cmd <report.json>
if "%~1"=="" (
    echo Usage: Run-Evaluate.cmd ^<audit-report.json^>
    echo Drag an audit report onto this file, or pass its path.
    pause
    exit /b 2
)
set "OUT=%~dp0reports\evaluation"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Evaluate-Workstation.ps1" -Report "%~1" -OutputDirectory "%OUT%" > nul
if errorlevel 1 (
    echo Evaluation failed.
    pause
    exit /b 1
)
type "%OUT%\evaluation.txt"
echo.
echo Structured output: %OUT%\evaluation.json
pause
