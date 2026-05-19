param(
  [switch]$SkipUiBuild,
  [switch]$UseDocker,
  [switch]$CleanInstall,
  [string]$AppEnv = "local"
)

$ErrorActionPreference = "Stop"

function Ensure-Command {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$InstallHint
  )

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing command '$Name'. Install it first: $InstallHint"
  }
}

function Run-Step {
  param(
    [Parameter(Mandatory=$true)][string]$Title,
    [Parameter(Mandatory=$true)][scriptblock]$Action
  )

  Write-Host "`n==> $Title" -ForegroundColor Cyan
  & $Action
}

function Reset-InstallArtifacts {
  param(
    [Parameter(Mandatory=$true)][string]$RootPath
  )

  $logsDir = Join-Path $RootPath "data\logs"
  $pnlPath = Join-Path $RootPath "data\PnL_stat.json"

  New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
  Get-ChildItem -Path $logsDir -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
  Set-Content -Path $pnlPath -Value "[]" -Encoding UTF8
}

$root = $PSScriptRoot
if (-not $root) {
  $root = (Get-Location).Path
}

Write-Host "Super Trader Bot master startup" -ForegroundColor Green
Write-Host "Root: $root"

if ($CleanInstall) {
  Run-Step "Cleaning logs and PnL_stat for fresh install" {
    Reset-InstallArtifacts -RootPath $root
  }
}

Run-Step "Checking required tools" {
  Ensure-Command -Name "node" -InstallHint "https://nodejs.org/"
  Ensure-Command -Name "npm" -InstallHint "https://nodejs.org/"

  if ($UseDocker) {
    Ensure-Command -Name "docker" -InstallHint "https://www.docker.com/products/docker-desktop/"
  } else {
    Ensure-Command -Name "cargo" -InstallHint "https://rustup.rs/"
  }
}

if (-not $SkipUiBuild) {
  Run-Step "Installing UI dependencies (npm ci)" {
    Set-Location (Join-Path $root "ui")
    npm ci
  }

  Run-Step "Building UI (npm run build)" {
    npm run build
  }
} else {
  Write-Host "`n==> Skipping UI build because -SkipUiBuild was provided" -ForegroundColor Yellow
}

if ($UseDocker) {
  Run-Step "Starting project with Docker Compose" {
    Set-Location $root
    docker compose up -d --build
  }

  Run-Step "Health check" {
    try {
      $health = Invoke-WebRequest -Uri "http://127.0.0.1:8080/api/health" -UseBasicParsing -TimeoutSec 10
      Write-Host "Health: $($health.StatusCode)" -ForegroundColor Green
    }
    catch {
      Write-Warning "Health check failed: $($_.Exception.Message)"
    }
  }

  Write-Host "`nProject started in Docker mode." -ForegroundColor Green
  Write-Host "Open: http://127.0.0.1:8080"
  exit 0
}

Run-Step "Building backend (cargo build)" {
  Set-Location (Join-Path $root "backend")
  cargo build
}

Run-Step "Starting backend (cargo run)" {
  $env:APP_ENV = $AppEnv
  Write-Host "APP_ENV=$($env:APP_ENV)"
  Write-Host "Backend will run in this terminal. Press Ctrl+C to stop." -ForegroundColor Yellow
  cargo run
}
