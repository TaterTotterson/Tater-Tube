#!/usr/bin/env bash
# Build Tater Tube's pinned Dusklight engine without any game disc image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:?Usage: build-dusklight-port.sh OUTPUT_DIR}"
UPSTREAM_URL="${DUSKLIGHT_URL:-https://github.com/TwilitRealm/dusklight.git}"
UPSTREAM_REF="${DUSKLIGHT_REF:-f5642f307384bd4b7b7a09f690e391152445c815}"
PATCH_FILE="${DUSKLIGHT_PATCH:-${REPO_ROOT}/packaging/ports/dusklight/tater-tube.patch}"
BUILD_ROOT="${DUSKLIGHT_BUILD_ROOT:-${TMPDIR:-/tmp}/tater-tube-dusklight-build}"
BUILD_JOBS="${DUSKLIGHT_BUILD_JOBS:-3}"
DAWN_PROVIDER="${DUSKLIGHT_DAWN_PROVIDER:-auto}"
SOURCE_DIR="${BUILD_ROOT}/source"
BUILD_DIR="${BUILD_ROOT}/build"
INSTALL_DIR="${BUILD_ROOT}/install"

for command in cmake git ninja python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done
case "$(uname -m)" in
    aarch64|arm64)
        for command in cargo rustc; do
            if ! command -v "${command}" >/dev/null 2>&1; then
                echo "Dusklight's ARM64 disc reader requires Rust 1.85 or newer (${command} is missing)." >&2
                exit 1
            fi
        done
        rust_minor="$(rustc --version | awk '{print $2}' | cut -d. -f2)"
        if [ -z "${rust_minor}" ] || [ "${rust_minor}" -lt 85 ]; then
            echo "Dusklight's ARM64 disc reader requires Rust 1.85 or newer." >&2
            exit 1
        fi
        ;;
esac
if [ ! -f "${PATCH_FILE}" ]; then
    echo "Dusklight patch not found: ${PATCH_FILE}" >&2
    exit 1
fi

cmake -E remove_directory "${SOURCE_DIR}"
cmake -E remove_directory "${BUILD_DIR}"
cmake -E remove_directory "${INSTALL_DIR}"
cmake -E remove_directory "${OUTPUT_DIR}"
cmake -E make_directory "${BUILD_ROOT}"
cmake -E make_directory "${OUTPUT_DIR}"

git clone --filter=blob:none --no-checkout "${UPSTREAM_URL}" "${SOURCE_DIR}"
git -C "${SOURCE_DIR}" checkout --detach "${UPSTREAM_REF}"
test "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" = "${UPSTREAM_REF}"
git -C "${SOURCE_DIR}" submodule update --init --recursive --depth 1
git -C "${SOURCE_DIR}" apply --check "${PATCH_FILE}"
git -C "${SOURCE_DIR}" apply "${PATCH_FILE}"

cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_DISABLE_FIND_PACKAGE_SQLite3=ON \
    -DAURORA_DAWN_PROVIDER="${DAWN_PROVIDER}" \
    -DAURORA_SDL3_PROVIDER=vendor \
    -DBUILD_SHARED_LIBS=OFF \
    -DDUSK_ENABLE_DISCORD=OFF \
    -DDUSK_ENABLE_SENTRY_NATIVE=OFF \
    -DDUSK_ENABLE_UPDATE_CHECKER=OFF \
    -DDUSK_PACKAGE_INSTALL=OFF
cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"
cmake --install "${BUILD_DIR}"

install -m 0755 "${INSTALL_DIR}/dusklight" "${OUTPUT_DIR}/dusklight-bin"
cmake -E copy_directory "${INSTALL_DIR}/res" "${OUTPUT_DIR}/res"
cmake -E make_directory "${OUTPUT_DIR}/LICENSES"
install -m 0644 "${SOURCE_DIR}/LICENSE.md" "${OUTPUT_DIR}/LICENSES/Dusklight-CC0-1.0.txt"
install -m 0644 "${SOURCE_DIR}/extern/aurora/LICENSE" "${OUTPUT_DIR}/LICENSES/Aurora-MIT.txt"

license_index=0
while IFS= read -r dependency_license; do
    license_index=$((license_index + 1))
    license_name="dependency-${license_index}-$(basename "${dependency_license}")"
    install -m 0644 "${dependency_license}" "${OUTPUT_DIR}/LICENSES/${license_name}"
done < <(find "${BUILD_DIR}/_deps" -type f \
    \( -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'COPYING' -o -iname 'COPYING.*' -o -iname 'NOTICE' -o -iname 'NOTICE.*' \) \
    2>/dev/null | sort)

cat > "${OUTPUT_DIR}/dusklight" <<'EOF'
#!/bin/sh
set -eu

engine_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -d "${engine_dir}/lib" ]; then
    export LD_LIBRARY_PATH="${engine_dir}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
if [ "${1:-}" = "--tater-validate-disc" ]; then
    cd "${engine_dir}"
    exec "${engine_dir}/dusklight-bin" "$@"
fi
user_root="${TATER_TUBE_PORT_USER_ROOT:-}"
if [ -z "${user_root}" ]; then
    user_root="${XDG_DATA_HOME:-${HOME}/.local/share}/tater-tube/ports/dusklight/user"
fi
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${user_root}/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${user_root}/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${user_root}/cache}"
mkdir -p "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_CACHE_HOME}"
cd "${engine_dir}"
exec "${engine_dir}/dusklight-bin" "$@"
EOF
chmod 0755 "${OUTPUT_DIR}/dusklight"

cat > "${OUTPUT_DIR}/SOURCE.txt" <<EOF
Dusklight 1.4.1 (${UPSTREAM_REF})
Source: ${UPSTREAM_URL}
Tater Tube patch: tater-tube.patch
Build options: Release, Vulkan, updater/Discord/Sentry disabled
License: CC0-1.0 (Aurora is MIT)
No Twilight Princess disc image, extracted game asset, BIOS, save, or credential is included.
At runtime Dusklight reads a supported user-owned GameCube USA or EUR disc image directly.
EOF

if find "${OUTPUT_DIR}" -type f \
        \( -iname '*.iso' -o -iname '*.gcm' -o -iname '*.ciso' \
           -o -iname '*.gcz' -o -iname '*.nfs' -o -iname '*.rvz' \
           -o -iname '*.wbfs' -o -iname '*.wia' -o -iname '*.tgc' \) \
        -print -quit | grep -q .; then
    echo "Refusing a Dusklight bundle containing a game disc image." >&2
    exit 1
fi

echo "Dusklight Tater Tube engine written to ${OUTPUT_DIR}"
