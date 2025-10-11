#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ARCHIVE_DIR="$ROOT_DIR/image"
BASE_NAME="hiddify-cli-offline.tar"
XZ_ARCHIVE="${ARCHIVE_DIR}/${BASE_NAME}.xz"
TAR_ARCHIVE="${ARCHIVE_DIR}/${BASE_NAME}"

# Helper function to run docker commands with proper user context
docker_cmd() {
  if [[ -n "${DOCKER_RUN_AS_USER:-}" ]]; then
    # If running as non-root user (Docker Desktop), don't use sudo
    "$@"
  else
    "$@"
  fi
}

if [[ -f "$XZ_ARCHIVE" ]]; then
  ARCHIVE_PATH="$XZ_ARCHIVE"
  ARCHIVE_KIND="xz"
elif [[ -f "$TAR_ARCHIVE" ]]; then
  ARCHIVE_PATH="$TAR_ARCHIVE"
  ARCHIVE_KIND="tar"
else
  echo "Archive not found. Expected $XZ_ARCHIVE or $TAR_ARCHIVE" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or not in PATH." >&2
  exit 1
fi

echo "Loading image from $ARCHIVE_PATH ..."

case "$ARCHIVE_KIND" in
  tar)
    docker_cmd docker load -i "$ARCHIVE_PATH"
    ;;
  xz)
    if ! command -v xz >/dev/null 2>&1; then
      echo "xz is required to decompress $ARCHIVE_PATH" >&2
      exit 1
    fi
    xz -dc "$ARCHIVE_PATH" | docker_cmd docker load
    ;;
  *)
    echo "Unsupported archive kind: $ARCHIVE_KIND" >&2
    exit 1
    ;;
esac

echo "Image load complete. Run 'docker compose up -d' to start the service."