#!/usr/bin/env bash
# Build Tater Tube's pinned 2 Ship 2 Harkinian engine without any game ROM or extracted game assets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:?Usage: build-2ship2harkinian-port.sh OUTPUT_DIR}"
UPSTREAM_URL="${TWO_SHIP_URL:-https://github.com/HarbourMasters/2ship2harkinian.git}"
UPSTREAM_REF="${TWO_SHIP_REF:-acfd617302ebb74e63f26f0049b53400a644c8e8}"
PATCH_FILE="${TWO_SHIP_PATCH:-${REPO_ROOT}/packaging/ports/2ship2harkinian/tater-tube.patch}"
CRT_PATCH_FILE="${TWO_SHIP_CRT_PATCH:-${REPO_ROOT}/packaging/ports/2ship2harkinian/crt-display.patch}"
BUILD_ROOT="${TWO_SHIP_BUILD_ROOT:-${TMPDIR:-/tmp}/tater-tube-2ship2harkinian-build}"
BUILD_JOBS="${TWO_SHIP_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
SOURCE_DIR="${BUILD_ROOT}/source"
BUILD_DIR="${BUILD_ROOT}/build"

for command in cmake git ninja python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done
if [ ! -f "${PATCH_FILE}" ]; then
    echo "2Ship patch not found: ${PATCH_FILE}" >&2
    exit 1
fi
if [ ! -f "${CRT_PATCH_FILE}" ]; then
    echo "2Ship CRT display patch not found: ${CRT_PATCH_FILE}" >&2
    exit 1
fi

rm -rf "${SOURCE_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"
mkdir -p "${BUILD_ROOT}" "${OUTPUT_DIR}"
git clone --filter=blob:none --no-checkout "${UPSTREAM_URL}" "${SOURCE_DIR}"
git -C "${SOURCE_DIR}" checkout --detach "${UPSTREAM_REF}"
test "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" = "${UPSTREAM_REF}"
git -C "${SOURCE_DIR}" submodule update --init --recursive --depth 1
git -C "${SOURCE_DIR}" apply --check "${PATCH_FILE}"
git -C "${SOURCE_DIR}" apply "${PATCH_FILE}"
git -C "${SOURCE_DIR}/libultraship" apply --check "${CRT_PATCH_FILE}"
git -C "${SOURCE_DIR}/libultraship" apply "${CRT_PATCH_FILE}"

cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" --target Generate2ShipOtr --parallel "${BUILD_JOBS}"
cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"

install -m 0755 "${BUILD_DIR}/mm/2s2h.elf" "${OUTPUT_DIR}/2s2h.elf"
install -m 0644 "${BUILD_DIR}/mm/2ship.o2r" "${OUTPUT_DIR}/2ship.o2r"
if [ -f "${BUILD_DIR}/gamecontrollerdb.txt" ]; then
    install -m 0644 "${BUILD_DIR}/gamecontrollerdb.txt" "${OUTPUT_DIR}/gamecontrollerdb.txt"
fi
mkdir -p "${OUTPUT_DIR}/assets"
cp -a "${SOURCE_DIR}/mm/assets/extractor/." "${OUTPUT_DIR}/assets/"
cp -a "${SOURCE_DIR}/mm/assets/xml" "${OUTPUT_DIR}/assets/xml"
zapd_binary="$(find "${BUILD_DIR}" -type f -name 'ZAPD.out' -perm -111 -print -quit)"
if [ -n "${zapd_binary}" ]; then
    mkdir -p "${OUTPUT_DIR}/assets/extractor"
    install -m 0755 "${zapd_binary}" "${OUTPUT_DIR}/assets/extractor/ZAPD.out"
fi
install -m 0644 "${SOURCE_DIR}/LICENSE" "${OUTPUT_DIR}/LICENSE.txt"

cat > "${OUTPUT_DIR}/2ship2harkinian" <<'EOF'
#!/bin/sh
set -eu

engine_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
user_root="${TATER_TUBE_PORT_USER_ROOT:-}"
if [ -z "${user_root}" ]; then
    user_root="${XDG_DATA_HOME:-${HOME}/.local/share}/tater-tube/ports/2ship2harkinian/user"
fi
mkdir -p "${user_root}"
export SHIP_HOME="${user_root}"
if [ -d "${engine_dir}/lib" ]; then
    export LD_LIBRARY_PATH="${engine_dir}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
cd "${user_root}"
exec "${engine_dir}/2s2h.elf" "$@"
EOF
chmod 0755 "${OUTPUT_DIR}/2ship2harkinian"

cat > "${OUTPUT_DIR}/SOURCE.txt" <<EOF
2 Ship 2 Harkinian 4.0.2 (${UPSTREAM_REF})
Source: ${UPSTREAM_URL}
Tater Tube patches: tater-tube.patch, crt-display.patch
Upstream crash fix: 754be5c5db4fcc429b7ff6df805436e9890dd877 (Disable SFX replacement)
Upstream Linux audio fixes: ae7f98d686b47b11086665883e1f0c0098d96f4b (PR #1745)
Build options: Release
No ROM, generated mm.o2r, BIOS, or copyrighted Majora's Mask game data is included.
The bundled 2ship.o2r contains only the port project's original assets.
EOF

if find "${OUTPUT_DIR}" -type f \
        \( -iname 'mm.o2r' -o -iname 'mm.otr' -o -iname 'mm.zip' \
           -o -iname 'baserom*' -o -iname '*.z64' -o -iname '*.n64' -o -iname '*.v64' \) \
        -print -quit | grep -q .; then
    echo "Refusing a 2Ship bundle containing a ROM or generated game archive." >&2
    exit 1
fi

echo "2 Ship 2 Harkinian Tater Tube engine written to ${OUTPUT_DIR}"
