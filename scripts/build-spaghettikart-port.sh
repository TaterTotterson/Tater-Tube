#!/usr/bin/env bash
# Build Tater Tube's pinned SpaghettiKart engine without any game ROM or extracted game assets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:?Usage: build-spaghettikart-port.sh OUTPUT_DIR}"
UPSTREAM_URL="${SPAGHETTIKART_URL:-https://github.com/HarbourMasters/SpaghettiKart.git}"
UPSTREAM_REF="${SPAGHETTIKART_REF:-1732542a6a200a21a9112a75820517a754d9514a}"
PATCH_FILE="${SPAGHETTIKART_PATCH:-${REPO_ROOT}/packaging/ports/spaghettikart/tater-tube.patch}"
CRT_PATCH_FILE="${SPAGHETTIKART_CRT_PATCH:-${REPO_ROOT}/packaging/ports/spaghettikart/crt-display.patch}"
BUILD_ROOT="${SPAGHETTIKART_BUILD_ROOT:-${TMPDIR:-/tmp}/tater-tube-spaghettikart-build}"
BUILD_JOBS="${SPAGHETTIKART_BUILD_JOBS:-3}"
SOURCE_DIR="${BUILD_ROOT}/source"
BUILD_DIR="${BUILD_ROOT}/build"

for command in cmake git ninja python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done
if [ ! -f "${PATCH_FILE}" ]; then
    echo "SpaghettiKart patch not found: ${PATCH_FILE}" >&2
    exit 1
fi
if [ ! -f "${CRT_PATCH_FILE}" ]; then
    echo "SpaghettiKart CRT display patch not found: ${CRT_PATCH_FILE}" >&2
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
cmake --build "${BUILD_DIR}" --target GenerateO2R --parallel "${BUILD_JOBS}"
cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"

install -m 0755 "${BUILD_DIR}/Spaghettify" "${OUTPUT_DIR}/Spaghettify"
install -m 0644 "${BUILD_DIR}/spaghetti.o2r" "${OUTPUT_DIR}/spaghetti.o2r"
install -m 0644 "${SOURCE_DIR}/config.yml" "${OUTPUT_DIR}/config.yml"
cp -a "${SOURCE_DIR}/yamls" "${OUTPUT_DIR}/yamls"
cp -a "${SOURCE_DIR}/meta" "${OUTPUT_DIR}/meta"
if [ -f "${BUILD_DIR}/gamecontrollerdb.txt" ]; then
    install -m 0644 "${BUILD_DIR}/gamecontrollerdb.txt" "${OUTPUT_DIR}/gamecontrollerdb.txt"
fi

cmake -E make_directory "${OUTPUT_DIR}/LICENSES"
install -m 0644 "${SOURCE_DIR}/libultraship/LICENSE" "${OUTPUT_DIR}/LICENSES/libultraship.txt"
install -m 0644 "${SOURCE_DIR}/torch/LICENSE" "${OUTPUT_DIR}/LICENSES/torch.txt"
install -m 0644 "${SOURCE_DIR}/torch/lib/StormLib/LICENSE" "${OUTPUT_DIR}/LICENSES/StormLib.txt"

cat > "${OUTPUT_DIR}/spaghettikart" <<'EOF'
#!/bin/sh
set -eu

engine_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
user_root="${TATER_TUBE_PORT_USER_ROOT:-}"
if [ -z "${user_root}" ]; then
    user_root="${XDG_DATA_HOME:-${HOME}/.local/share}/tater-tube/ports/spaghettikart/user"
fi
mkdir -p "${user_root}"
export SHIP_HOME="${user_root}"
if [ -d "${engine_dir}/lib" ]; then
    export LD_LIBRARY_PATH="${engine_dir}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
cd "${user_root}"
exec "${engine_dir}/Spaghettify" "$@"
EOF
chmod 0755 "${OUTPUT_DIR}/spaghettikart"

cat > "${OUTPUT_DIR}/SOURCE.txt" <<EOF
SpaghettiKart 1.0.0 (${UPSTREAM_REF})
Source: ${UPSTREAM_URL}
Tater Tube patches: tater-tube.patch, crt-display.patch
Build options: Release
Redistribution permission confirmed by the Tater Tube project owner.
No ROM, generated mk64.o2r, BIOS, or copyrighted Mario Kart 64 game data is included.
The bundled spaghetti.o2r contains only the port project's original assets.
EOF

if find "${OUTPUT_DIR}" -type f \
        \( -iname 'mk64.o2r' -o -iname 'baserom*' \
           -o -iname '*.z64' -o -iname '*.n64' -o -iname '*.v64' \) \
        -print -quit | grep -q .; then
    echo "Refusing a SpaghettiKart bundle containing a ROM or generated game archive." >&2
    exit 1
fi

echo "SpaghettiKart Tater Tube engine written to ${OUTPUT_DIR}"
