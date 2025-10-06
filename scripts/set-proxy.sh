# shellcheck shell=bash
if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then
  echo "This script is meant to be sourced (use: set-proxy)." >&2
  exit 1
fi

if [[ -z ${BASH_VERSION:-} ]]; then
  echo "set-proxy requires bash." >&2
  return 1
fi

SCRIPT_DIR=$(cd "$(dirname "$BASH_SOURCE")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
STATE_FILE="$ROOT_DIR/.proxy-state"

resolve_proxy_port() {
  if [[ -n ${PROXY_PORT:-} ]]; then
    printf '%s\n' "$PROXY_PORT"
    return
  fi

  local port=""
  if [[ -f "$ROOT_DIR/.env" ]]; then
    port=$(awk -F= '/^PROXY_PORT=/{print $2; exit}' "$ROOT_DIR/.env")
  fi
  if [[ -z "$port" && -f "$ROOT_DIR/.env.example" ]]; then
    port=$(awk -F= '/^PROXY_PORT=/{print $2; exit}' "$ROOT_DIR/.env.example")
  fi
  if [[ -z "$port" ]]; then
    port=12334
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    port=12334
  fi
  printf '%s\n' "$port"
}

PROXY_PORT=$(resolve_proxy_port)
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
NO_PROXY_LIST="localhost,127.0.0.1,::1"
CURL_TIMEOUT="${HIDDIFY_PROXY_TIMEOUT:-8}"
PRIME_MODE="${HIDDIFY_PROXY_PRIME:-0}"

PROXY_EXPORT_VARS=(http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY ftp_proxy FTP_PROXY)
NO_PROXY_VARS=(no_proxy NO_PROXY)
STATE_VARS=("${PROXY_EXPORT_VARS[@]}" "${NO_PROXY_VARS[@]}" HIDDIFY_PROXY)

declare -Ag _proxy_backup

capture_current_env() {
  _proxy_backup=()
  for var in "${STATE_VARS[@]}"; do
    if [[ -v $var ]]; then
      _proxy_backup["$var"]="${!var}"
    else
      _proxy_backup["$var"]="__UNSET__"
    fi
  done
}

write_state_file() {
  umask 077
  {
    echo "STATUS=on"
    for var in "${STATE_VARS[@]}"; do
      printf '%s=%q\n' "$var" "${_proxy_backup[$var]-__UNSET__}"
    done
  } > "$STATE_FILE"
}

read_state_file() {
  [[ -f "$STATE_FILE" ]] || return 1
  _proxy_backup=()
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    if [[ "$key" == "STATUS" ]]; then
      continue
    fi
    if [[ "$value" == "__UNSET__" ]]; then
      _proxy_backup["$key"]="__UNSET__"
    else
      local decoded
      eval "decoded=$value"
      _proxy_backup["$key"]="$decoded"
    fi
  done < "$STATE_FILE"
  return 0
}

restore_from_backup() {
  for var in "${STATE_VARS[@]}"; do
    local value="${_proxy_backup[$var]-__UNSET__}"
    if [[ "$value" == "__UNSET__" ]]; then
      unset "$var"
    else
      printf -v line 'export %s=%q' "$var" "$value"
      eval "$line"
    fi
  done
}

apply_proxy_env() {
  for var in "${PROXY_EXPORT_VARS[@]}"; do
    printf -v line 'export %s=%q' "$var" "$PROXY_URL"
    eval "$line"
  done

  local existing
  existing="${_proxy_backup[no_proxy]-__UNSET__}"
  if [[ "$existing" == "__UNSET__" || -z "$existing" ]]; then
    export no_proxy="$NO_PROXY_LIST"
  else
    export no_proxy="$NO_PROXY_LIST,$existing"
  fi

  existing="${_proxy_backup[NO_PROXY]-__UNSET__}"
  if [[ "$existing" == "__UNSET__" || -z "$existing" ]]; then
    export NO_PROXY="$NO_PROXY_LIST"
  else
    export NO_PROXY="$NO_PROXY_LIST,$existing"
  fi

  export HIDDIFY_PROXY=on
}

clear_proxy_env() {
  for var in "${STATE_VARS[@]}"; do
    unset "$var"
  done
}

is_proxy_enabled() {
  [[ -f "$STATE_FILE" ]] && grep -q '^STATUS=on$' "$STATE_FILE"
}

fetch_location() {
  local json ip city region country

  if command -v curl >/dev/null 2>&1; then
    json=$(curl -4 -fsSL --max-time "$CURL_TIMEOUT" -H "Accept: application/json" https://ifconfig.co/json 2>/dev/null)
    if [[ -n "$json" ]]; then
      ip=$(printf '%s' "$json" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      city=$(printf '%s' "$json" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      region=$(printf '%s' "$json" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      [[ -z "$region" ]] && region=$(printf '%s' "$json" | sed -n 's/.*"region_name"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      country=$(printf '%s' "$json" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      [[ -z "$country" ]] && country=$(printf '%s' "$json" | sed -n 's/.*"country_iso"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      if [[ -n "$ip" ]]; then
        printf '%s|%s|%s|%s' "$ip" "$city" "$region" "$country"
        return 0
      fi
    fi

    json=$(curl -4 -fsSL --max-time "$CURL_TIMEOUT" https://ipinfo.io/json 2>/dev/null)
    if [[ -n "$json" ]]; then
      ip=$(printf '%s' "$json" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      city=$(printf '%s' "$json" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      region=$(printf '%s' "$json" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      country=$(printf '%s' "$json" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"[:space:]]*\)".*/\1/p')
      if [[ -n "$ip" ]]; then
        printf '%s|%s|%s|%s' "$ip" "$city" "$region" "$country"
        return 0
      fi
    fi

    ip=$(curl -4 -fsSL --max-time "$CURL_TIMEOUT" https://icanhazip.com 2>/dev/null | tr -d '\r\n')
    if [[ -n "$ip" ]]; then
      printf '%s|||' "$ip"
      return 0
    fi
  fi

  return 1
}

print_proxy_summary() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "Proxy enabled. Skipping IP check because curl is unavailable."
    return 0
  fi

  local attempt result
  local ip="" city="" region="" country="" location=""

  for attempt in 1 2 3 4 5; do
    result=$(fetch_location || true)
    IFS='|' read -r ip city region country <<< "$result"
    if [[ -n "$ip" ]]; then
      break
    fi
    sleep 2
  done

  if [[ -z "$ip" ]]; then
    echo "Proxy active but external IP lookup failed (network or service issue)."
    return 1
  fi

  [[ -n "$city" ]] && location="$city"
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
  return 0
}

prime_proxy() {
  capture_current_env
  apply_proxy_env
  print_proxy_summary || true
  restore_from_backup
}

show_status() {
  if is_proxy_enabled; then
    echo "Proxy enabled (listening on $PROXY_URL)."
  else
    echo "Proxy disabled."
  fi
}

enable_proxy() {
  if is_proxy_enabled; then
    echo "Proxy already enabled."
    print_proxy_summary || true
    return
  fi
  capture_current_env
  write_state_file
  apply_proxy_env
  print_proxy_summary || true
  echo "Proxy variables exported in this shell."
}

restore_proxy() {
  if ! read_state_file; then
    echo "Proxy already disabled."
    return
  fi
  restore_from_backup
  rm -f "$STATE_FILE"
  echo "Proxy variables removed."
}

main() {
  capture_current_env >/dev/null 2>&1 || true

  if [[ ${1:-} == "--status" ]]; then
    show_status
    return
  fi

  if [[ "$PRIME_MODE" == "1" ]]; then
    prime_proxy
    return
  fi

  if is_proxy_enabled; then
    echo "Disabling proxy..."
    restore_proxy
  else
    echo "Enabling proxy on $PROXY_URL ..."
    enable_proxy
  fi
}

main "$@"
