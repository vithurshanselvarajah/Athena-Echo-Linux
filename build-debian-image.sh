#!/bin/bash
# Build the minimal Debian arm64 Athena hardware bring-up system image in Docker.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build-debian-image.sh output/system.img [size]}
SIZE=${2:-1536M}
command -v docker >/dev/null || { echo "Docker is required to build the Debian arm64 image" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
OUT=$(mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/athena-bringup.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
log "Building Debian arm64 image (target size $SIZE); package setup may take several minutes under emulation"
docker run --rm --platform linux/arm64 \
	-v "$ROOT:/src:ro" -v "$WORK:/work" -v "$(dirname "$OUT"):/out" \
	debian:13-slim bash /src/image/debian-arm64/mkrootfs.sh \
	-o "/out/$(basename "$OUT")" -w /work -s "$SIZE"
[ -s "$OUT" ] || { echo "bring-up image was not created: $OUT" >&2; exit 1; }
log "Built image: $OUT ($(du -h "$OUT" | cut -f1))"
