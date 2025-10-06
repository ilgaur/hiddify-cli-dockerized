#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
STATE_FILE="$ROOT_DIR/.proxy-state"

SHELL_BIN="${SHELL:-/bin/bash}"
NON_INTERACTIVE="${HIDDIFY_PROXY_NONINTERACTIVE:-0}"
CURL_TIMEOUT="${HIDDIFY_PROXY_TIMEOUT:-8}"

proxy_env() {
  env \
    http_proxy="$PROXY_URL" \
    HTTP_PROXY="$PROXY_URL" \
    https_proxy="$PROXY_URL" \
    HTTPS_PROXY="$PROXY_URL" \
    all_proxy="$PROXY_URL" \
    ALL_PROXY="$PROXY_URL" \
    ftp_proxy="$PROXY_URL" \
    FTP_PROXY="$PROXY_URL" \
    no_proxy="$NO_PROXY_LIST" \
    NO_PROXY="$NO_PROXY_LIST" \
    HIDDIFY_PROXY="on" \
    "$@"
}

print_proxy_summary() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "Proxy enabled. Skipping IP check because curl is unavailable."
    return
  fi

  local ip city region country location
  ip=$(proxy_env curl -fsSL --max-time "$CURL_TIMEOUT" https://icanhazip.com 2>/dev/null | tr -d '\r\n' || true)

  if [[ -z "$ip" ]]; then
    echo "Proxy enabled but external IP lookup failed (network or service issue)."
    return
  fi

  city=$(proxy_env curl -fsSL --max-time "$CURL_TIMEOUT" https://ipinfo.io/city 2>/dev/null | tr -d '\r\n' || true)
  region=$(proxy_env curl -fsSL --max-time "$CURL_TIMEOUT" https://ipinfo.io/region 2>/dev/null | tr -d '\r\n' || true)
  country=$(proxy_env curl -fsSL --max-time "$CURL_TIMEOUT" https://ipinfo.io/country 2>/dev/null | tr -d '\r\n' || true)

  location=""
  if [[ -n "$city" ]]; then
    location+="$city"
  fi
  if [[ -n "$region" && "$region" != "$city" ]]; then
    [[ -n "$location" ]] && location+=" "
    location+="$region"
  fi
  if [[ -n "$country" ]]; then
    [[ -n "$location" ]] && location+=" "
    location+="$country"
  fi

  if [[ -n "$location" ]]; then
    echo "Proxy active. External IP: $ip ($location)."
  else
    echo "Proxy active. External IP: $ip."
  fi
}

find_proxy_port() {
  if [ -n "${PROXY_PORT:-}" ]; then
    port="$PROXY_PORT"
  else
    port=""
    for candidate in "$ROOT_DIR/.env" "$ROOT_DIR/.env.example"; do
      if [ -z "$port" ] && [ -f "$candidate" ]; then
        value=$(grep -E '^PROXY_PORT=' "$candidate" | tail -n 1 | cut -d '=' -f2-)
        if [ -n "$value" ]; then
          port="$value"
        fi
      fi
    done
  fi

  if ! printf '%s' "$port" | grep -Eq '^[0-9]+$'; then
    port="12334"
  fi

  printf '%s' "$port"
}

PROXY_PORT=$(find_proxy_port)
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
NO_PROXY_LIST="localhost,127.0.0.1,::1"

ensure_shell_present() {
  if [ ! -x "$SHELL_BIN" ]; then
    echo "Cannot determine interactive shell (SHELL=$SHELL_BIN)." >&2
    exit 1
  fi
}

write_state() {
  printf '%s\n' "$1" > "$STATE_FILE"
}

remove_state() {
  rm -f "$STATE_FILE"
}

launch_shell_with_env() {
  if [ -t 0 ] && [ -t 1 ]; then
    exec env \
      http_proxy="$PROXY_URL" \
      HTTP_PROXY="$PROXY_URL" \
      https_proxy="$PROXY_URL" \
      HTTPS_PROXY="$PROXY_URL" \
      all_proxy="$PROXY_URL" \
      ALL_PROXY="$PROXY_URL" \
      ftp_proxy="$PROXY_URL" \
      FTP_PROXY="$PROXY_URL" \
      no_proxy="$NO_PROXY_LIST" \
      NO_PROXY="$NO_PROXY_LIST" \
      HIDDIFY_PROXY="on" \
      "$SHELL_BIN" -l
  else
    echo "Proxy enabled. Launch an interactive shell to pick up the settings." >&2
  fi
}

launch_shell_without_env() {
  if [ -t 0 ] && [ -t 1 ]; then
    exec env \
      -u http_proxy -u HTTP_PROXY \
      -u https_proxy -u HTTPS_PROXY \
      -u all_proxy -u ALL_PROXY \
      -u ftp_proxy -u FTP_PROXY \
      -u no_proxy -u NO_PROXY \
      -u HIDDIFY_PROXY \
      "$SHELL_BIN" -l
  else
    echo "Proxy disabled. Launch a new shell to continue without proxy." >&2
  fi
}

ensure_shell_present

if [ -f "$STATE_FILE" ]; then
  echo "Disabling proxy..."
  remove_state
  if [ "$NON_INTERACTIVE" = "1" ]; then
    echo "Proxy entries removed."
    exit 0
  fi
  launch_shell_without_env
else
  echo "Enabling proxy on $PROXY_URL ..."
  write_state "on"
  print_proxy_summary || true
  if [ "$NON_INTERACTIVE" = "1" ]; then
    echo "Proxy entries staged for 127.0.0.1:$PROXY_PORT. Run 'set-proxy' to toggle interactively."
    exit 0
  fi
  launch_shell_with_env
fi
