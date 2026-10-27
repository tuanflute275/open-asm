#!/usr/bin/env bash
set -euo pipefail

# Phase 2 of an air-gapped deployment: run this ON the offline server, from
# inside the folder extracted from the tarball built by airgap-bundle.sh.
# This script never contacts the network — every image must already be
# loaded from images/all-images.tar, and every config value is generated
# locally with openssl.
#
# Prerequisites on this server (not handled here — each needs its own
# offline install path, which varies per environment):
#   - Docker Engine + Docker Compose v2 plugin, already installed
#   - This bundle's extracted folder, already copied here
#
# Usage:
#   APP_HTTP_PORT=8080 bash airgap-deploy.sh     # optional, default port 80

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

http_port="${APP_HTTP_PORT:-80}"
[[ "$http_port" =~ ^[0-9]{1,5}$ ]] || fail "APP_HTTP_PORT must be a number"

[[ -f docker-compose.yml ]] || fail "run from inside the extracted bundle directory"
[[ -f images/all-images.tar ]] || fail "images/all-images.tar not found — re-run airgap-bundle.sh"
command -v docker >/dev/null 2>&1 || fail "Docker is not installed on this server"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin is required"
command -v openssl >/dev/null 2>&1 || fail "openssl is required to generate secrets"

printf 'Loading images from the bundle (no network access used)...\n'
docker load -i images/all-images.tar

root_env=".env"
if [[ -f "$root_env" ]]; then
  printf 'Reusing existing %s (delete it to regenerate secrets).\n' "$root_env"
else
  postgres_password="$(openssl rand -hex 32)"
  redis_password="$(openssl rand -hex 32)"
  encryption_key="$(openssl rand -hex 32)"
  api_key="$(openssl rand -hex 32)"
  rustfs_access="oasm-$(openssl rand -hex 16)"
  rustfs_secret="$(openssl rand -hex 32)"
  bridge_ip="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
  [[ "$bridge_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "could not determine Docker's bridge IPv4 address"
  # Native Linux docker.sock is normally root:docker (group-writable) — the
  # worker's non-root user just needs that gid in group_add. If this server's
  # socket turns out to be owner-only (seen on some Docker Desktop builds,
  # never on a real Linux host), group_add can't help; run the worker as root
  # instead via a local docker-compose.override.yml (see AGENTS.md gotcha 12
  # and the oasm-worker comment block in docker-compose.yml for the full
  # explanation of why).
  socket_gid="$(stat -c '%g' /var/run/docker.sock)"
  [[ "$socket_gid" =~ ^[0-9]+$ ]] || fail "could not determine the Docker socket's group id"

  cat > "$root_env" <<EOF
APP_HTTP_PORT=$http_port
DOCKER_HOST_GATEWAY_IP=$bridge_ip
WORKER_DOCKER_GID=$socket_gid
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=$postgres_password
POSTGRES_DB=open_asm
OASM_CLOUD_APIKEY=$api_key
WORKER_API_KEY=$api_key
REDIS_PASSWORD=$redis_password
REDIS_URL=redis://:$redis_password@redis:6379/0
ENCRYPTION_KEYS=$encryption_key
RUSTFS_ACCESS_KEY=$rustfs_access
RUSTFS_SECRET_KEY=$rustfs_secret
EOF
  chmod 0600 "$root_env"

  mkdir -p core-api worker console
  cat > core-api/.env <<EOF
POSTGRES_HOST=postgres
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=$postgres_password
POSTGRES_PORT=5432
POSTGRES_DB=open_asm
POSTGRES_SSL=false
PORT=6276
GRPC_PORT=16276
OASM_CLOUD_APIKEY=$api_key
REDIS_URL=redis://:$redis_password@redis:6379/0
GEO_IP_URL=geo-ip:4360
ENCRYPTION_KEYS=$encryption_key
RUSTFS_ENDPOINT=http://rustfs:9000
RUSTFS_ACCESS_KEY=$rustfs_access
RUSTFS_SECRET_KEY=$rustfs_secret
AUDIT_ARCHIVE_DIR=./audit-archive
EOF
  cat > worker/.env <<EOF
WORKER_API_KEY=$api_key
WORKER_GRPC_HOST=core-api
WORKER_GRPC_PORT=16276
EOF
  cp console.example.env console/.env 2>/dev/null || touch console/.env
  chmod 0600 core-api/.env worker/.env console/.env
  printf 'Generated application secrets in private .env files.\n'
fi

mkdir -p core-api worker console
[[ -f core-api/.env ]] || fail "core-api/.env missing — delete $root_env and rerun to regenerate"
[[ -f worker/.env ]] || fail "worker/.env missing — delete $root_env and rerun to regenerate"
[[ -f console/.env ]] || cp console.example.env console/.env 2>/dev/null || touch console/.env

compose_override="$(mktemp ./.airgap-compose-override.XXXXXX.yml)"
trap 'rm -f "$compose_override"' EXIT
cat > "$compose_override" <<'YAML'
services:
  console:
    ports: !reset
      - "${APP_HTTP_PORT:-80}:80"
  core-api:
    environment:
      OASM_CLOUD_APIKEY: "${OASM_CLOUD_APIKEY:?missing OASM_CLOUD_APIKEY}"
      REDIS_URL: "${REDIS_URL:?missing REDIS_URL}"
    healthcheck:
      start_period: 120s
  oasm-worker:
    ports: !reset
      - "${DOCKER_HOST_GATEWAY_IP:?missing Docker bridge IP}:26276:26276"
    environment:
      WORKER_API_KEY: "${WORKER_API_KEY:?missing WORKER_API_KEY}"
  redis:
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD:?missing REDIS_PASSWORD}"]
  rustfs:
    environment:
      RUSTFS_ACCESS_KEY: "${RUSTFS_ACCESS_KEY:?missing RUSTFS_ACCESS_KEY}"
      RUSTFS_SECRET_KEY: "${RUSTFS_SECRET_KEY:?missing RUSTFS_SECRET_KEY}"
YAML

set -a
# shellcheck disable=SC1090
source "$root_env"
set +a

compose=(docker compose -f docker-compose.yml -f "$compose_override")
"${compose[@]}" config --quiet
# No `pull` step on purpose: every image must already be local (docker load
# above), and --no-build skips any build attempt that would need a package
# registry. If an image is missing, this fails fast instead of reaching out.
"${compose[@]}" up -d --no-build --wait --wait-timeout 300

curl -fsS --max-time 15 "http://127.0.0.1:${http_port}/api/health" >/dev/null ||
  fail "containers started, but the application health endpoint did not respond"

printf '\nOpen-ASM is running, fully offline.\n'
printf 'Open this URL from a browser on the internal network: http://<this-server-internal-ip>:%s\n' "$http_port"
printf 'Create the first account in the web interface; no default login is configured.\n'
printf '\nKnown offline limitations:\n'
printf ' - AI Studio chat/agents need a reachable LLM API. Without internet, configure an\n'
printf '   agent provider of type CUSTOM pointing at an internal/self-hosted LLM endpoint\n'
printf '   (e.g. vLLM, Ollama) if you have one; otherwise skip that feature.\n'
printf ' - A GitHub release-version check and the models.dev pricing catalog fetch will\n'
printf '   fail silently on every boot / every ~12h — logged errors, no functional impact.\n'
printf ' - Only the connector images bundled by airgap-bundle.sh are usable. To add more\n'
printf '   later, rerun airgap-bundle.sh --connectors <names> on a connected machine and\n'
printf '   `docker load` the new tar on this server.\n'
