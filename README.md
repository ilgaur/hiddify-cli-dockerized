# Hiddify CLI Bundle

This repository ships the Hiddify CLI binary together with a prebuilt Docker image so that the stack can run without reaching the Docker hub.

## Files
- `HiddifyCli` – the upstream CLI executable bundled into the image.
- `Dockerfile` – minimal Debian-based image definition kept for reference.
- `entrypoint.sh` – runs the CLI, watches connectivity, and exposes it on all interfaces via `socat`.
- `docker-compose.yml` – runs the CLI container using local environment settings.
- `.env.example` – template for the required environment values. Copy to `.env` and edit before running.
- `image/hiddify-cli-offline.tar.xz` – exported Docker image (xz-compressed) ready to load in air-gapped environments.
- `scripts/install.sh` – curl-install entrypoint that bootstraps the repo and runs setup.
- `scripts/setup.sh` – interactive bootstrapper that wires everything together.
- `scripts/load-image.sh` – helper that loads the exported image with `docker load`.
- `docker-bin/` – static Docker Engine and Compose binaries for offline installation.
- `scripts/install-docker.sh` – installs the bundled Docker binaries onto the host.
- `scripts/set-proxy.sh` – toggles local proxy environment variables for interactive shells.

## Quick start

Run the automated bootstrapper:

```bash
curl -fsSL https://raw.githubusercontent.com/ilgaur/hiddify-cli-dockerized/main/scripts/install.sh | bash
```

The installer checks out this repository (defaults to `~/hiddify-cli-dockerized`), keeps it up to date, and invokes the local `scripts/setup.sh` with sudo.

Already have the repo on disk? Run the setup directly:

```bash
sudo ./scripts/setup.sh
```

It will:

- ensure the helper scripts are executable
- collect the required environment values (subscription URL, ports, health-check tuning)
- install Docker & Compose from `docker-bin/` when missing (and add you to the `docker` group)
- load the bundled image, launch the stack, and register a `set-proxy` shell function system-wide (your shell reloads automatically at the end)
- prime the proxy toggle once so your next shell can use the local proxy immediately

## Manual usage
1. `cp .env.example .env` and set `SUBSCRIPTION_URL` (and adjust the proxy port if needed).
2. `./scripts/load-image.sh` to import the bundled image (run once per host). The script auto-detects `.tar.xz` archives and pipes them into `docker load`.
3. `docker compose up -d` to start the proxy service.

The compose file publishes only the proxy port using the value from `.env`. Optional environment variables let you tune the self-healing monitor (check interval, failure threshold, health probe URL, restart grace).

### Proxy toggle helper

On the next shell after setup, the proxy is enabled automatically so you can confirm the exit IP straight away. Afterwards, run `set-proxy` (function loaded from your shell profile) to toggle the proxy on demand. For scripting or status checks, use `source ./scripts/set-proxy.sh --status`.

### Installing Docker offline

If the target machine lacks Docker, copy this repository and run `sudo ./scripts/install-docker.sh`. The script installs the static `docker` CLI, daemon, Compose plugin (including a `docker-compose` shim) from `docker-bin/` into `/usr/local`, provisions matching systemd units, enables/starts both containerd and Docker (mirroring the official convenience script), and adds the invoking user to the `docker` group when possible. On systems without systemd the script prints a reminder to start the daemons manually.
