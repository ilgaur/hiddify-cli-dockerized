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
AUTO_ENABLE_FILE="$STATE_DIR/auto-enable-proxy"
declare -a alias_targets=()
docker_group_notice=""

# Debug mode - set to 1 to enable verbose output
DEBUG_MODE="${HIDDIFY_DEBUG:-0}"

debug() {
  if [[ "$DEBUG_MODE" == "1" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

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

docker_cmd() {
  if [[ -n "${DOCKER_RUN_AS_USER:-}" ]]; then
    debug "Running docker command as user: $DOCKER_RUN_AS_USER"
    run_as_user "$DOCKER_RUN_AS_USER" "$@"
  else
    debug "Running docker command as current user (root)"
    "$@"
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

prompt_proxy_bind_address() {
  local default_choice="$1" input
  local normalized_default

  case "${default_choice,,}" in
    y|yes)
      normalized_default="y"
      ;;
    n|no|"")
      normalized_default="n"
      ;;
    *)
      normalized_default="$default_choice"
      ;;
  esac

  while true; do
    input=$(prompt_value "PROXY_BIND_PROMPT" "Expose proxy on all interfaces? (y/N or IP)" "$normalized_default" false)
    case "${input,,}" in
      y|yes)
        printf '0.0.0.0'
        return
        ;;
      n|no)
        printf '127.0.0.1'
        return
        ;;
      *)
        if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          printf '%s' "$input"
          return
        fi
        warn "Please enter 'y', 'n', or an IPv4 address."
    esac
    normalized_default="n"
  done
}

append_shell_block() {
  local target="$1" marker="$2" content="$3"
  if [[ ! -e "$target" ]]; then
    touch "$target"
    set_owner_if_needed "$target"
  fi
  if ! grep -Fqx "$marker" "$target" 2>/dev/null; then
    printf '\n%s\n' "$content" >> "$target" || true
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
    
    # Check if Docker Desktop is being used
    if [[ "$REPO_USER" != "root" ]]; then
      local user_docker_socket="/home/$REPO_USER/.docker/desktop/docker.sock"
      local user_docker_desktop_socket="/home/$REPO_USER/.docker/desktop/docker-cli.sock"
      
      if [[ -S "$user_docker_desktop_socket" ]] || [[ -S "$user_docker_socket" ]]; then
        info "Detected user-scoped Docker daemon; running Docker commands as $REPO_USER."
        export DOCKER_RUN_AS_USER="$REPO_USER"
      fi
    fi
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
  if ! docker_cmd docker image inspect local/hiddify-cli-offline:latest >/dev/null 2>&1; then
    need_load=1
  elif [[ ! -f "$HASH_RECORD" ]] || [[ $(cat "$HASH_RECORD") != "$current_hash" ]]; then
    need_load=1
  fi
  if [[ $need_load -eq 1 ]]; then
    info "Loading bundled Docker image ..."
    ensure_executable "$ROOT_DIR/scripts/load-image.sh"
    
    # Pass the DOCKER_RUN_AS_USER environment variable to load-image.sh
    if [[ -n "${DOCKER_RUN_AS_USER:-}" ]]; then
      export DOCKER_RUN_AS_USER
      run_as_user "$DOCKER_RUN_AS_USER" "$ROOT_DIR/scripts/load-image.sh"
    else
      "$ROOT_DIR/scripts/load-image.sh"
    fi
    
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

  local bind_existing
  bind_existing=$(get_env_value PROXY_BIND_ADDRESS "$ENV_FILE")
  [[ -z "$bind_existing" ]] && bind_existing=$(get_env_value PROXY_BIND_ADDRESS "$ENV_TEMPLATE")
  local bind_prompt_default
  case "${bind_existing,,}" in
    0.0.0.0)
      bind_prompt_default="y"
      ;;
    ""|127.0.0.1)
      bind_prompt_default="n"
      ;;
    *)
      bind_prompt_default="$bind_existing"
      ;;
  esac
  local bind_address
  bind_address=$(prompt_proxy_bind_address "$bind_prompt_default")
  set_env_value PROXY_BIND_ADDRESS "$bind_address"

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
  debug "Setting up aliases"
  alias_targets=()

  local set_proxy_block set_proxy_profile

  read -r -d '' set_proxy_block <<'EOF_BLOCK' || true
set-proxy() {
  . "%ROOT_DIR%/scripts/set-proxy.sh" "\$@"
}

if [[ -z ${HIDDIFY_PROXY_FN_LOADED:-} ]]; then
  export HIDDIFY_PROXY_FN_LOADED=1
  if [[ -f "%AUTO_ENABLE_FILE%" ]]; then
    rm -f "%AUTO_ENABLE_FILE%"
    set-proxy || true
  else
    set-proxy --status >/dev/null 2>&1 || true
  fi
fi
EOF_BLOCK
  set_proxy_block=${set_proxy_block//%ROOT_DIR%/$ROOT_DIR}
  set_proxy_block=${set_proxy_block//%AUTO_ENABLE_FILE%/$AUTO_ENABLE_FILE}

  local user_files=("$REPO_USER_HOME/.bashrc" "$REPO_USER_HOME/.profile" "$REPO_USER_HOME/.bash_profile" "$REPO_USER_HOME/.zshrc")
  for file in "${user_files[@]}"; do
    remove_legacy_alias "$file"
    append_shell_block "$file" "$SET_PROXY_MARKER" "$set_proxy_block"
  done

  read -r -d '' set_proxy_profile <<'EOF_PROFILE' || true
#!/bin/sh
if [ -n "$BASH_VERSION" ] || [ -n "$ZSH_VERSION" ]; then
  set-proxy() {
    . "%ROOT_DIR%/scripts/set-proxy.sh" "\$@"
  }

  if [ -z "${HIDDIFY_PROXY_FN_LOADED:-}" ]; then
    export HIDDIFY_PROXY_FN_LOADED=1
    if [ -f "%AUTO_ENABLE_FILE%" ]; then
      rm -f "%AUTO_ENABLE_FILE%"
      set-proxy || true
    else
      set-proxy --status >/dev/null 2>&1 || true
    fi
  fi
fi
EOF_PROFILE
  set_proxy_profile=${set_proxy_profile//%ROOT_DIR%/$ROOT_DIR}
  set_proxy_profile=${set_proxy_profile//%AUTO_ENABLE_FILE%/$AUTO_ENABLE_FILE}

  if [[ -d /etc/profile.d ]]; then
    local profile_script="/etc/profile.d/hiddify-proxy.sh"
    printf '%s\n' "$set_proxy_profile" > "$profile_script" || true
    chmod 0644 "$profile_script" || true
    alias_targets+=("$profile_script")
  fi
  
  debug "Aliases setup complete"
}

install_proxy_command() {
  debug "Installing proxy command wrapper"
  local wrapper="/usr/local/bin/set-proxy"
  cat <<EOF > "$wrapper"
#!/usr/bin/env bash
echo "Use 'set-proxy' from an interactive shell (function)." >&2
echo "If you need to inspect the current proxy state, run: source \"$ROOT_DIR/scripts/set-proxy.sh\" --status" >&2
exit 1
EOF
  chmod 0755 "$wrapper" || true
}

deploy_stack() {
  info "Starting Docker Compose stack ..."
  
  # Change to the root directory where docker-compose.yml is located
  cd "$ROOT_DIR"
  
  # Temporarily disable exit on error for docker compose
  set +e
  local compose_status=0
  
  if docker_cmd docker compose version >/dev/null 2>&1; then
    debug "Using 'docker compose' command"
    docker_cmd docker compose up -d
    compose_status=$?
  elif command -v docker-compose >/dev/null 2>&1; then
    debug "Using 'docker-compose' command"
    docker_cmd docker-compose up -d
    compose_status=$?
  else
    warn "Neither 'docker compose' nor 'docker-compose' is available."
    exit 1
  fi
  
  set -e
  
  # Check if the container started successfully
  if [[ $compose_status -ne 0 ]]; then
    warn "Failed to start Docker Compose stack (exit code: $compose_status)."
    exit 1
  fi
  
  # Give container time to stabilize
  debug "Waiting for container to stabilize..."
  sleep 3
  
  # Verify the container is actually running
  if docker_cmd docker ps --filter "name=hiddify-cli" --format '{{.Names}}' | grep -q hiddify-cli; then
    debug "Container hiddify-cli is confirmed running"
  else
    warn "Container hiddify-cli is not running after deployment"
  fi
}

show_proxy_info() {
  # This function displays the proxy information
  local proxy_port
  proxy_port=$(get_env_value PROXY_PORT "$ENV_FILE")
  [[ -z "$proxy_port" ]] && proxy_port=12334
  
  echo
  info "Testing proxy connectivity..."
  
  # Wait a bit more for proxy to be ready
  sleep 2
  
  # Test if proxy is working
  local test_result external_ip location_json
  test_result=$(curl -s -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:${proxy_port}" \
    --max-time 8 \
    https://icanhazip.com 2>/dev/null || echo "000")
  
  if [[ "$test_result" == "200" ]]; then
    # Get external IP
    external_ip=$(curl -s --proxy "http://127.0.0.1:${proxy_port}" \
      --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '\r\n')
    
    if [[ -n "$external_ip" ]]; then
      # Try to get location info
      location_json=$(curl -s --proxy "http://127.0.0.1:${proxy_port}" \
        --max-time 5 "https://ipinfo.io/${external_ip}/json" 2>/dev/null || echo "{}")
      
      if [[ -n "$location_json" && "$location_json" != "{}" ]]; then
        local city region country location=""
        city=$(echo "$location_json" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        region=$(echo "$location_json" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') 
        country=$(echo "$location_json" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        
        [[ -n "$city" ]] && location="$city"
        [[ -n "$region" && "$region" != "$city" ]] && location="${location:+$location, }$region"
        [[ -n "$country" ]] && location="${location:+$location, }$country"
        
        if [[ -n "$location" ]]; then
          info "✓ Proxy active. External IP: $external_ip ($location)"
        else
          info "✓ Proxy active. External IP: $external_ip"
        fi
      else
        info "✓ Proxy active. External IP: $external_ip"
      fi
    else
      info "✓ Proxy is active on port $proxy_port"
    fi
  else
    warn "Proxy on port $proxy_port is not responding yet (HTTP $test_result)."
    echo "  You can test it manually with:"
    echo "    curl --proxy http://127.0.0.1:${proxy_port} https://icanhazip.com"
  fi
}

enable_proxy_toggle() {
  debug "Starting enable_proxy_toggle function"
  
  # First show the proxy information
  show_proxy_info
  
  # Setup the set-proxy function for the user
  if [[ -x "$ROOT_DIR/scripts/set-proxy.sh" ]]; then
    # Try to prime the proxy for the user (but don't fail if it doesn't work)
    if [[ "$REPO_USER" != "root" ]]; then
      debug "Attempting to prime proxy for user $REPO_USER"
      set +e
      local prime_cmd="HIDDIFY_PROXY_PRIME=1 source '$ROOT_DIR/scripts/set-proxy.sh'"
      run_as_user "$REPO_USER" bash -c "$prime_cmd" < /dev/null > /dev/null 2>&1
      set -e
    fi
    
    info "Proxy helper configured. Run 'set-proxy' in your shell to toggle proxy variables."
  else
    warn "set-proxy.sh not found or not executable."
  fi
  
  debug "enable_proxy_toggle function complete"
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
  
  echo
  echo "Use 'set-proxy' (shell function) to toggle the local proxy in your shells."
  echo "Open a new shell or run 'exec \$SHELL -l' to pick up the function immediately."
  echo "You can check the stack with 'docker compose ps'."
}

# MAIN FUNCTION - with proper error handling
main() {
  debug "Starting main function"
  
  # Change to the repository root directory
  cd "$ROOT_DIR"
  
  mkdir -p "$STATE_DIR"
  set_owner_if_needed "$STATE_DIR"
  
  # Ensure scripts are executable
  ensure_executable "$ROOT_DIR/scripts/set-proxy.sh" 2>/dev/null || true
  ensure_executable "$ROOT_DIR/scripts/load-image.sh" 2>/dev/null || true
  ensure_executable "$ROOT_DIR/scripts/install-docker.sh" 2>/dev/null || true
  ensure_executable "$ROOT_DIR/entrypoint.sh" 2>/dev/null || true
  ensure_executable "$ROOT_DIR/HiddifyCli" 2>/dev/null || true
  
  # Run the setup steps
  configure_env_file
  ensure_docker
  ensure_image_loaded
  
  # Make sure we're in the right directory for docker compose
  cd "$ROOT_DIR"
  
  deploy_stack
  setup_aliases
  
  # Create auto-enable file
  touch "$AUTO_ENABLE_FILE" 2>/dev/null || true
  set_owner_if_needed "$AUTO_ENABLE_FILE" 2>/dev/null || true
  
  install_proxy_command
  
  # THIS IS CRITICAL - Call enable_proxy_toggle to show IP/location
  # Wrap in error handling to ensure it runs
  debug "About to call enable_proxy_toggle"
  enable_proxy_toggle || {
    warn "Failed to verify proxy, but setup is complete."
    echo "  Try testing manually: curl --proxy http://127.0.0.1:$(get_env_value PROXY_PORT "$ENV_FILE") https://icanhazip.com"
  }
  
  # Show summary
  summarise
  
  debug "Main function complete"
}

# Run main and ensure we don't exit early
main "$@" || {
  exit_code=$?
  warn "Setup encountered an issue (exit code: $exit_code)"
  exit $exit_code
}

# Explicitly reach the end
debug "Script completed successfully"
exit 0