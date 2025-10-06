#!/bin/sh
set -eu

PROXY_PORT="${PROXY_PORT:-12334}"
INTERNAL_PROXY_PORT="${INTERNAL_PROXY_PORT:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://icanhazip.com}"
PROXY_TIMEOUT="${PROXY_TIMEOUT:-8}"
DIRECT_TIMEOUT="${DIRECT_TIMEOUT:-5}"
RESTART_GRACE="${RESTART_GRACE:-3}"

validate_uint() {
  case "$1" in
    ''|*[!0-9]*)
      echo "Invalid numeric value: $1" >&2
      exit 1
      ;;
  esac
}

validate_uint "$PROXY_PORT"
[ -n "$INTERNAL_PROXY_PORT" ] && validate_uint "$INTERNAL_PROXY_PORT"
validate_uint "$CHECK_INTERVAL"
validate_uint "$FAIL_THRESHOLD"
validate_uint "$PROXY_TIMEOUT"
validate_uint "$DIRECT_TIMEOUT"
validate_uint "$RESTART_GRACE"

if [ -z "$INTERNAL_PROXY_PORT" ] || [ "$INTERNAL_PROXY_PORT" -eq "$PROXY_PORT" ]; then
  INTERNAL_PROXY_PORT=$((PROXY_PORT + 1))
fi

cleanup() {
  kill "${CLI_PID:-}" 2>/dev/null || true
  kill "${SOCAT_TCP_PID:-}" 2>/dev/null || true
  kill "${SOCAT_UDP_PID:-}" 2>/dev/null || true
  wait "${CLI_PID:-}" 2>/dev/null || true
  wait "${SOCAT_TCP_PID:-}" 2>/dev/null || true
  wait "${SOCAT_UDP_PID:-}" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

start_cli() {
  /opt/hiddify/HiddifyCli "$@" --in-proxy-port "$INTERNAL_PROXY_PORT" &
  CLI_PID=$!
}

restart_cli() {
  echo "[entrypoint] Restarting HiddifyCli" >&2
  kill "$CLI_PID" 2>/dev/null || true
  wait "$CLI_PID" 2>/dev/null || true
  start_cli "$@"
  sleep "$RESTART_GRACE"
}

start_cli "$@"

socat TCP-LISTEN:"$PROXY_PORT",fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:"$INTERNAL_PROXY_PORT" &
SOCAT_TCP_PID=$!

socat -T15 UDP-LISTEN:"$PROXY_PORT",fork,reuseaddr,bind=0.0.0.0 UDP:127.0.0.1:"$INTERNAL_PROXY_PORT" &
SOCAT_UDP_PID=$!

fail_count=0

proxy_probe() {
  curl --fail --silent --show-error --max-time "$PROXY_TIMEOUT" \
    --proxy "http://127.0.0.1:$PROXY_PORT" \
    --output /dev/null "$HEALTHCHECK_URL"
}

direct_probe() {
  curl --fail --silent --show-error --max-time "$DIRECT_TIMEOUT" \
    --noproxy '*' --output /dev/null "$HEALTHCHECK_URL"
}

while :; do
  sleep "$CHECK_INTERVAL"

  if ! kill -0 "$CLI_PID" 2>/dev/null; then
    echo "[entrypoint] HiddifyCli exited; relaunching" >&2
    restart_cli "$@"
    fail_count=0
    continue
  fi

  if proxy_probe; then
    fail_count=0
    continue
  fi

  if ! direct_probe; then
    echo "[entrypoint] Proxy check failed but internet unavailable; skipping restart" >&2
    fail_count=0
    continue
  fi

  fail_count=$((fail_count + 1))
  if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
    restart_cli "$@"
    fail_count=0
  fi
done
