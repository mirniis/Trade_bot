@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0"
set "URL=http://127.0.0.1:8080"
set "HEALTH=%URL%/api/health"

echo.
echo Super Trader Bot unified startup
echo Root: %ROOT%
echo.

REM If already running, just open browser.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-WebRequest -UseBasicParsing -Uri '%HEALTH%' -TimeoutSec 2; if ($r.StatusCode -eq 200 -and $r.Content -match 'ok') { exit 0 } else { exit 1 } } catch { exit 1 }"
if %ERRORLEVEL% EQU 0 (
  echo [info] Bot is already running. Opening browser...
  start "" "%URL%"
  exit /b 0
)

REM Start full project in a separate terminal window.
echo [info] Starting full system (UI build + backend run)...
start "Super Trader Bot" powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%run-master.ps1"

REM Wait until backend is healthy, then open browser.
echo [info] Waiting for backend health...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline=(Get-Date).AddMinutes(5); $ok=$false; while((Get-Date) -lt $deadline){ try { $r=Invoke-WebRequest -UseBasicParsing -Uri '%HEALTH%' -TimeoutSec 3; if($r.StatusCode -eq 200 -and $r.Content -match 'ok'){ $ok=$true; break } } catch {}; Start-Sleep -Milliseconds 700 }; if($ok){ exit 0 } else { exit 1 }"
if %ERRORLEVEL% EQU 0 (
  echo [ok] Backend is up. Opening browser...
  start "" "%URL%"
  exit /b 0
)

echo [error] Backend did not become healthy within timeout.
echo [hint] Check the "Super Trader Bot" terminal window for details.
exit /b 1
