#!/usr/bin/env bash
# Build the reusable Raspberry Pi OS Trixie ARM64 runtime bundle locally.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:-${REPO_ROOT}/out/pi-runtime}"
IMAGE_NAME="${PI_RUNTIME_BUILDER_IMAGE:-tater-tube-pi-runtimes}"
BUILD_JOBS="${PI_RUNTIME_BUILD_JOBS:-4}"
DUSKLIGHT_BUILD_JOBS="${PI_DUSKLIGHT_BUILD_JOBS:-3}"

docker build \
    --platform linux/arm64 \
    --build-arg "BUILD_JOBS=${BUILD_JOBS}" \
    --build-arg "DUSKLIGHT_BUILD_JOBS=${DUSKLIGHT_BUILD_JOBS}" \
    -f "${REPO_ROOT}/packaging/pi/Dockerfile.runtimes" \
    -t "${IMAGE_NAME}" \
    "${REPO_ROOT}"

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
# The export image is intentionally FROM scratch and has no default command.
# docker create only needs a placeholder here because the container is never
# started; it exists solely so docker cp can read the packaged filesystem.
container_id="$(docker create --platform linux/arm64 "${IMAGE_NAME}" /bin/true)"
cleanup() {
    docker rm -f "${container_id}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker cp "${container_id}:/opt/tater-tube-runtimes/." "${OUTPUT_DIR}/"

echo "Raspberry Pi ARM64 runtimes written to ${OUTPUT_DIR}"
