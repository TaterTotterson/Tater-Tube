#!/bin/bash -e

SUBSTAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${PI240_SOURCE_DIR:-/240mp-src}"
TARGET_DIR="${ROOTFS_DIR}/opt/240mp-src"
PROFILE="${PI240_IMAGE_PROFILE:-crt-ntsc}"
ENABLE_IR="${PI240_ENABLE_IR:-1}"
IR_GPIO_PIN="${PI240_IR_GPIO_PIN:-23}"
ENABLE_BLUETOOTH="${PI240_ENABLE_BLUETOOTH:-1}"
ENABLE_BOOT_SPLASH="${PI240_ENABLE_BOOT_SPLASH:-1}"

if [ ! -d "$SOURCE_DIR" ]; then
        echo "Tater Tube source directory not found: $SOURCE_DIR" >&2
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

if [ -n "${PI240_RUNTIME_BUNDLE_DIR:-}" ]; then
    if [ ! -d "${PI240_RUNTIME_BUNDLE_DIR}" ]; then
        echo "Tater Tube runtime bundle directory not found: ${PI240_RUNTIME_BUNDLE_DIR}" >&2
        exit 1
    fi
    RUNTIME_TARGET="${ROOTFS_DIR}/opt/240mp/share/240mp/vendor"
    install -d "${RUNTIME_TARGET}"
    cp -a "${PI240_RUNTIME_BUNDLE_DIR}/." "${RUNTIME_TARGET}/"
fi

{
    printf 'PI240_SERVICE_USER=%q\n' "${PI240_SERVICE_USER:-mp240}"
    printf 'PI240_SERVICE_HOME=%q\n' "${PI240_SERVICE_HOME:-/var/lib/240mp}"
    printf 'PI240_IMAGE_PROFILE=%q\n' "$PROFILE"
    printf 'PI240_ENABLE_IR=%q\n' "$ENABLE_IR"
    printf 'PI240_IR_GPIO_PIN=%q\n' "$IR_GPIO_PIN"
    printf 'PI240_IR_PROTOCOL=%q\n' "${PI240_IR_PROTOCOL:-nec}"
    printf 'PI240_ENABLE_BLUETOOTH=%q\n' "$ENABLE_BLUETOOTH"
    printf 'PI240_ENABLE_BOOT_SPLASH=%q\n' "$ENABLE_BOOT_SPLASH"
    printf 'PI240_INSTALL_ALL_RETRO_CORE_FALLBACKS=%q\n' "${PI240_INSTALL_ALL_RETRO_CORE_FALLBACKS:-1}"
} > "${ROOTFS_DIR}/tmp/240mp-image.env"

if [ "$PROFILE" != "none" ]; then
    SNIPPET="${SUBSTAGE_DIR}/files/config-${PROFILE}.txt"
    if [ ! -f "$SNIPPET" ]; then
        echo "Unknown Tater Tube display profile: $PROFILE" >&2
        echo "Expected one of: hdmi, pi5-hdmi-auto, crt-ntsc, crt-pal, none" >&2
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

    if [ "$PROFILE" = "crt-ntsc" ] || [ "$PROFILE" = "crt-pal" ]; then
        sed -i -E \
            -e 's|^[[:space:]]*dtoverlay=vc4-kms-v3d([[:space:]]*)$|# dtoverlay=vc4-kms-v3d|' \
            -e 's|^[[:space:]]*dtoverlay=vc4-kms-v3d,composite([[:space:]]*)$|# dtoverlay=vc4-kms-v3d,composite|' \
            "$CONFIG_TXT"
    fi

    {
        printf '\n# --- Tater Tube display profile: %s ---\n' "$PROFILE"
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
        printf '\n# --- Tater Tube IR remote receiver ---\n'
        printf 'dtoverlay=gpio-ir,gpio_pin=%s\n' "$IR_GPIO_PIN"
    } >> "$CONFIG_TXT"
fi
