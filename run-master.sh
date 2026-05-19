#!/usr/bin/env bash
set -euo pipefail

SKIP_UI_BUILD=0
USE_DOCKER=0
APP_ENV="local"
CLEAN_INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ui-build)
      SKIP_UI_BUILD=1
      shift
      ;;
    --use-docker)
      USE_DOCKER=1
      shift
      ;;
    --app-env)
      APP_ENV="${2:-local}"
      shift 2
      ;;
    --clean-install)
      CLEAN_INSTALL=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./run-master.sh [options]

Options:
  --skip-ui-build      Skip npm ci and npm run build in ui
  --use-docker         Start project via docker compose
  --clean-install      Clean data/logs and reset data/PnL_stat.json to []
  --app-env <value>    Set APP_ENV for backend run (default: local)
  -h, --help           Show help
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ensure_command() {
  local name="$1"
  local hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing command '$name'. Install it first: $hint" >&2
    exit 1
  fi
}

run_step() {
  local title="$1"
  echo
  echo "==> $title"
}

echo "Super Trader Bot master startup"
echo "Root: $ROOT_DIR"

if [[ "$CLEAN_INSTALL" -eq 1 ]]; then
  run_step "Cleaning logs and PnL_stat for fresh install"
  mkdir -p "$ROOT_DIR/data/logs"
  find "$ROOT_DIR/data/logs" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  printf '[]\n' > "$ROOT_DIR/data/PnL_stat.json"
fi

run_step "Checking required tools"
ensure_command node "https://nodejs.org/"
ensure_command npm "https://nodejs.org/"
if [[ "$USE_DOCKER" -eq 1 ]]; then
  ensure_command docker "https://docs.docker.com/get-docker/"
else
  ensure_command cargo "https://rustup.rs/"
fi

if [[ "$SKIP_UI_BUILD" -eq 0 ]]; then
  run_step "Installing UI dependencies (npm ci)"
  cd "$ROOT_DIR/ui"
  npm ci

  run_step "Building UI (npm run build)"
  npm run build
else
  echo
  echo "==> Skipping UI build because --skip-ui-build was provided"
fi

if [[ "$USE_DOCKER" -eq 1 ]]; then
  run_step "Starting project with Docker Compose"
  cd "$ROOT_DIR"
  docker compose up -d --build

  run_step "Health check"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "http://127.0.0.1:8080/api/health" >/dev/null; then
      echo "Health: OK"
    else
      echo "Health check failed"
    fi
  else
    echo "curl is not installed; skip health check"
  fi

  echo
  echo "Project started in Docker mode."
  echo "Open: http://127.0.0.1:8080"
  exit 0
fi

run_step "Building backend (cargo build)"
cd "$ROOT_DIR/backend"
cargo build

run_step "Starting backend (cargo run)"
export APP_ENV="$APP_ENV"
echo "APP_ENV=$APP_ENV"
echo "Backend will run in this terminal. Press Ctrl+C to stop."
cargo run
