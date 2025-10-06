# Hiddify CLI Bundle

This repository ships the Hiddify CLI binary together with a prebuilt Docker image so that the stack can run without reaching the Docker hub.

## Files
- `HiddifyCli` – the upstream CLI executable bundled into the image.
- `Dockerfile` – minimal Debian-based image definition kept for reference.
- `entrypoint.sh` – runs the CLI, watches connectivity, and exposes it on all interfaces via `socat`.
- `docker-compose.yml` – runs the CLI container using local environment settings.
- `.env.example` – template for the required environment values. Copy to `.env` and edit before running.
- `image/hiddify-cli-offline.tar.xz` – exported Docker image (xz-compressed) ready to load in air-gapped environments.
- `load-image.sh` – helper that loads the exported image with `docker load`.

## Usage
1. `cp .env.example .env` and set `SUBSCRIPTION_URL` (and adjust the proxy port if needed).
2. `./load-image.sh` to import the bundled image (run once per host). The script auto-detects `.tar.xz` archives and pipes them into `docker load`.
3. `docker compose up -d` to start the proxy service.

The compose file publishes only the proxy port using the value from `.env`. Optional environment variables let you tune the self-healing monitor (check interval, failure threshold, health probe URL, restart grace).
