#!/bin/bash
# Build on Linux inside Docker, including on Apple silicon Macs. Does not access a device.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE" && pwd)
IMAGE=athena-kbuild:debian13
VOLUME=athena-kbuild
OUT=${OUT:-$ROOT/build}
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
# The image is for the host: build.sh cross compiles with aarch64-linux-gnu-, so an arm64 image on
# another host would only run the cross compiler under emulation.
log "Building or refreshing Docker build environment ($IMAGE)"
docker build --progress=plain -t "$IMAGE" -f "$HERE/Dockerfile.build" "$HERE"
log "Docker build environment is ready"
log "Starting kernel build in container athena-kbuild (JOBS=${JOBS:-4})"
docker volume create "$VOLUME" >/dev/null
CONTAINER=$(docker create --rm --name athena-kbuild \
    -v "$ROOT:/repo:ro" \
    --mount "type=volume,src=$VOLUME,dst=/athena-kbuild" \
    -v "$OUT:/out" \
    -e WORK=/athena-kbuild -e OUT=/out -e JOBS="${JOBS:-4}" \
    "$IMAGE" bash /repo/build.sh)
trap 'docker rm -f athena-kbuild >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker start --attach "$CONTAINER" &
wait "$!"
log "Kernel build container finished successfully; artifacts are in $OUT"
