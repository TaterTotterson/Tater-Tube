#!/usr/bin/env bash
# Build Tater Tube's pinned sm64coopdx engine without any Nintendo ROM or assets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:?Usage: build-sm64coopdx-port.sh OUTPUT_DIR}"
UPSTREAM_URL="${SM64COOPDX_URL:-https://github.com/coop-deluxe/sm64coopdx.git}"
UPSTREAM_REF="${SM64COOPDX_REF:-8cd6e5977d9f920d51ca71f2c61801d019ed79c6}"
PATCH_FILE="${SM64COOPDX_PATCH:-${REPO_ROOT}/packaging/ports/sm64coopdx/exit-to-tater-tube.patch}"
BUILD_ROOT="${SM64COOPDX_BUILD_ROOT:-${TMPDIR:-/tmp}/tater-tube-sm64coopdx-build}"
BUILD_JOBS="${SM64COOPDX_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
SOURCE_DIR="${BUILD_ROOT}/source"

for command in git make python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done
if [ ! -f "${PATCH_FILE}" ]; then
    echo "sm64coopdx patch not found: ${PATCH_FILE}" >&2
    exit 1
fi

rm -rf "${SOURCE_DIR}" "${OUTPUT_DIR}"
mkdir -p "${BUILD_ROOT}" "${OUTPUT_DIR}"
git clone --filter=blob:none --no-checkout "${UPSTREAM_URL}" "${SOURCE_DIR}"
git -C "${SOURCE_DIR}" checkout --detach "${UPSTREAM_REF}"
test "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" = "${UPSTREAM_REF}"
git -C "${SOURCE_DIR}" apply --check "${PATCH_FILE}"
git -C "${SOURCE_DIR}" apply "${PATCH_FILE}"

BUILD_LOG="${BUILD_ROOT}/build.log"
if ! make -C "${SOURCE_DIR}" -j"${BUILD_JOBS}" \
        HANDHELD=1 \
        DISCORD_SDK=0 \
        UPDATER=0 >"${BUILD_LOG}" 2>&1; then
    echo "sm64coopdx build failed; final compiler output:" >&2
    tail -n 160 "${BUILD_LOG}" >&2
    exit 1
fi

BUILD_OUTPUT="${SOURCE_DIR}/build/us_pc"
ENGINE_BINARY="${BUILD_OUTPUT}/sm64coopdx"
if [ ! -x "${ENGINE_BINARY}" ]; then
    ENGINE_BINARY="${BUILD_OUTPUT}/sm64coopdx.arm"
fi
if [ ! -x "${ENGINE_BINARY}" ]; then
    echo "sm64coopdx build did not produce a supported engine binary." >&2
    exit 1
fi
install -m 0755 "${ENGINE_BINARY}" "${OUTPUT_DIR}/sm64coopdx"
for directory in dynos lang mods palettes; do
    cp -a "${BUILD_OUTPUT}/${directory}" "${OUTPUT_DIR}/${directory}"
done

cat > "${OUTPUT_DIR}/SOURCE.txt" <<EOF
sm64coopdx ${UPSTREAM_REF}
Source: ${UPSTREAM_URL}
Tater Tube patch: exit-to-tater-tube.patch
Build options: HANDHELD=1 DISCORD_SDK=0 UPDATER=0
No ROM, extracted ROM asset, BIOS, or Nintendo-owned game data is included.
EOF

if find "${OUTPUT_DIR}" -type f \
        \( -iname 'baserom*' -o -iname '*.z64' -o -iname '*.n64' -o -iname '*.v64' \) \
        -print -quit | grep -q .; then
    echo "Refusing a port bundle containing a ROM." >&2
    exit 1
fi

echo "sm64coopdx Tater Tube engine written to ${OUTPUT_DIR}"
