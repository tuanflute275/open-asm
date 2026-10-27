#!/usr/bin/env bash
set -euo pipefail

# Phase 1 of an air-gapped deployment: run on ANY machine that has internet
# and Docker (your laptop, a bastion host, a build server) to produce a single
# tarball containing every image Open-ASM needs. Copy that tarball to the
# offline server (USB stick, internal file share, scp through a jump host)
# and run airgap-deploy.sh there — the offline server never touches the
# network.
#
# What goes in the bundle, and why it's enough:
#   - oasm/oasm-api, oasm/oasm-console, oasm/oasm-worker: the published app
#     images (same ones deploy-vps.sh pulls). core-api already bundles the
#     worker's built-in tool archives (subfinder/httpx/naabu/dnsx/screenshot)
#     under public/archived/ at build time, so the worker never needs the
#     internet to fetch those — it downloads them from core-api over the
#     internal docker network.
#   - Postgres/Redis/RustFS/geo-ip: third-party images the stack depends on.
#   - Connector images (ghcr.io/oasm-platform/connector-*): the worker's
#     Docker runtime only pulls an image when it is NOT already present
#     locally (worker/internal/runtime/docker.go: imageIsCached inspects
#     before pulling) — so pre-loading these with `docker load` means a scan
#     never triggers a real network pull on the offline server.
#
# Usage:
#   bash scripts/airgap-bundle.sh [--out DIR] [--tag TAG] [--connectors LIST]
#
# Run from the repository root.

readonly MANIFEST="core-api/resources/connectors/manifest.json"

out_dir="./airgap-bundle"
image_tag="latest"
connectors_filter=""

usage() {
  cat <<EOF
Usage: bash scripts/airgap-bundle.sh [options]

Pulls every image Open-ASM needs and packs them, plus docker-compose.yml and
example env files, into one tarball for transfer to a server with no
internet access.

Options:
  --out DIR          Output directory (default: ./airgap-bundle)
  --tag TAG          Tag of the published oasm/oasm-* images (default: latest)
  --connectors LIST  Comma-separated connector names to include, e.g.
                      "nuclei,nikto,katana" (default: all connectors listed
                      in $MANIFEST — safest, since the offline server cannot
                      fetch one later; use this to shrink the bundle)
  --help             Show this help

Must run from the repository root, on a machine with internet and Docker.
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --out) [[ $# -ge 2 ]] || fail "--out requires a path"; out_dir="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || fail "--tag requires a value"; image_tag="$2"; shift 2 ;;
    --connectors) [[ $# -ge 2 ]] || fail "--connectors requires a list"; connectors_filter="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown option: $1 (see --help)" ;;
  esac
done

[[ -f docker-compose.yml && -f "$MANIFEST" ]] ||
  fail "run from the open-asm repository root (docker-compose.yml / $MANIFEST not found)"
command -v docker >/dev/null 2>&1 || fail "Docker is required on this machine"

app_images=(
  "oasm/oasm-api:$image_tag"
  "oasm/oasm-console:$image_tag"
  "oasm/oasm-worker:$image_tag"
)
infra_images=(
  "pgvector/pgvector:pg17"
  "redis:alpine"
  "rustfs/rustfs:latest"
  "ghcr.io/l1ttps/geoip-proxy:latest"
)

mapfile -t all_connector_images < <(
  grep -oE '"image": *"[^"]+"' "$MANIFEST" | sed -E 's/"image": *"//; s/"$//'
)
[[ ${#all_connector_images[@]} -gt 0 ]] || fail "no connector images found in $MANIFEST"

connector_images=()
if [[ -z "$connectors_filter" ]]; then
  connector_images=("${all_connector_images[@]}")
else
  IFS=',' read -r -a wanted <<< "$connectors_filter"
  for name in "${wanted[@]}"; do
    name="$(printf '%s' "$name" | xargs)"
    match=""
    for img in "${all_connector_images[@]}"; do
      [[ "$img" == *"connector-$name:"* ]] && { match="$img"; break; }
    done
    [[ -n "$match" ]] || fail "no connector named '$name' in $MANIFEST"
    connector_images+=("$match")
  done
fi

all_images=("${app_images[@]}" "${infra_images[@]}" "${connector_images[@]}")

printf 'Pulling %d images (this downloads everything needed for a fully offline deploy):\n' "${#all_images[@]}"
for img in "${all_images[@]}"; do
  printf ' - %s\n' "$img"
  docker pull "$img"
done

mkdir -p "$out_dir/images"
printf '\nSaving all images into one tar (can take a while for 15 connector images)...\n'
docker save -o "$out_dir/images/all-images.tar" "${all_images[@]}"

cp docker-compose.yml "$out_dir/"
cp console/example.env "$out_dir/console.example.env" 2>/dev/null || : > "$out_dir/console.example.env"
cp "$MANIFEST" "$out_dir/connectors-manifest.json"
printf '%s\n' "${all_images[@]}" > "$out_dir/images.list"
[[ -f scripts/airgap-deploy.sh ]] && cp scripts/airgap-deploy.sh "$out_dir/"

bundle_file="${out_dir%/}.tar"
tar -C "$(dirname "$out_dir")" -cf "$bundle_file" "$(basename "$out_dir")"
bundle_size="$(du -h "$bundle_file" | cut -f1)"

printf '\nBundle ready: %s (%s)\n' "$bundle_file" "$bundle_size"
printf 'Copy this ONE file to the offline server (USB / internal file share / scp via a jump\n'
printf 'host), extract it, cd into the extracted folder, then run: bash airgap-deploy.sh\n'
