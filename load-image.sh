#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_PATH="image/hiddify-cli-offline.tar"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Archive not found: $ARCHIVE_PATH" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or not in PATH." >&2
  exit 1
fi

echo "Loading image from $ARCHIVE_PATH ..."
docker load -i "$ARCHIVE_PATH"

echo "Image load complete. Run 'docker compose up -d' to start the service."
