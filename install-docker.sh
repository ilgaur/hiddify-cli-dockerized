#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root (or via sudo)." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ASSETS_DIR="$SCRIPT_DIR/docker-bin"
DOCKER_TGZ=$(ls "$ASSETS_DIR"/docker-*.tgz 2>/dev/null | head -n 1)
COMPOSE_BIN=$(ls "$ASSETS_DIR"/docker-compose-*-linux-x86_64 2>/dev/null | head -n 1)

if [ -z "$DOCKER_TGZ" ]; then
  echo "Docker archive not found in $ASSETS_DIR" >&2
  exit 1
fi

if [ -z "$COMPOSE_BIN" ]; then
  echo "Docker Compose binary not found in $ASSETS_DIR" >&2
  exit 1
fi

INSTALL_PREFIX="/usr/local"
BIN_DIR="$INSTALL_PREFIX/bin"
PLUGIN_DIR="$INSTALL_PREFIX/lib/docker/cli-plugins"

SYSTEMD_DIR="/etc/systemd/system"
DOCKER_SERVICE="$SYSTEMD_DIR/docker.service"
DOCKER_SOCKET="$SYSTEMD_DIR/docker.socket"
CONTAINERD_SERVICE="$SYSTEMD_DIR/containerd.service"
SYSTEMD_UNIT_MSG=""

mkdir -p "$BIN_DIR" "$PLUGIN_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

tar -xzf "$DOCKER_TGZ" -C "$TMPDIR"
cp -f "$TMPDIR"/docker/* "$BIN_DIR/"
chmod +x "$BIN_DIR"/docker*

install -m 0755 "$COMPOSE_BIN" "$PLUGIN_DIR/docker-compose"

if ! getent group docker >/dev/null 2>&1; then
  groupadd --system docker
fi

if command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$SYSTEMD_DIR"

  cat > "$DOCKER_SERVICE" <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service containerd.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF

  cat > "$DOCKER_SOCKET" <<'EOF'
[Unit]
Description=Docker Socket for the API
PartOf=docker.service

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

  cat > "$CONTAINERD_SERVICE" <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
Type=notify
ExecStart=/usr/local/bin/containerd
ExecReload=/bin/kill -s HUP $MAINPID
Restart=always
RestartSec=5s
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "$DOCKER_SERVICE" "$DOCKER_SOCKET" "$CONTAINERD_SERVICE"

  systemctl daemon-reload
  systemctl enable --now containerd.service
  systemctl enable --now docker.socket
  systemctl enable --now docker.service
  SYSTEMD_UNIT_MSG=" and enabled"
else
  echo "systemctl not found; Docker services were not configured automatically." >&2
  SYSTEMD_UNIT_MSG=" (manual systemctl enable/start required)"
fi

cat <<INFO
Docker binaries installed to $BIN_DIR
Docker Compose plugin installed to $PLUGIN_DIR/docker-compose

Docker systemd units have been installed${SYSTEMD_UNIT_MSG}.
INFO
