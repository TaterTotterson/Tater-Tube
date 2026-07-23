#!/usr/bin/env bash
# Package locally built Pi runtimes into a reusable, checksum-addressed archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INPUT_DIR="${1:-${REPO_ROOT}/out/pi-runtime}"
OUTPUT_FILE="${2:-${REPO_ROOT}/out/runtime-bundle/Tater-Tube-runtime-linux-arm64.tar.gz}"

for required_path in \
    moonlight-sdl/bin/moonlight \
    moonlight-sdl/LICENSE \
    moonlight-sdl/SOURCE.txt \
    ports/sm64coopdx/sm64coopdx \
    ports/sm64coopdx/SOURCE.txt \
    ports/2ship2harkinian/2s2h.elf \
    ports/2ship2harkinian/LICENSE.txt \
    ports/2ship2harkinian/SOURCE.txt \
    ports/shipwright/soh.elf \
    ports/shipwright/LICENSES/libultraship.txt \
    ports/shipwright/SOURCE.txt \
    ports/spaghettikart/Spaghettify \
    ports/spaghettikart/LICENSES/libultraship.txt \
    ports/spaghettikart/SOURCE.txt \
    ports/starship/Starship \
    ports/starship/LICENSES/Starship.txt \
    ports/starship/SOURCE.txt \
    ports/dusklight/dusklight-bin \
    ports/dusklight/LICENSES/Dusklight-CC0-1.0.txt \
    ports/dusklight/SOURCE.txt; do
    test -f "${INPUT_DIR}/${required_path}" || {
        echo "Pi runtime bundle input is incomplete: ${required_path}" >&2
        exit 1
    }
done

if find "${INPUT_DIR}" -type f \
        \( -iname '*.z64' -o -iname '*.n64' -o -iname '*.v64' \
           -o -iname '*.iso' -o -iname '*.chd' -o -iname '*.cue' \
           -o -iname 'mm.o2r' -o -iname 'oot.o2r' -o -iname 'oot.otr' \) \
        -print -quit | grep -q .; then
    echo "Refusing to package a Pi runtime bundle containing game data." >&2
    exit 1
fi

mkdir -p "$(dirname "${OUTPUT_FILE}")"
rm -f "${OUTPUT_FILE}" "${OUTPUT_FILE}.sha256"
COPYFILE_DISABLE=1 tar -czf "${OUTPUT_FILE}" -C "${INPUT_DIR}" .
if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$(dirname "${OUTPUT_FILE}")"
        sha256sum "$(basename "${OUTPUT_FILE}")" \
            > "$(basename "${OUTPUT_FILE}").sha256"
    )
else
    (
        cd "$(dirname "${OUTPUT_FILE}")"
        shasum -a 256 "$(basename "${OUTPUT_FILE}")" \
            > "$(basename "${OUTPUT_FILE}").sha256"
    )
fi
tar -tzf "${OUTPUT_FILE}" >/dev/null
ls -lh "${OUTPUT_FILE}" "${OUTPUT_FILE}.sha256"
