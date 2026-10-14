@echo off
setlocal
rem Previews or applies selected actions of an update plan. Nothing runs without -Apply and a yes per action.
rem   Run-Update.cmd <update-plan.json> -Risk low            preview every low-risk action
rem   Run-Update.cmd <update-plan.json> -Risk low -Apply     run them, asking before each one
rem   Run-Update.cmd <update-plan.json> -Action 3,7 -Apply   run actions 3 and 7
if "%~1"=="" (
    echo Usage: Run-Update.cmd ^<update-plan.json^> [-Action ^<order or id^>[,...]] [-Risk low^|medium] [-Apply]
    echo Without -Apply nothing is changed.
    pause
    exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Update-Workstation.ps1" -Plan %*
if errorlevel 1 (
    echo Update failed or was refused. See the message above.
    pause
    exit /b 1
)
pause
