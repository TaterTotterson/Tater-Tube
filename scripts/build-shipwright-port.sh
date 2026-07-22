#!/usr/bin/env bash
# Build Tater Tube's pinned Ship of Harkinian engine without any game ROM or extracted game assets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:?Usage: build-shipwright-port.sh OUTPUT_DIR}"
UPSTREAM_URL="${SHIPWRIGHT_URL:-https://github.com/HarbourMasters/Shipwright.git}"
UPSTREAM_REF="${SHIPWRIGHT_REF:-cb71e22a79bc5d1f688fa881795bbd93094895fc}"
PATCH_FILE="${SHIPWRIGHT_PATCH:-${REPO_ROOT}/packaging/ports/shipwright/tater-tube.patch}"
CRT_PATCH_FILE="${SHIPWRIGHT_CRT_PATCH:-${REPO_ROOT}/packaging/ports/shipwright/crt-display.patch}"
BUILD_ROOT="${SHIPWRIGHT_BUILD_ROOT:-${TMPDIR:-/tmp}/tater-tube-shipwright-build}"
BUILD_JOBS="${SHIPWRIGHT_BUILD_JOBS:-3}"
SOURCE_DIR="${BUILD_ROOT}/source"
BUILD_DIR="${BUILD_ROOT}/build"

for command in cmake git ninja python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done
if [ ! -f "${PATCH_FILE}" ]; then
    echo "Shipwright patch not found: ${PATCH_FILE}" >&2
    exit 1
fi
if [ ! -f "${CRT_PATCH_FILE}" ]; then
    echo "Shipwright CRT display patch not found: ${CRT_PATCH_FILE}" >&2
    exit 1
fi

cmake -E remove_directory "${SOURCE_DIR}"
cmake -E remove_directory "${BUILD_DIR}"
cmake -E remove_directory "${OUTPUT_DIR}"
cmake -E make_directory "${BUILD_ROOT}"
cmake -E make_directory "${OUTPUT_DIR}"

git clone --filter=blob:none --no-checkout "${UPSTREAM_URL}" "${SOURCE_DIR}"
git -C "${SOURCE_DIR}" checkout --detach "${UPSTREAM_REF}"
test "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" = "${UPSTREAM_REF}"
git -C "${SOURCE_DIR}" submodule update --init --recursive --depth 1
git -C "${SOURCE_DIR}" apply --check "${PATCH_FILE}"
git -C "${SOURCE_DIR}" apply "${PATCH_FILE}"
git -C "${SOURCE_DIR}/libultraship" apply --check "${CRT_PATCH_FILE}"
git -C "${SOURCE_DIR}/libultraship" apply "${CRT_PATCH_FILE}"

cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS=-w \
    -DCMAKE_CXX_FLAGS=-w
cmake --build "${BUILD_DIR}" --target GenerateSohOtr --parallel "${BUILD_JOBS}"
cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"

install -m 0755 "${BUILD_DIR}/soh/soh.elf" "${OUTPUT_DIR}/soh.elf"
install -m 0644 "${BUILD_DIR}/soh/soh.o2r" "${OUTPUT_DIR}/soh.o2r"
if [ -f "${BUILD_DIR}/gamecontrollerdb.txt" ]; then
    install -m 0644 "${BUILD_DIR}/gamecontrollerdb.txt" "${OUTPUT_DIR}/gamecontrollerdb.txt"
fi

cmake -E make_directory "${OUTPUT_DIR}/assets"
cp -a "${SOURCE_DIR}/soh/assets/extractor/." "${OUTPUT_DIR}/assets/"
cp -a "${SOURCE_DIR}/soh/assets/xml" "${OUTPUT_DIR}/assets/xml"
zapd_binary="$(find "${BUILD_DIR}" -type f -name 'ZAPD.out' -perm -111 -print -quit)"
if [ -n "${zapd_binary}" ]; then
    cmake -E make_directory "${OUTPUT_DIR}/assets/extractor"
    install -m 0755 "${zapd_binary}" "${OUTPUT_DIR}/assets/extractor/ZAPD.out"
fi

cmake -E make_directory "${OUTPUT_DIR}/LICENSES"
install -m 0644 "${SOURCE_DIR}/libultraship/LICENSE" "${OUTPUT_DIR}/LICENSES/libultraship.txt"
install -m 0644 "${SOURCE_DIR}/OTRExporter/LICENSE" "${OUTPUT_DIR}/LICENSES/OTRExporter.txt"
install -m 0644 "${SOURCE_DIR}/ZAPDTR/LICENSE" "${OUTPUT_DIR}/LICENSES/ZAPDTR.txt"

cat > "${OUTPUT_DIR}/shipwright" <<'EOF'
#!/bin/sh
set -eu

engine_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
user_root="${TATER_TUBE_PORT_USER_ROOT:-}"
if [ -z "${user_root}" ]; then
    user_root="${XDG_DATA_HOME:-${HOME}/.local/share}/tater-tube/ports/shipwright/user"
fi
mkdir -p "${user_root}"
export SHIP_HOME="${user_root}"
if [ -d "${engine_dir}/lib" ]; then
    export LD_LIBRARY_PATH="${engine_dir}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
cd "${user_root}"
exec "${engine_dir}/soh.elf" "$@"
EOF
chmod 0755 "${OUTPUT_DIR}/shipwright"

cat > "${OUTPUT_DIR}/SOURCE.txt" <<EOF
Ship of Harkinian 9.2.3 (${UPSTREAM_REF})
Source: ${UPSTREAM_URL}
Tater Tube patches: tater-tube.patch, crt-display.patch
Build options: Release
Redistribution permission confirmed by the Tater Tube project owner.
No ROM, generated oot.o2r/oot-mq.o2r, BIOS, or copyrighted Ocarina of Time game data is included.
The bundled soh.o2r contains only the port project's original assets.
EOF

if find "${OUTPUT_DIR}" -type f \
        \( -iname 'oot.o2r' -o -iname 'oot-mq.o2r' -o -iname 'oot.otr' \
           -o -iname 'baserom*' -o -iname '*.z64' -o -iname '*.n64' -o -iname '*.v64' \) \
        -print -quit | grep -q .; then
    echo "Refusing a Shipwright bundle containing a ROM or generated game archive." >&2
    exit 1
fi

echo "Ship of Harkinian Tater Tube engine written to ${OUTPUT_DIR}"
