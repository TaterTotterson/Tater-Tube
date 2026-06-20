#!/usr/bin/env bash
# Build a Raspberry Pi OS Lite appliance image that boots directly into 240-MP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PI_GEN_REPO="${PI_GEN_REPO:-https://github.com/RPi-Distro/pi-gen.git}"
PI_GEN_BRANCH="${PI_GEN_BRANCH:-arm64}"
PI_GEN_DIR="${PI_GEN_DIR:-${REPO_ROOT}/.cache/pi-gen-arm64}"
PI_GEN_CONFIG="${PI_GEN_CONFIG:-${PI_GEN_DIR}/config}"

PI_IMAGE_NAME="${PI_IMAGE_NAME:-240mp}"
PI_IMAGE_RELEASE="${PI_IMAGE_RELEASE:-trixie}"
PI_IMAGE_PROFILE="${PI_IMAGE_PROFILE:-crt-ntsc}"
PI_IMAGE_ROOT_MARGIN_MB="${PI_IMAGE_ROOT_MARGIN_MB:-1536}"
PI_SERVICE_USER="${PI_SERVICE_USER:-mp240}"
PI_SERVICE_HOME="${PI_SERVICE_HOME:-/var/lib/240mp}"
PI_FIRST_USER_NAME="${PI_FIRST_USER_NAME:-tater}"
PI_ENABLE_SSH="${PI_ENABLE_SSH:-1}"
PI_FIRST_USER_PASS="${PI_FIRST_USER_PASS-pi}"
PI_FIRST_USER_PUBKEY="${PI_FIRST_USER_PUBKEY:-}"
PI_PUBKEY_ONLY_SSH="${PI_PUBKEY_ONLY_SSH:-0}"
PI_ENABLE_IR="${PI_ENABLE_IR:-1}"
PI_IR_GPIO_PIN="${PI_IR_GPIO_PIN:-17}"
PI_IR_PROTOCOL="${PI_IR_PROTOCOL:-nec}"
PI_ENABLE_BOOT_SPLASH="${PI_ENABLE_BOOT_SPLASH:-1}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

write_config_value() {
    printf '%s=%q\n' "$1" "$2" >> "$PI_GEN_CONFIG"
}

load_pubkey() {
    local pubkey="$1"
    if [ -n "$pubkey" ] && [ -f "$pubkey" ]; then
        cat "$pubkey"
    else
        printf '%s' "$pubkey"
    fi
}

patch_pi_gen_export_margin() {
    local prerun="${PI_GEN_DIR}/export-image/prerun.sh"
    local tmp="${prerun}.tmp"

    awk -v margin="$PI_IMAGE_ROOT_MARGIN_MB" '
        /^ROOT_MARGIN=/ {
            print "ROOT_MARGIN=\"$(echo \"($ROOT_SIZE * 0.2 + " margin " * 1024 * 1024) / 1\" | bc)\""
            next
        }
        { print }
    ' "$prerun" > "$tmp"
    mv "$tmp" "$prerun"
    chmod +x "$prerun"
}

patch_pi_gen_disable_apt_listchanges() {
    local finalise="${PI_GEN_DIR}/export-image/05-finalise/01-run.sh"
    local tmp="${finalise}.tmp"

    awk '
        /if \[ -f \/usr\/lib\/systemd\/system\/apt-listchanges.service \]; then/ {
            print "\tif [ -f /usr/lib/systemd/system/apt-listchanges.service ]; then"
            print "\t\tsystemctl disable apt-listchanges.timer || true"
            print "\tfi"
            skip=1
            next
        }
        skip && /^[[:space:]]*fi$/ {
            skip=0
            next
        }
        !skip {
            print
        }
    ' "$finalise" > "$tmp"
    mv "$tmp" "$finalise"
    chmod +x "$finalise"
}

case "$PI_IMAGE_PROFILE" in
    hdmi|crt-ntsc|none) ;;
    *)
        echo "Unknown PI_IMAGE_PROFILE: $PI_IMAGE_PROFILE" >&2
        echo "Use one of: hdmi, crt-ntsc, none" >&2
        exit 1
        ;;
esac

case "$REPO_ROOT" in
    *" "*)
        echo "pi-gen does not support build paths containing spaces." >&2
        echo "Repo path: ${REPO_ROOT}" >&2
        exit 1
        ;;
esac

case "$PI_GEN_DIR" in
    *" "*)
        echo "pi-gen does not support build paths containing spaces." >&2
        echo "pi-gen path: ${PI_GEN_DIR}" >&2
        exit 1
        ;;
esac

if [ -n "$PI_FIRST_USER_PUBKEY" ]; then
    PI_ENABLE_SSH=1
fi

if [ -z "$PI_FIRST_USER_PASS" ] && [ "${PI_ALLOW_NO_LOGIN_USER:-0}" != "1" ]; then
    cat >&2 <<'MSG'
Refusing to build an image without a login user credential.

Set:
  PI_FIRST_USER_PASS='a strong password'

Optionally also set:
  PI_FIRST_USER_PUBKEY='ssh-ed25519 ...' or PI_FIRST_USER_PUBKEY=/path/to/id.pub

The app itself runs as the dedicated mp240 service user, but you still want a
real login for SSH, debugging, and the Exit to Terminal flow. To intentionally
build without one, set PI_ALLOW_NO_LOGIN_USER=1.
MSG
    exit 1
fi

require_cmd git
require_cmd docker

mkdir -p "$(dirname "$PI_GEN_DIR")" "$(dirname "$PI_GEN_CONFIG")"

if [ ! -d "${PI_GEN_DIR}/.git" ]; then
    git clone --depth 1 --branch "$PI_GEN_BRANCH" "$PI_GEN_REPO" "$PI_GEN_DIR"
else
    git -C "$PI_GEN_DIR" fetch --depth 1 origin "$PI_GEN_BRANCH"
    git -C "$PI_GEN_DIR" checkout "$PI_GEN_BRANCH"
    git -C "$PI_GEN_DIR" reset --hard "origin/${PI_GEN_BRANCH}"
fi

patch_pi_gen_export_margin
patch_pi_gen_disable_apt_listchanges

CUSTOM_STAGE="${PI_GEN_DIR}/stage240mp"
rm -rf "$CUSTOM_STAGE"
cp -R "${SCRIPT_DIR}/pi-image/stage240mp" "$CUSTOM_STAGE"
chmod +x "$CUSTOM_STAGE"/00-install-app/*.sh
touch "${PI_GEN_DIR}/stage2/SKIP_IMAGES"
rm -f "${CUSTOM_STAGE}/SKIP_IMAGES"

: > "$PI_GEN_CONFIG"
write_config_value IMG_NAME "$PI_IMAGE_NAME"
write_config_value RELEASE "$PI_IMAGE_RELEASE"
write_config_value STAGE_LIST "stage0 stage1 stage2 stage240mp"
write_config_value DEPLOY_COMPRESSION "xz"
write_config_value ENABLE_SSH "$PI_ENABLE_SSH"
write_config_value FIRST_USER_NAME "$PI_FIRST_USER_NAME"

if [ -n "$PI_FIRST_USER_PASS" ]; then
    write_config_value FIRST_USER_PASS "$PI_FIRST_USER_PASS"
    write_config_value DISABLE_FIRST_BOOT_USER_RENAME "1"
fi

if [ -n "$PI_FIRST_USER_PUBKEY" ]; then
    write_config_value PUBKEY_SSH_FIRST_USER "$(load_pubkey "$PI_FIRST_USER_PUBKEY")"
    write_config_value PUBKEY_ONLY_SSH "$PI_PUBKEY_ONLY_SSH"
    write_config_value DISABLE_FIRST_BOOT_USER_RENAME "1"
fi

export PIGEN_DOCKER_OPTS="${PIGEN_DOCKER_OPTS:-} --mount type=bind,source=${REPO_ROOT},target=/240mp-src,readonly -e PI240_SOURCE_DIR=/240mp-src -e PI240_IMAGE_PROFILE=${PI_IMAGE_PROFILE} -e PI240_SERVICE_USER=${PI_SERVICE_USER} -e PI240_SERVICE_HOME=${PI_SERVICE_HOME} -e PI240_ENABLE_SSH=${PI_ENABLE_SSH} -e PI240_ENABLE_IR=${PI_ENABLE_IR} -e PI240_IR_GPIO_PIN=${PI_IR_GPIO_PIN} -e PI240_IR_PROTOCOL=${PI_IR_PROTOCOL} -e PI240_ENABLE_BOOT_SPLASH=${PI_ENABLE_BOOT_SPLASH}"

echo "Building ${PI_IMAGE_NAME} Raspberry Pi image with pi-gen..."
echo "pi-gen: ${PI_GEN_DIR}"
echo "config: ${PI_GEN_CONFIG}"
echo "display profile: ${PI_IMAGE_PROFILE}"
echo "SSH: ${PI_ENABLE_SSH}"
echo "IR receiver: ${PI_ENABLE_IR} (GPIO ${PI_IR_GPIO_PIN}, protocol ${PI_IR_PROTOCOL})"
echo "boot splash: ${PI_ENABLE_BOOT_SPLASH}"
echo "rootfs margin: ${PI_IMAGE_ROOT_MARGIN_MB} MB"

(
    cd "$PI_GEN_DIR"
    ./build-docker.sh
)

echo ""
echo "Image build complete. Output files are in:"
echo "  ${PI_GEN_DIR}/deploy"
