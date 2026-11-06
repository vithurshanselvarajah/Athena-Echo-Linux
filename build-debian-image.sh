#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

OUT=${1:?usage: build-debian-image.sh output/system.img [size]}

SIZE=${2:-1536M}

CACHE_DIR=${CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/athena/debian-arm64}

IMAGE=athena-rootfs-builder:debian13

command -v docker >/dev/null || { echo "Docker is required to build the Debian arm64 image" >&2; exit 1; }

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

OUT=$(mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")

mkdir -p "$CACHE_DIR"

CACHE_DIR=$(cd "$CACHE_DIR" && pwd)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/athena-rootfs.XXXXXX")

trap 'rm -rf "$WORK"' EXIT

log "Building Debian arm64 image (target size $SIZE); package setup may take several minutes under emulation"

docker build --platform linux/arm64 --progress=plain -t "$IMAGE" -f "$ROOT/Dockerfile.rootfs" "$ROOT"

docker run --rm --platform linux/arm64 \
	-v "$ROOT:/src:ro" -v "$WORK:/work" -v "$(dirname "$OUT"):/out" \
	-v "$CACHE_DIR:/cache" \
	"$IMAGE" bash /src/image/debian-arm64/mkrootfs.sh \
	-o "/out/$(basename "$OUT")" -w /work -s "$SIZE"

[ -s "$OUT" ] || { echo "system image was not created: $OUT" >&2; exit 1; }

log "Built image: $OUT ($(du -h "$OUT" | cut -f1))"
