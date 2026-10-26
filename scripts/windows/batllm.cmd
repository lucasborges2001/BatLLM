@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem BatLLM Windows entry point. No operation installs or launches anything by default.
rem PowerShell execution policy is scoped to the child process, not changed globally.
set "DOCTOR=%~dp0batllm-doctor.ps1"
set "APPLY=%~dp0batllm-apply.ps1"
rem Pass an explicit repository root to Doctor: PS 5.1 may not resolve
rem $PSScriptRoot in a script parameter default expression under -File.
set "REPO_ROOT=%~dp0..\.."

if "%~1"=="" goto help
if /I "%~1"=="help" goto help
if /I "%~1"=="--help" goto help
if /I "%~1"=="-h" goto help
if /I "%~1"=="/?" goto help
if /I "%~1"=="doctor" goto doctor
if /I "%~1"=="apply" goto apply

goto bad_args

:doctor
shift
set "TARGET=NonLive"
if "%~1"=="" goto doctor_run
if /I "%~1"=="NonLive" goto doctor_nonlive
if /I "%~1"=="Gameplay" goto doctor_gameplay
goto bad_args

:doctor_nonlive
set "TARGET=NonLive"
shift
goto doctor_options

:doctor_gameplay
set "TARGET=Gameplay"
shift
goto doctor_options

:doctor_options
if "%~1"=="" goto doctor_run
if /I "%~1"=="json" goto doctor_json
goto bad_args

:doctor_json
shift
if not "%~1"=="" goto bad_args
if not exist "%DOCTOR%" goto doctor_missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DOCTOR%" -Target "%TARGET%" -RepoRoot "%REPO_ROOT%" -Json
exit /b %ERRORLEVEL%

:doctor_run
if not exist "%DOCTOR%" goto doctor_missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DOCTOR%" -Target "%TARGET%" -RepoRoot "%REPO_ROOT%"
exit /b %ERRORLEVEL%

:apply
shift
set "MODE=NonLive"
if "%~1"=="" goto apply_plan
if /I "%~1"=="NonLive" goto apply_nonlive
if /I "%~1"=="Gameplay" goto apply_gameplay
goto bad_args

:apply_nonlive
set "MODE=NonLive"
shift
goto apply_options

:apply_gameplay
set "MODE=Gameplay"
shift
goto apply_options

:apply_options
if "%~1"=="" goto apply_plan
if /I "%~1"=="plan" goto apply_explicit_plan
if /I "%~1"=="execute" goto apply_execute
goto bad_args

:apply_explicit_plan
shift
if not "%~1"=="" goto bad_args
goto apply_plan

:apply_plan
if not exist "%APPLY%" goto apply_missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APPLY%" -Mode "%MODE%"
exit /b %ERRORLEVEL%

:apply_execute
shift
if not "%~1"=="" goto bad_args
if not exist "%APPLY%" goto apply_missing
echo Applying %MODE% setup explicitly. Existing environments may be changed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APPLY%" -Mode "%MODE%" -Apply
exit /b %ERRORLEVEL%

:doctor_missing
>&2 echo ERROR: Missing Windows Doctor script: "%DOCTOR%"
exit /b 3

:apply_missing
>&2 echo ERROR: Missing Windows Apply script: "%APPLY%"
exit /b 3

:bad_args
>&2 echo ERROR: Invalid arguments.
>&2 echo Run batllm.cmd help for supported commands.
exit /b 2

:help
echo BatLLM Windows launcher
 echo.
echo Usage:
echo   batllm.cmd help
 echo   batllm.cmd doctor [NonLive^|Gameplay] [json]
 echo   batllm.cmd apply [NonLive^|Gameplay] [plan^|execute]
 echo.
echo Safety:
echo   No arguments show this help. Doctor reads the environment only.
echo   Apply defaults to plan mode and makes no changes.
echo   'execute' explicitly permits Apply to prepare Python dependencies and state.
echo   This launcher never installs Ollama, starts it, pulls a model or launches the game.
echo   Use the existing PowerShell Apply script separately for those opt-in operations.
echo   No global PowerShell execution-policy changes are made.
exit /b 0
