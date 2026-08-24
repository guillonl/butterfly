#!/bin/zsh
set -euo pipefail

MODE="${1:-run}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Butterfly"
BUILD="/private/tmp/butterfly-codex-build"
APP="$BUILD/Butterfly Dev.app"
BIN="$APP/Contents/MacOS/Butterfly"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
cd "$ROOT"
env \
  BUTTERFLY_BUILD_DIR="$BUILD" \
  BUTTERFLY_APP_NAME="Butterfly Dev" \
  BUTTERFLY_BUNDLE_ID="com.leoguillon.butterfly.dev" \
  BUTTERFLY_SIGN_IDENTITY="Butterfly Dev" \
  bash scripts/build.sh

open_app() { /usr/bin/open -n "$APP"; }

case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$BIN" ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.leoguillon.butterfly"'
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
