#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${HIDDIFY_REPO_URL:-https://github.com/ilgaur/hiddify-cli-dockerized.git}"
ARCHIVE_URL="${HIDDIFY_REPO_ARCHIVE_URL:-https://github.com/ilgaur/hiddify-cli-dockerized/archive/refs/heads/main.tar.gz}"
DEFAULT_DIR="${HIDDIFY_INSTALL_DIR:-$HOME/hiddify-cli-dockerized}"
SKIP_SETUP="${HIDDIFY_INSTALLER_NO_SETUP:-0}"

info() { printf '[install] %s\n' "$*"; }
warn() { printf '[install][warn] %s\n' "$*" >&2; }

cleanup_tmp() {
  local dir="$1"
  [[ -d "$dir" ]] && rm -rf "$dir"
}

local_repo_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "stdin" && "${BASH_SOURCE[0]}" != "-" ]]; then
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  candidate_root=$(cd "$script_dir/.." && pwd)
  if [[ -f "$candidate_root/scripts/setup.sh" ]]; then
    local_repo_dir="$candidate_root"
  fi
fi

if [[ -n "$local_repo_dir" ]]; then
  info "Using existing repository at $local_repo_dir"
  repo_dir="$local_repo_dir"
else
  repo_dir="$DEFAULT_DIR"
  install_dir_parent=$(dirname "$repo_dir")
  mkdir -p "$install_dir_parent"

  if [[ -d "$repo_dir/.git" ]]; then
    info "Repository already cloned at $repo_dir; updating..."
    if command -v git >/dev/null 2>&1; then
      if ! git -C "$repo_dir" pull --ff-only; then
        warn "Unable to update repository automatically. Please resolve git state manually."
      fi
    else
      warn "git not available to update existing repository; continuing with current contents."
    fi
  elif [[ -d "$repo_dir" && -e "$repo_dir/scripts/setup.sh" ]]; then
    info "Using existing directory at $repo_dir."
  elif [[ -d "$repo_dir" ]]; then
    if [[ -z "$(ls -A "$repo_dir" 2>/dev/null)" ]]; then
      rmdir "$repo_dir"
    else
      warn "Directory $repo_dir exists but does not look like this project. Aborting."
      exit 1
    fi
  else
    if command -v git >/dev/null 2>&1; then
      info "Cloning repository into $repo_dir ..."
      git clone "$REPO_URL" "$repo_dir"
    else
      warn "git not found; falling back to tarball download."
      if ! command -v curl >/dev/null 2>&1; then
        warn "curl is required to download the repository when git is unavailable."
        exit 1
      fi
      if ! command -v tar >/dev/null 2>&1; then
        warn "tar is required to extract the repository archive."
        exit 1
      fi
      tmpdir=$(mktemp -d)
      trap 'cleanup_tmp "$tmpdir"' EXIT
      info "Downloading repository archive ..."
      if ! curl -fsSL "$ARCHIVE_URL" -o "$tmpdir/repo.tar.gz"; then
        warn "Failed to download repository archive."
        exit 1
      fi
      tar -xzf "$tmpdir/repo.tar.gz" -C "$tmpdir"
      extracted_dir=$(find "$tmpdir" -maxdepth 1 -type d -name '*hiddify-cli-dockerized*' -print -quit)
      if [[ -z "$extracted_dir" ]]; then
        warn "Unable to locate extracted repository directory."
        exit 1
      fi
      mv "$extracted_dir" "$repo_dir"
      info "Repository extracted to $repo_dir"
      cleanup_tmp "$tmpdir"
      trap - EXIT
    fi
  fi
fi

if [[ "${SKIP_SETUP}" == "1" ]]; then
  info "HIDDIFY_INSTALLER_NO_SETUP=1 set; skipping setup execution."
  exit 0
fi

setup_script="$repo_dir/scripts/setup.sh"
if [[ ! -x "$setup_script" ]]; then
  if [[ -f "$setup_script" ]]; then
    chmod +x "$setup_script"
  else
    warn "scripts/setup.sh not found in $repo_dir."
    exit 1
  fi
fi

if [[ $EUID -eq 0 ]]; then
  info "Running setup as root."
  bash "$setup_script"
else
  if command -v sudo >/dev/null 2>&1; then
    info "Running setup via sudo ..."
    sudo bash "$setup_script"
  else
    warn "sudo is required to run setup automatically. Please run: sudo $setup_script"
    exit 1
  fi
fi
