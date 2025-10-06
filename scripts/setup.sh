#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run this script with sudo (e.g., sudo ./setup.sh)." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
STATE_DIR="$ROOT_DIR/.state"
IMAGE_PATH="$ROOT_DIR/image/hiddify-cli-offline.tar.xz"
HASH_RECORD="$STATE_DIR/hiddify-image.sha256"
ENV_FILE="$ROOT_DIR/.env"
ENV_TEMPLATE="$ROOT_DIR/.env.example"
REPO_USER="${SUDO_USER:-root}"
REPO_USER_HOME=$(getent passwd "$REPO_USER" | cut -d: -f6 || true)
[[ -z "$REPO_USER_HOME" ]] && REPO_USER_HOME="$ROOT_DIR"
SET_PROXY_MARKER="set-proxy() {"
declare -a alias_targets=()
docker_group_notice=""

get_repo_group() {
  id -gn "$REPO_USER" 2>/dev/null || echo "$REPO_USER"
}

set_owner_if_needed() {
  local path="$1"
  if [[ "$REPO_USER" != "root" && -e "$path" ]]; then
    local group
    group=$(get_repo_group)
    chown "$REPO_USER":"$group" "$path" 2>/dev/null || true
  fi
}

info() { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup][warn] %s\n' "$*" >&2; }
require_file() { [[ -f "$1" ]] || { warn "Required file missing: $1"; exit 1; }; }
ensure_executable() { [[ -f "$1" ]] && chmod +x "$1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || { warn "Required command '$1' not found."; exit 1; }; }

run_as_user() {
  local user="$1"; shift
  if [[ "$user" == "root" ]]; then
    "$@"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- "$@"
  else
    local quoted
    printf -v quoted ' %q' "$@"
    su - "$user" -c "${quoted:1}"
  fi
}

get_env_value() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  awk -F'=' -v k="$key" 'BEGIN{OFS="="} !/^#/ && $1==k {print substr($0, index($0,$2)); exit}' "$file"
}

set_env_value() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  if [[ -f "$ENV_FILE" ]]; then
    awk -F'=' -v k="$key" -v v="$value" 'BEGIN{OFS="="; seen=0}
      /^#/ {print; next}
      $1==k {
        if (!seen) {print k"="v; seen=1}
        next
      }
      {print}
      END{if(!seen)print k"="v}' "$ENV_FILE" > "$tmp"
  else
    echo "${key}=${value}" > "$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
  trap - RETURN
  set_owner_if_needed "$ENV_FILE"
}

prompt_value() {
  local key="$1" label="$2" default_value="$3" required="$4" input
  local prompt tty_available=1

  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    tty_available=0
  fi

  while true; do
    prompt="$label"
    [[ -n "$default_value" ]] && prompt+=" [${default_value}]"
    prompt+=": "
    if [[ $tty_available -eq 1 ]]; then
      if [[ -t 0 ]]; then
        read -r -p "$prompt" input
      else
        read -r -p "$prompt" input < /dev/tty
      fi
    else
      info "Non-interactive session: using default value for $label."
      input="$default_value"
    fi

    if [[ -z "$input" ]]; then
      input="$default_value"
    fi
    if [[ "$required" == "true" && -z "$input" ]]; then
      warn "${label} is required."
      continue
    fi
    printf '%s' "$input"
    return
  done
}

append_shell_block() {
  local target="$1" marker="$2" content="$3"
  if [[ ! -e "$target" ]]; then
    touch "$target"
    set_owner_if_needed "$target"
  fi
  if ! grep -Fqx "$marker" "$target" 2>/dev/null; then
    printf '\n%s\n' "$content" >> "$target"
    alias_targets+=("$target")
  fi
}

remove_legacy_alias() {
  local target="$1"
  [[ -f "$target" ]] || return
  if grep -q '^alias set-proxy=' "$target" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    grep -v '^alias set-proxy=' "$target" > "$tmp"
    mv "$tmp" "$target"
    set_owner_if_needed "$target"
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker already present."
  else
    info "Docker not detected. Running install-docker.sh ..."
    require_file "$ROOT_DIR/scripts/install-docker.sh"
    ensure_executable "$ROOT_DIR/scripts/install-docker.sh"
    "$ROOT_DIR/scripts/install-docker.sh"
  fi

  if [[ "$REPO_USER" != "root" ]] && command -v usermod >/dev/null 2>&1; then
    if id -nG "$REPO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      info "User $REPO_USER already in docker group."
    else
      usermod -aG docker "$REPO_USER"
      docker_group_notice="User '$REPO_USER' added to docker group. Re-login or run 'newgrp docker' to apply permissions."
    fi
  fi
}

ensure_image_loaded() {
  require_file "$IMAGE_PATH"
  require_command sha256sum
  mkdir -p "$STATE_DIR"
  local current_hash
  current_hash=$(sha256sum "$IMAGE_PATH" | awk '{print $1}')
  local need_load=0
  if ! docker image inspect local/hiddify-cli-offline:latest >/dev/null 2>&1; then
    need_load=1
  elif [[ ! -f "$HASH_RECORD" ]] || [[ $(cat "$HASH_RECORD") != "$current_hash" ]]; then
    need_load=1
  fi
  if [[ $need_load -eq 1 ]]; then
    info "Loading bundled Docker image ..."
    ensure_executable "$ROOT_DIR/scripts/load-image.sh"
    "$ROOT_DIR/scripts/load-image.sh"
    echo "$current_hash" > "$HASH_RECORD"
    set_owner_if_needed "$HASH_RECORD"
  else
    info "Bundled Docker image already matches the loaded version."
  fi
}

configure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    info "Creating .env from template."
    require_file "$ENV_TEMPLATE"
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    set_owner_if_needed "$ENV_FILE"
  fi

  local sub_default
  sub_default=$(get_env_value SUBSCRIPTION_URL "$ENV_FILE")
  local subscription_url
  subscription_url=$(prompt_value "SUBSCRIPTION_URL" "Subscription URL" "$sub_default" true)
  set_env_value SUBSCRIPTION_URL "$subscription_url"

  local example_default
  example_default=$(get_env_value PROXY_PORT "$ENV_FILE")
  [[ -z "$example_default" ]] && example_default=$(get_env_value PROXY_PORT "$ENV_TEMPLATE")
  local proxy_port
  proxy_port=$(prompt_value "PROXY_PORT" "Proxy port" "${example_default:-12334}" false)
  set_env_value PROXY_PORT "$proxy_port"

  local check_interval_default
  check_interval_default=$(get_env_value CHECK_INTERVAL "$ENV_FILE")
  [[ -z "$check_interval_default" ]] && check_interval_default=$(get_env_value CHECK_INTERVAL "$ENV_TEMPLATE")
  [[ -z "$check_interval_default" ]] && check_interval_default=10
  local check_interval
  check_interval=$(prompt_value "CHECK_INTERVAL" "Health-check interval (seconds)" "$check_interval_default" false)
  set_env_value CHECK_INTERVAL "$check_interval"

  local fail_threshold_default
  fail_threshold_default=$(get_env_value FAIL_THRESHOLD "$ENV_FILE")
  [[ -z "$fail_threshold_default" ]] && fail_threshold_default=$(get_env_value FAIL_THRESHOLD "$ENV_TEMPLATE")
  [[ -z "$fail_threshold_default" ]] && fail_threshold_default=3
  local fail_threshold
  fail_threshold=$(prompt_value "FAIL_THRESHOLD" "Restart threshold" "$fail_threshold_default" false)
  set_env_value FAIL_THRESHOLD "$fail_threshold"

  local health_url_default
  health_url_default=$(get_env_value HEALTHCHECK_URL "$ENV_FILE")
  [[ -z "$health_url_default" ]] && health_url_default=$(get_env_value HEALTHCHECK_URL "$ENV_TEMPLATE")
  [[ -z "$health_url_default" ]] && health_url_default=https://icanhazip.com
  local health_url
  health_url=$(prompt_value "HEALTHCHECK_URL" "Health-check URL" "$health_url_default" false)
  set_env_value HEALTHCHECK_URL "$health_url"

  local restart_grace_default
  restart_grace_default=$(get_env_value RESTART_GRACE "$ENV_FILE")
  [[ -z "$restart_grace_default" ]] && restart_grace_default=$(get_env_value RESTART_GRACE "$ENV_TEMPLATE")
  [[ -z "$restart_grace_default" ]] && restart_grace_default=3
  local restart_grace
  restart_grace=$(prompt_value "RESTART_GRACE" "Restart grace (seconds)" "$restart_grace_default" false)
  set_env_value RESTART_GRACE "$restart_grace"

  info "Environment values saved to .env"
}

setup_aliases() {
  alias_targets=()

  local set_proxy_block set_proxy_profile

  read -r -d '' set_proxy_block <<'EOF_BLOCK' || true
set-proxy() {
  . "%ROOT_DIR%/scripts/set-proxy.sh" "\$@"
}
EOF_BLOCK
  set_proxy_block=${set_proxy_block//%ROOT_DIR%/$ROOT_DIR}

  local user_files=("$REPO_USER_HOME/.bashrc" "$REPO_USER_HOME/.profile" "$REPO_USER_HOME/.bash_profile" "$REPO_USER_HOME/.zshrc")
  for file in "${user_files[@]}"; do
    remove_legacy_alias "$file"
    append_shell_block "$file" "$SET_PROXY_MARKER" "$set_proxy_block"
  done

  read -r -d '' set_proxy_profile <<'EOF_PROFILE' || true
#!/bin/sh
set-proxy() {
  . "%ROOT_DIR%/scripts/set-proxy.sh" "\$@"
}
EOF_PROFILE
  set_proxy_profile=${set_proxy_profile//%ROOT_DIR%/$ROOT_DIR}

  if [[ -d /etc/profile.d ]]; then
    local profile_script="/etc/profile.d/hiddify-proxy.sh"
    printf '%s\n' "$set_proxy_profile" > "$profile_script"
    chmod 0644 "$profile_script"
    alias_targets+=("$profile_script")
  fi
}

install_proxy_command() {
  local wrapper="/usr/local/bin/set-proxy"
  cat <<EOF > "$wrapper"
#!/usr/bin/env bash
echo "Use 'set-proxy' from an interactive shell (function)." >&2
echo "If you need to inspect the current proxy state, run: source \"$ROOT_DIR/scripts/set-proxy.sh\" --status" >&2
exit 1
EOF
  chmod 0755 "$wrapper"
}

deploy_stack() {
  info "Starting Docker Compose stack ..."
  if docker compose version >/dev/null 2>&1; then
    docker compose up -d
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d
  else
    warn "Neither 'docker compose' nor 'docker-compose' is available."
    exit 1
  fi
}

enable_proxy_toggle() {
  if [[ -x "$ROOT_DIR/scripts/set-proxy.sh" ]]; then
    echo
    if [[ -t 0 && -t 1 ]]; then
      info "Opening a proxied shell for $REPO_USER (exit to continue)."
      if ! run_as_user "$REPO_USER" "$ROOT_DIR/scripts/set-proxy.sh"; then
        warn "Unable to launch proxied shell for $REPO_USER. Run 'set-proxy' manually."
      fi
    else
      info "Non-interactive session detected; priming proxy toggle for $REPO_USER."
      if ! run_as_user "$REPO_USER" env HIDDIFY_PROXY_NONINTERACTIVE=1 HIDDIFY_PROXY_PRIME=1 bash "$ROOT_DIR/scripts/set-proxy.sh"; then
        warn "Unable to prime proxy toggle for $REPO_USER. Run 'set-proxy' manually."
      fi
    fi
  fi
}

summarise() {
  echo
  info "Setup complete."
  echo "Configuration file: $ENV_FILE"
  echo "Docker image: local/hiddify-cli-offline:latest"
  if [[ -n "${docker_group_notice:-}" ]]; then
    echo "$docker_group_notice"
  fi
  if ((${#alias_targets[@]})); then
    echo "Alias 'set-proxy' registered in:"
    for file in "${alias_targets[@]}"; do
      echo "  - $file"
    done
  else
    echo "Alias 'set-proxy' already present."
  fi
  echo "Use 'set-proxy' (shell function) to toggle the local proxy in your shells."
  echo "You can check the stack with 'docker compose ps'."
}

main() {
  cd "$ROOT_DIR"
  mkdir -p "$STATE_DIR"
  set_owner_if_needed "$STATE_DIR"
  ensure_executable "$ROOT_DIR/scripts/set-proxy.sh"
  ensure_executable "$ROOT_DIR/scripts/load-image.sh"
  ensure_executable "$ROOT_DIR/scripts/install-docker.sh"
  ensure_executable "$ROOT_DIR/entrypoint.sh"
  ensure_executable "$ROOT_DIR/HiddifyCli"
  configure_env_file
  ensure_docker
  ensure_image_loaded
  deploy_stack
  setup_aliases
  install_proxy_command
  enable_proxy_toggle
  summarise
}

main "$@"
