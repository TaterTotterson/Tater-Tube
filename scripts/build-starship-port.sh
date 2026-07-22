#!/usr/bin/env bash
# Build Tater Tube's pinned Starship engine without any game ROM or extracted game assets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:?Usage: build-starship-port.sh OUTPUT_DIR}"
UPSTREAM_URL="${STARSHIP_URL:-https://github.com/HarbourMasters/Starship.git}"
UPSTREAM_REF="${STARSHIP_REF:-cb19785b51698185a688e17ba1a34c7889195bdb}"
PATCH_FILE="${STARSHIP_PATCH:-${REPO_ROOT}/packaging/ports/starship/tater-tube.patch}"
CRT_PATCH_FILE="${STARSHIP_CRT_PATCH:-${REPO_ROOT}/packaging/ports/starship/crt-display.patch}"
BUILD_ROOT="${STARSHIP_BUILD_ROOT:-${TMPDIR:-/tmp}/tater-tube-starship-build}"
BUILD_JOBS="${STARSHIP_BUILD_JOBS:-3}"
SOURCE_DIR="${BUILD_ROOT}/source"
BUILD_DIR="${BUILD_ROOT}/build"

for command in cmake git ninja python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done
if [ ! -f "${PATCH_FILE}" ]; then
    echo "Starship patch not found: ${PATCH_FILE}" >&2
    exit 1
fi
if [ ! -f "${CRT_PATCH_FILE}" ]; then
    echo "Starship CRT display patch not found: ${CRT_PATCH_FILE}" >&2
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
cmake --build "${BUILD_DIR}" --target GeneratePortO2R --parallel "${BUILD_JOBS}"
cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"

install -m 0755 "${BUILD_DIR}/Starship" "${OUTPUT_DIR}/Starship"
install -m 0644 "${BUILD_DIR}/starship.o2r" "${OUTPUT_DIR}/starship.o2r"
install -m 0644 "${SOURCE_DIR}/config.yml" "${OUTPUT_DIR}/config.yml"
cmake -E make_directory "${OUTPUT_DIR}/assets"
cp -a "${SOURCE_DIR}/assets/yaml" "${OUTPUT_DIR}/assets/"
if [ -f "${BUILD_DIR}/gamecontrollerdb.txt" ]; then
    install -m 0644 "${BUILD_DIR}/gamecontrollerdb.txt" "${OUTPUT_DIR}/gamecontrollerdb.txt"
elif [ -f "${SOURCE_DIR}/libultraship/extern/gamecontrollerdb.txt" ]; then
    install -m 0644 "${SOURCE_DIR}/libultraship/extern/gamecontrollerdb.txt" "${OUTPUT_DIR}/gamecontrollerdb.txt"
fi

cmake -E make_directory "${OUTPUT_DIR}/LICENSES"
install -m 0644 "${SOURCE_DIR}/LICENSE.md" "${OUTPUT_DIR}/LICENSES/Starship.txt"
install -m 0644 "${SOURCE_DIR}/libultraship/LICENSE" "${OUTPUT_DIR}/LICENSES/libultraship.txt"
install -m 0644 "${SOURCE_DIR}/tools/Torch/LICENSE" "${OUTPUT_DIR}/LICENSES/Torch.txt"

cat > "${OUTPUT_DIR}/starship" <<'EOF'
#!/bin/sh
set -eu

engine_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
user_root="${TATER_TUBE_PORT_USER_ROOT:-}"
if [ -z "${user_root}" ]; then
    user_root="${XDG_DATA_HOME:-${HOME}/.local/share}/tater-tube/ports/starship/user"
fi
mkdir -p "${user_root}"
export SHIP_HOME="${user_root}"
if [ -d "${engine_dir}/lib" ]; then
    export LD_LIBRARY_PATH="${engine_dir}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
for support_path in config.yml assets; do
    if [ ! -e "${user_root}/${support_path}" ]; then
        ln -s "${engine_dir}/${support_path}" "${user_root}/${support_path}"
    fi
done
cd "${user_root}"
exec "${engine_dir}/Starship" "$@"
EOF
chmod 0755 "${OUTPUT_DIR}/starship"

cat > "${OUTPUT_DIR}/SOURCE.txt" <<EOF
Starship 2.0.0 (${UPSTREAM_REF})
Source: ${UPSTREAM_URL}
Tater Tube patches: tater-tube.patch, crt-display.patch
Build options: Release
License: CC0-1.0
No ROM, generated sf64.o2r, BIOS, or copyrighted Star Fox 64 game data is included.
The bundled starship.o2r contains only the port project's original assets.
EOF

if find "${OUTPUT_DIR}" -type f \
        \( -iname 'sf64.o2r' -o -iname 'baserom*' \
           -o -iname '*.z64' -o -iname '*.n64' -o -iname '*.v64' \) \
        -print -quit | grep -q .; then
    echo "Refusing a Starship bundle containing a ROM or generated game archive." >&2
    exit 1
fi

echo "Starship Tater Tube engine written to ${OUTPUT_DIR}"
