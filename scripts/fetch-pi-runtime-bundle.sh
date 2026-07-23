#!/usr/bin/env bash
# Download and verify the immutable ARM64 runtime bundle pinned by the repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${PI_RUNTIME_BUNDLE_LOCK:-${REPO_ROOT}/packaging/pi/runtime-bundle.lock}"
OUTPUT_DIR="${1:-${REPO_ROOT}/out/pi-runtime}"

test -f "${LOCK_FILE}" || {
    echo "Pi runtime bundle lock not found: ${LOCK_FILE}" >&2
    exit 1
}
# shellcheck source=/dev/null
source "${LOCK_FILE}"
: "${PI_RUNTIME_BUNDLE_TAG:?Missing PI_RUNTIME_BUNDLE_TAG in lock}"
: "${PI_RUNTIME_BUNDLE_FILE:?Missing PI_RUNTIME_BUNDLE_FILE in lock}"
: "${PI_RUNTIME_BUNDLE_SHA256:?Missing PI_RUNTIME_BUNDLE_SHA256 in lock}"

repository="${PI_RUNTIME_BUNDLE_REPOSITORY:-TaterTotterson/Tater-Tube}"
url="https://github.com/${repository}/releases/download/${PI_RUNTIME_BUNDLE_TAG}/${PI_RUNTIME_BUNDLE_FILE}"
download_dir="$(mktemp -d)"
archive="${download_dir}/${PI_RUNTIME_BUNDLE_FILE}"
cleanup() {
    rm -rf "${download_dir}"
}
trap cleanup EXIT

curl -fL --retry 5 --retry-all-errors --connect-timeout 20 \
    -o "${archive}" "${url}"
if command -v sha256sum >/dev/null 2>&1; then
    echo "${PI_RUNTIME_BUNDLE_SHA256}  ${archive}" | sha256sum -c -
else
    actual_sha="$(shasum -a 256 "${archive}" | awk '{ print $1 }')"
    test "${actual_sha}" = "${PI_RUNTIME_BUNDLE_SHA256}"
fi
tar -tzf "${archive}" >/dev/null

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
tar -xzf "${archive}" -C "${OUTPUT_DIR}"

for required_path in \
    moonlight-sdl/bin/moonlight \
    moonlight-sdl/LICENSE \
    moonlight-sdl/SOURCE.txt \
    ports/sm64coopdx/sm64coopdx \
    ports/2ship2harkinian/2s2h.elf \
    ports/shipwright/soh.elf \
    ports/spaghettikart/Spaghettify \
    ports/starship/Starship \
    ports/dusklight/dusklight-bin; do
    test -f "${OUTPUT_DIR}/${required_path}"
done

echo "Verified Pi runtime bundle ${PI_RUNTIME_BUNDLE_TAG} in ${OUTPUT_DIR}"
