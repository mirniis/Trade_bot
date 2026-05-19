@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0"
set "USE_DOCKER=0"
set "SKIP_UI_BUILD=0"
set "APP_ENV=local"
set "INSTALL_DOCKER=0"
set "CLEAN_INSTALL=0"

:parse_args
if "%~1"=="" goto after_parse
if /I "%~1"=="--use-docker" (
  set "USE_DOCKER=1"
  shift
  goto parse_args
)
if /I "%~1"=="--skip-ui-build" (
  set "SKIP_UI_BUILD=1"
  shift
  goto parse_args
)
if /I "%~1"=="--install-docker" (
  set "INSTALL_DOCKER=1"
  shift
  goto parse_args
)
if /I "%~1"=="--clean-install" (
  set "CLEAN_INSTALL=1"
  shift
  goto parse_args
)
if /I "%~1"=="--app-env" (
  if "%~2"=="" (
    echo [error] --app-env requires a value.
    exit /b 1
  )
  set "APP_ENV=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--help" goto usage
if /I "%~1"=="-h" goto usage

echo [error] Unknown argument: %~1
goto usage

:after_parse
echo.
echo Super Trader Bot Windows master startup
echo Root: %ROOT%
echo.

where winget >nul 2>nul
if errorlevel 1 (
  echo [error] winget not found. Install App Installer from Microsoft Store and retry.
  exit /b 1
)

call :ensure_cmd node "Node.js LTS" "NodeJS.NodeJS.LTS"
if errorlevel 1 exit /b 1

call :ensure_cmd npm "Node.js LTS" "NodeJS.NodeJS.LTS"
if errorlevel 1 exit /b 1

if "%USE_DOCKER%"=="1" (
  if "%INSTALL_DOCKER%"=="1" (
    call :ensure_cmd docker "Docker Desktop" "Docker.DockerDesktop"
    if errorlevel 1 exit /b 1
  ) else (
    where docker >nul 2>nul
    if errorlevel 1 (
      echo [error] docker not found. Re-run with --install-docker or install Docker Desktop manually.
      exit /b 1
    )
  )
) else (
  call :ensure_cmd cargo "Rust toolchain" "Rustlang.Rustup"
  if errorlevel 1 exit /b 1
)

set "PS_ARGS=-ExecutionPolicy Bypass -File "%ROOT%run-master.ps1" -AppEnv %APP_ENV%"
if "%USE_DOCKER%"=="1" set "PS_ARGS=%PS_ARGS% -UseDocker"
if "%SKIP_UI_BUILD%"=="1" set "PS_ARGS=%PS_ARGS% -SkipUiBuild"
if "%CLEAN_INSTALL%"=="1" set "PS_ARGS=%PS_ARGS% -CleanInstall"

echo.
echo [info] Launching PowerShell master script...
powershell %PS_ARGS%
exit /b %ERRORLEVEL%

:ensure_cmd
set "CMD_NAME=%~1"
set "HUMAN_NAME=%~2"
set "WINGET_ID=%~3"

where %CMD_NAME% >nul 2>nul
if not errorlevel 1 (
  echo [ok] %CMD_NAME% already installed.
  exit /b 0
)

echo [info] %CMD_NAME% not found. Installing %HUMAN_NAME% via winget...
winget install --id %WINGET_ID% -e --accept-package-agreements --accept-source-agreements
if errorlevel 1 (
  echo [error] Failed to install %HUMAN_NAME% via winget.
  echo [hint] Try running terminal as Administrator and rerun this .bat file.
  exit /b 1
)

where %CMD_NAME% >nul 2>nul
if errorlevel 1 (
  echo [warn] %CMD_NAME% still not visible in current terminal.
  echo [hint] Close terminal and run this .bat again.
  exit /b 1
)

echo [ok] %CMD_NAME% installed.
exit /b 0

:usage
echo.
echo Usage:
echo   run-master.bat [--use-docker] [--install-docker] [--skip-ui-build] [--clean-install] [--app-env VALUE]
echo.
echo Examples:
echo   run-master.bat
echo   run-master.bat --clean-install
echo   run-master.bat --use-docker --install-docker
echo   run-master.bat --app-env production
echo.
exit /b 1
