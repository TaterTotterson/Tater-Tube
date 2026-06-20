#!/bin/bash -e

SUBSTAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${PI240_SOURCE_DIR:-/240mp-src}"
TARGET_DIR="${ROOTFS_DIR}/opt/240mp-src"
PROFILE="${PI240_IMAGE_PROFILE:-crt-ntsc}"
ENABLE_IR="${PI240_ENABLE_IR:-1}"
IR_GPIO_PIN="${PI240_IR_GPIO_PIN:-17}"
ENABLE_BOOT_SPLASH="${PI240_ENABLE_BOOT_SPLASH:-1}"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "240-MP source directory not found: $SOURCE_DIR" >&2
    echo "Set PI240_SOURCE_DIR or use scripts/build-pi-image.sh." >&2
    exit 1
fi

install -d "$TARGET_DIR"
tar \
    --exclude=.git \
    --exclude=build \
    --exclude=.cache \
    --exclude='*.dmg' \
    --exclude='*.img' \
    --exclude='*.img.xz' \
    -C "$SOURCE_DIR" \
    -cf - . | tar -C "$TARGET_DIR" -xf -

install -m 0755 "$SOURCE_DIR/scripts/lib/pi-setup.sh" "${ROOTFS_DIR}/tmp/240mp-pi-setup.sh"

{
    printf 'PI240_SERVICE_USER=%q\n' "${PI240_SERVICE_USER:-mp240}"
    printf 'PI240_SERVICE_HOME=%q\n' "${PI240_SERVICE_HOME:-/var/lib/240mp}"
    printf 'PI240_IMAGE_PROFILE=%q\n' "$PROFILE"
    printf 'PI240_ENABLE_IR=%q\n' "$ENABLE_IR"
    printf 'PI240_IR_GPIO_PIN=%q\n' "$IR_GPIO_PIN"
    printf 'PI240_IR_PROTOCOL=%q\n' "${PI240_IR_PROTOCOL:-nec}"
    printf 'PI240_ENABLE_BOOT_SPLASH=%q\n' "$ENABLE_BOOT_SPLASH"
} > "${ROOTFS_DIR}/tmp/240mp-image.env"

if [ "$PROFILE" != "none" ]; then
    SNIPPET="${SUBSTAGE_DIR}/files/config-${PROFILE}.txt"
    if [ ! -f "$SNIPPET" ]; then
        echo "Unknown 240-MP display profile: $PROFILE" >&2
        echo "Expected one of: hdmi, crt-ntsc, none" >&2
        exit 1
    fi

    CONFIG_TXT=""
    for candidate in "${ROOTFS_DIR}/boot/firmware/config.txt" "${ROOTFS_DIR}/boot/config.txt"; do
        if [ -f "$candidate" ] || [ -d "$(dirname "$candidate")" ]; then
            CONFIG_TXT="$candidate"
            break
        fi
    done
    CONFIG_TXT="${CONFIG_TXT:-${ROOTFS_DIR}/boot/firmware/config.txt}"
    install -d "$(dirname "$CONFIG_TXT")"
    touch "$CONFIG_TXT"

    {
        printf '\n# --- 240-MP display profile: %s ---\n' "$PROFILE"
        cat "$SNIPPET"
    } >> "$CONFIG_TXT"
fi

if [ "$ENABLE_IR" = "1" ]; then
    CONFIG_TXT=""
    for candidate in "${ROOTFS_DIR}/boot/firmware/config.txt" "${ROOTFS_DIR}/boot/config.txt"; do
        if [ -f "$candidate" ] || [ -d "$(dirname "$candidate")" ]; then
            CONFIG_TXT="$candidate"
            break
        fi
    done
    CONFIG_TXT="${CONFIG_TXT:-${ROOTFS_DIR}/boot/firmware/config.txt}"
    install -d "$(dirname "$CONFIG_TXT")"
    touch "$CONFIG_TXT"

    {
        printf '\n# --- 240-MP IR remote receiver ---\n'
        printf 'dtoverlay=gpio-ir,gpio_pin=%s\n' "$IR_GPIO_PIN"
    } >> "$CONFIG_TXT"
fi
