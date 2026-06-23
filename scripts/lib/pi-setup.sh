#!/usr/bin/env bash
# Shared Raspberry Pi install helpers for the release installer and pi-gen image.

PI240_RUNTIME_PACKAGES=(
    libqt6quick6
    libqt6qml6
    libqt6concurrent6
    libqt6opengl6
    libqt6network6
    libqt6svg6
    qt6-svg-plugins
    qt6-wayland
    qml6-module-qtquick
    qml6-module-qtquick-controls
    qml6-module-qtquick-window
    qml6-module-qtquick-effects
    libsdl2-2.0-0
    python3-smbus
    i2c-tools
    bluez
    bluetooth
    rfkill
    cifs-utils
    ir-keytable
    mpv
    openssh-server
    plymouth
    plymouth-themes
    retroarch
    yt-dlp
)

PI240_RETRO_CORE_PACKAGES=(
    libretro-nestopia
    libretro-genesisplusgx
    libretro-gambatte
    libretro-mgba
)

PI240_OPTIONAL_RETRO_CORE_PACKAGES=(
    libretro-snes9x
    libretro-beetle-psx
    libretro-pcsx-rearmed
)

PI240_PSX_CORE_URL="${PI240_PSX_CORE_URL:-https://buildbot.libretro.com/nightly/linux/aarch64/latest/pcsx_rearmed_libretro.so.zip}"

PI240_PSX_CORE_NAMES=(
    pcsx_rearmed_libretro.so
    mednafen_psx_hw_libretro.so
    mednafen_psx_libretro.so
    beetle_psx_hw_libretro.so
    beetle_psx_libretro.so
    swanstation_libretro.so
)

pi240_is_root() {
    [ "$(id -u)" -eq 0 ]
}

pi240_root() {
    if pi240_is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

pi240_install_file_from_stdin() {
    local target="$1"
    local mode="${2:-0644}"

    if pi240_is_root; then
        install -d -m 0755 "$(dirname "$target")"
        cat > "$target"
        chmod "$mode" "$target"
    else
        local tmp
        tmp="$(mktemp)"
        cat > "$tmp"
        sudo install -D -m "$mode" "$tmp" "$target"
        rm -f "$tmp"
    fi
}

pi240_install_runtime_dependencies() {
    pi240_root apt-get update -qq
    pi240_root apt-get install -y "${PI240_RUNTIME_PACKAGES[@]}"
    pi240_install_latest_ytdlp
    pi240_install_retro_core_dependencies
    pi240_install_moonlight_streaming
}

pi240_install_missing_runtime_dependencies() {
    if ! command -v dpkg-query >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
        return 0
    fi

    local missing=()
    local pkg
    for pkg in "${PI240_RUNTIME_PACKAGES[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        pi240_install_latest_ytdlp
        pi240_install_missing_retro_core_dependencies
        pi240_install_moonlight_streaming
        return 0
    fi

    pi240_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    pi240_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    pi240_install_latest_ytdlp
    pi240_install_missing_retro_core_dependencies no-update
    pi240_install_moonlight_streaming
}

pi240_install_latest_ytdlp() {
    if ! command -v curl >/dev/null 2>&1; then
        return 0
    fi

    local asset
    case "$(uname -m)" in
        aarch64|arm64)
            asset="yt-dlp_linux_aarch64"
            ;;
        x86_64|amd64)
            asset="yt-dlp_linux"
            ;;
        *)
            printf '[240mp-setup] Skipping yt-dlp binary refresh on unsupported arch: %s\n' "$(uname -m)" >&2
            return 0
            ;;
    esac

    local url="${PI240_YTDLP_URL:-https://github.com/yt-dlp/yt-dlp/releases/latest/download/${asset}}"
    local tmp
    tmp="$(mktemp)"
    if curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 -o "$tmp" "$url"; then
        pi240_root install -m 0755 "$tmp" /usr/local/bin/yt-dlp
        /usr/local/bin/yt-dlp --version >/dev/null 2>&1 || true
    else
        printf '[240mp-setup] Could not refresh yt-dlp from %s; keeping packaged copy\n' "$url" >&2
    fi
    rm -f "$tmp"
}

pi240_install_moonlight_streaming() {
    if command -v moonlight >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        return 0
    fi

    if ! apt-cache show moonlight-embedded >/dev/null 2>&1; then
        if ! command -v curl >/dev/null 2>&1; then
            printf '[240mp-setup] Skipping Moonlight install; curl is unavailable.\n' >&2
            return 0
        fi

        local setup_script
        setup_script="$(mktemp)"
        if curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' -o "$setup_script"; then
            pi240_root env distro=raspbian bash "$setup_script" || true
        else
            printf '[240mp-setup] Warning: could not download Moonlight package setup script.\n' >&2
        fi
        rm -f "$setup_script"
    fi

    if apt-cache show moonlight-embedded >/dev/null 2>&1; then
        pi240_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        pi240_root env DEBIAN_FRONTEND=noninteractive apt-get install -y moonlight-embedded || true
    else
        printf '[240mp-setup] Moonlight Embedded package is unavailable; PC Link will show N/A until installed.\n' >&2
    fi
}

pi240_install_retro_core_dependencies() {
    local pkg
    for pkg in "${PI240_RETRO_CORE_PACKAGES[@]}" "${PI240_OPTIONAL_RETRO_CORE_PACKAGES[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            pi240_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || true
        else
            printf '[240mp-setup] Optional RetroArch core package unavailable: %s\n' "$pkg" >&2
        fi
    done
    pi240_install_psx_core_fallback
}

pi240_install_missing_retro_core_dependencies() {
    if ! command -v dpkg-query >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
        return 0
    fi

    local missing=()
    local pkg
    for pkg in "${PI240_RETRO_CORE_PACKAGES[@]}" "${PI240_OPTIONAL_RETRO_CORE_PACKAGES[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    if [ "${1:-}" != "no-update" ]; then
        pi240_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    fi

    for pkg in "${missing[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            pi240_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || true
        else
            printf '[240mp-setup] Optional RetroArch core package unavailable: %s\n' "$pkg" >&2
        fi
    done
    pi240_install_psx_core_fallback
}

pi240_retro_core_dirs() {
    printf '%s\n' \
        /usr/lib/aarch64-linux-gnu/libretro \
        /usr/lib/arm-linux-gnueabihf/libretro \
        /usr/lib/x86_64-linux-gnu/libretro \
        /usr/lib/libretro \
        /usr/local/lib/libretro
}

pi240_has_retro_core() {
    local name="$1"
    local dir
    while IFS= read -r dir; do
        [ -f "$dir/$name" ] && return 0
    done < <(pi240_retro_core_dirs)
    return 1
}

pi240_has_psx_core() {
    local name
    for name in "${PI240_PSX_CORE_NAMES[@]}"; do
        pi240_has_retro_core "$name" && return 0
    done
    return 1
}

pi240_install_psx_core_fallback() {
    pi240_has_psx_core && return 0

    if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        printf '[240mp-setup] PSX core fallback needs curl and python3.\n' >&2
        return 0
    fi

    local tmp target
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/240mp-psx-core.XXXXXX")"
    target="/usr/local/lib/libretro/pcsx_rearmed_libretro.so"
    trap 'rm -rf "$tmp"' RETURN

    printf '[240mp-setup] Installing PSX RetroArch core from Libretro buildbot.\n' >&2
    if ! curl -fsSL "$PI240_PSX_CORE_URL" -o "$tmp/pcsx_rearmed.zip"; then
        printf '[240mp-setup] Warning: could not download PSX core: %s\n' "$PI240_PSX_CORE_URL" >&2
        return 0
    fi

    if ! python3 - "$tmp/pcsx_rearmed.zip" "$tmp" <<'PY'
import pathlib
import sys
import zipfile

zip_path = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
member_name = "pcsx_rearmed_libretro.so"

with zipfile.ZipFile(zip_path) as archive:
    for member in archive.namelist():
        if pathlib.PurePosixPath(member).name == member_name:
            out_path = out_dir / member_name
            out_path.write_bytes(archive.read(member))
            raise SystemExit(0)

print(f"{member_name} not found in {zip_path}", file=sys.stderr)
raise SystemExit(1)
PY
    then
        printf '[240mp-setup] Warning: downloaded PSX core archive was not usable.\n' >&2
        return 0
    fi

    pi240_root install -d -m 0755 /usr/local/lib/libretro
    pi240_root install -m 0644 "$tmp/pcsx_rearmed_libretro.so" "$target"
}

pi240_install_tty_rule() {
    pi240_install_file_from_stdin /etc/udev/rules.d/99-240mp-tty.rules 0644 <<'RULE'
KERNEL=="tty0", GROUP="tty", MODE="0620"
RULE

    if command -v udevadm >/dev/null 2>&1 && [ -e /dev/tty0 ]; then
        pi240_root udevadm control --reload-rules || true
        pi240_root udevadm trigger /dev/tty0 || true
    fi
}

pi240_join_existing_groups() {
    local sep="$1"
    shift
    local groups=()
    local group

    for group in "$@"; do
        if getent group "$group" >/dev/null 2>&1; then
            groups+=("$group")
        fi
    done

    local IFS="$sep"
    printf '%s' "${groups[*]}"
}

pi240_boot_config_path() {
    local candidate
    for candidate in /boot/firmware/config.txt /boot/config.txt; do
        if [ -f "$candidate" ] || [ -d "$(dirname "$candidate")" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '%s' /boot/firmware/config.txt
}

pi240_boot_cmdline_path() {
    local candidate
    for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        if [ -f "$candidate" ] || [ -d "$(dirname "$candidate")" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '%s' /boot/firmware/cmdline.txt
}

pi240_append_boot_cmdline_args() {
    local cmdline_txt
    cmdline_txt="$(pi240_boot_cmdline_path)"

    pi240_root install -d -m 0755 "$(dirname "$cmdline_txt")"
    pi240_root touch "$cmdline_txt"

    local current=""
    if [ -f "$cmdline_txt" ]; then
        current="$(tr '\n' ' ' < "$cmdline_txt" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
    fi

    local arg
    for arg in "$@"; do
        [ -n "$arg" ] || continue
        case " $current " in
            *" $arg "*) ;;
            *) current="${current:+$current }$arg" ;;
        esac
    done

    printf '%s\n' "$current" | pi240_root tee "$cmdline_txt" >/dev/null
}

pi240_set_boot_cmdline_arg() {
    local prefix="$1"
    local replacement="$2"
    local cmdline_txt
    cmdline_txt="$(pi240_boot_cmdline_path)"

    pi240_root install -d -m 0755 "$(dirname "$cmdline_txt")"
    pi240_root touch "$cmdline_txt"

    local current=""
    if [ -f "$cmdline_txt" ]; then
        current="$(tr '\n' ' ' < "$cmdline_txt" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
    fi

    local updated=""
    local arg
    for arg in $current; do
        case "$arg" in
            "$prefix"*) ;;
            *) updated="${updated:+$updated }$arg" ;;
        esac
    done

    if [ -n "$replacement" ]; then
        updated="${updated:+$updated }$replacement"
    fi

    printf '%s\n' "$updated" | pi240_root tee "$cmdline_txt" >/dev/null
}

pi240_add_boot_cmdline_args() {
    pi240_append_boot_cmdline_args \
        quiet \
        splash \
        loglevel=3 \
        logo.nologo \
        vt.global_cursor_default=0 \
        systemd.show_status=false \
        rd.systemd.show_status=false \
        udev.log_level=3 \
        plymouth.ignore-serial-consoles
}

pi240_detect_composite_standard() {
    local requested="${1:-auto}"
    requested="$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')"

    case "$requested" in
        pal|crt-pal)
            printf '%s\n' pal
            return 0
            ;;
        ntsc|crt-ntsc)
            printf '%s\n' ntsc
            return 0
            ;;
    esac

    local config_txt
    config_txt="$(pi240_boot_config_path)"
    if [ -f "$config_txt" ]; then
        if grep -Eq '^[[:space:]]*sdtv_mode[[:space:]]*=[[:space:]]*2([[:space:]]|$)' "$config_txt"; then
            printf '%s\n' pal
            return 0
        fi
        if grep -Eq '^[[:space:]]*sdtv_mode[[:space:]]*=[[:space:]]*[01]([[:space:]]|$)' "$config_txt"; then
            printf '%s\n' ntsc
            return 0
        fi
    fi

    local cmdline_txt
    cmdline_txt="$(pi240_boot_cmdline_path)"
    if [ -f "$cmdline_txt" ]; then
        if grep -Eq '(^|[[:space:]])video=Composite-1:720x576' "$cmdline_txt"; then
            printf '%s\n' pal
            return 0
        fi
        if grep -Eq '(^|[[:space:]])video=Composite-1:720x480' "$cmdline_txt"; then
            printf '%s\n' ntsc
            return 0
        fi
    fi

    printf '%s\n' ntsc
}

pi240_force_composite_video() {
    local standard
    standard="$(pi240_detect_composite_standard "${1:-auto}")"

    local mode="720x480ie"
    if [ "$standard" = "pal" ]; then
        mode="720x576ie"
    fi

    # The Pi composite KMS connector reports "unknown" unless it is force-enabled.
    # mpv rejects that as disconnected, even though Qt can render through vc4drmfb.
    pi240_set_boot_cmdline_arg "video=Composite-1:" "video=Composite-1:${mode}"
}

pi240_auto_force_composite_video() {
    if compgen -G "/sys/class/drm/*-Composite-1" >/dev/null; then
        pi240_force_composite_video "${1:-auto}"
    fi
}

pi240_enable_ir_overlay() {
    local gpio_pin="${1:-23}"
    local config_txt
    config_txt="$(pi240_boot_config_path)"

    pi240_root install -d -m 0755 "$(dirname "$config_txt")"
    pi240_root touch "$config_txt"

    if pi240_root grep -Eq '^[[:space:]]*dtoverlay=gpio-ir([,[:space:]]|$)' "$config_txt"; then
        if pi240_is_root; then
            sed -i -E "s|^[[:space:]]*dtoverlay=gpio-ir.*$|dtoverlay=gpio-ir,gpio_pin=${gpio_pin}|" "$config_txt"
        else
            sudo sed -i -E "s|^[[:space:]]*dtoverlay=gpio-ir.*$|dtoverlay=gpio-ir,gpio_pin=${gpio_pin}|" "$config_txt"
        fi
        return 0
    fi

    if pi240_is_root; then
        {
            printf '\n# --- CRT Station IR remote receiver ---\n'
            printf 'dtoverlay=gpio-ir,gpio_pin=%s\n' "$gpio_pin"
        } >> "$config_txt"
    else
        {
            printf '\n# --- CRT Station IR remote receiver ---\n'
            printf 'dtoverlay=gpio-ir,gpio_pin=%s\n' "$gpio_pin"
        } | sudo tee -a "$config_txt" >/dev/null
    fi
}

pi240_enable_i2c() {
    local config_txt
    config_txt="$(pi240_boot_config_path)"

    pi240_root install -d -m 0755 "$(dirname "$config_txt")"
    pi240_root touch "$config_txt"

    if pi240_root grep -Eq '^[[:space:]]*#?[[:space:]]*dtparam=i2c_arm=' "$config_txt"; then
        if pi240_is_root; then
            sed -i -E 's|^[[:space:]]*#?[[:space:]]*dtparam=i2c_arm=.*$|dtparam=i2c_arm=on|' "$config_txt"
        else
            sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*dtparam=i2c_arm=.*$|dtparam=i2c_arm=on|' "$config_txt"
        fi
        return 0
    fi

    if pi240_is_root; then
        {
            printf '\n# --- CRT Station Argon ONE fan control ---\n'
            printf 'dtparam=i2c_arm=on\n'
        } >> "$config_txt"
    else
        {
            printf '\n# --- CRT Station Argon ONE fan control ---\n'
            printf 'dtparam=i2c_arm=on\n'
        } | sudo tee -a "$config_txt" >/dev/null
    fi
}

pi240_install_boot_splash() {
    pi240_add_boot_cmdline_args

    if ! command -v plymouth >/dev/null 2>&1; then
        return 0
    fi

    pi240_install_file_from_stdin /usr/share/plymouth/themes/240mp/240mp.plymouth 0644 <<'PLYMOUTH_THEME'
[Plymouth Theme]
Name=CRT Station
Description=CRT Station boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/240mp
ScriptFile=/usr/share/plymouth/themes/240mp/240mp.script
PLYMOUTH_THEME

    pi240_install_file_from_stdin /usr/share/plymouth/themes/240mp/240mp.script 0644 <<'PLYMOUTH_SCRIPT'
Window.SetBackgroundTopColor(0.0, 0.0, 0.0);
Window.SetBackgroundBottomColor(0.02, 0.02, 0.02);

screen_width = Window.GetWidth();
screen_height = Window.GetHeight();

title_y = screen_height * 0.31;
line_y = screen_height * 0.43;
sub_y = screen_height * 0.53;
load_y = screen_height * 0.68;
hint_y = screen_height * 0.77;

fun center_sprite(sprite, image, y) {
    sprite.SetX((screen_width - image.GetWidth()) / 2);
    sprite.SetY(y);
}

fun set_sprite_text(sprite, text, red, green, blue, y) {
    image = Image.Text(text, red, green, blue);
    sprite.SetImage(image);
    center_sprite(sprite, image, y);
}

title_image = Image.Text("CRT STATION", 1.0, 1.0, 1.0);
title_sprite = Sprite(title_image);
center_sprite(title_sprite, title_image, title_y);

line_image = Image.Text("///// COMPOSITE VIDEO SYSTEM /////", 1.0, 0.42, 0.0);
line_sprite = Sprite(line_image);
center_sprite(line_sprite, line_image, line_y);

sub_image = Image.Text("SIGNAL LOCK  --  CRT READY", 0.55, 0.55, 0.55);
sub_sprite = Sprite(sub_image);
center_sprite(sub_sprite, sub_image, sub_y);

load_image = Image.Text("BOOTING", 1.0, 0.42, 0.0);
load_sprite = Sprite(load_image);
center_sprite(load_sprite, load_image, load_y);

hint_image = Image.Text("PLEASE WAIT", 0.55, 0.55, 0.55);
hint_sprite = Sprite(hint_image);
center_sprite(hint_sprite, hint_image, hint_y);

fun message_callback(text) {
    if (text == "240MP_UPDATE") {
        set_sprite_text(title_sprite, "CRT STATION", 1.0, 1.0, 1.0, title_y);
        set_sprite_text(line_sprite, "///// FLASHING FIRMWARE /////", 1.0, 0.42, 0.0, line_y);
        set_sprite_text(sub_sprite, "UPDATE IN PROGRESS", 0.55, 0.55, 0.55, sub_y);
        set_sprite_text(load_sprite, "DO NOT POWER OFF", 1.0, 0.42, 0.0, load_y);
        set_sprite_text(hint_sprite, "VIDEO WILL RETURN", 0.55, 0.55, 0.55, hint_y);
    }
}

Plymouth.SetDisplayMessageFunction(message_callback);
PLYMOUTH_SCRIPT

    pi240_install_file_from_stdin /etc/plymouth/plymouthd.conf 0644 <<'PLYMOUTH_CONF'
[Daemon]
Theme=240mp
ShowDelay=0
PLYMOUTH_CONF

    local plymouth_set_default=""
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        plymouth_set_default="$(command -v plymouth-set-default-theme)"
    elif [ -x /usr/sbin/plymouth-set-default-theme ]; then
        plymouth_set_default="/usr/sbin/plymouth-set-default-theme"
    fi

    if [ -n "$plymouth_set_default" ]; then
        pi240_root "$plymouth_set_default" 240mp || true
        if command -v update-initramfs >/dev/null 2>&1; then
            pi240_root update-initramfs -u -k all || true
        elif [ -x /usr/sbin/update-initramfs ]; then
            pi240_root /usr/sbin/update-initramfs -u -k all || true
        fi
    fi

    # Keep the splash visible for the appliance instead of letting the default
    # multi-user boot path clear it before the Qt kiosk service starts.
    pi240_root systemctl mask plymouth-quit.service plymouth-quit-wait.service || true

    if [ -e /run/240mp-updating ]; then
        pi240_show_update_splash || true
    fi
}

pi240_show_update_splash() {
    if ! command -v plymouth >/dev/null 2>&1; then
        return 0
    fi

    # Hide whatever agetty or the kernel last left on the active console before
    # Plymouth takes over. On composite output the handoff can otherwise expose
    # the login prompt behind the update message for a moment.
    pi240_blank_update_console || true

    if ! plymouth --ping >/dev/null 2>&1; then
        if command -v plymouthd >/dev/null 2>&1; then
            pi240_root plymouthd \
                --mode=boot \
                --tty=/dev/tty1 \
                --attach-to-session \
                --graphical-boot \
                >/dev/null 2>&1 || true
        fi
    fi

    pi240_root plymouth --show-splash >/dev/null 2>&1 || true
    pi240_root plymouth display-message --text="240MP_UPDATE" >/dev/null 2>&1 || true
}

pi240_blank_one_console() {
    local tty="$1"
    [ -e "$tty" ] || return 0

    # Clear stale login text from the underlying VT before the EGL app releases
    # the display. Plymouth may not be able to draw until KMS is free.
    printf '\033c\033[?25l\033[0m\033[40m\033[37m\033[2J\033[3J\033[H' | pi240_root tee "$tty" >/dev/null 2>&1 || true

    if command -v setterm >/dev/null 2>&1; then
        if pi240_is_root; then
            TERM=linux setterm --cursor off --clear all --blank force > "$tty" 2>/dev/null || true
        else
            sudo sh -c "TERM=linux setterm --cursor off --clear all --blank force > '$tty'" 2>/dev/null || true
        fi
    fi
}

pi240_blank_update_console() {
    local ttys=("$@")
    local active_tty=""
    local tty

    if [ "${#ttys[@]}" -eq 0 ]; then
        ttys=(/dev/tty1 /dev/tty0 /dev/tty12)
        if [ -r /sys/class/tty/tty0/active ]; then
            active_tty="$(cat /sys/class/tty/tty0/active 2>/dev/null || true)"
            case "$active_tty" in
                tty[0-9]*) ttys+=("/dev/$active_tty") ;;
            esac
        fi
    fi

    for tty in "${ttys[@]}"; do
        pi240_blank_one_console "$tty"
    done
}

pi240_install_launcher() {
    local install_dir="${1:-/opt/240mp}"
    local launcher="${2:-/usr/local/bin/240mp}"

    {
        printf '#!/usr/bin/env bash\n'
        printf '# CRT Station launcher - auto-detects display platform\n'
        printf 'INSTALL_DIR=%q\n' "$install_dir"
        cat <<'LAUNCHER'

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
elif [ -n "${DISPLAY:-}" ]; then
    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
else
    # No display server: use EGLFS for headless/kiosk mode (RPi Lite).
    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-eglfs}"
    MP240_MPV_VT="${MP240_MPV_VT:-12}"
    export QT_QPA_EGLFS_ALWAYS_SET_MODE=1
    export QT_QPA_EGLFS_KMS_ATOMIC="${QT_QPA_EGLFS_KMS_ATOMIC:-0}"

    # Select a DRM card with display connectors. On Pi 5 the render-only v3d
    # node can enumerate first, and Qt EGLFS needs the real display card.
    KMS_CARD=""
    for s in /sys/class/drm/card*-*/status; do
        [ -e "$s" ] || continue
        if [ "$(cat "$s")" = "connected" ]; then
            n=$(basename "$(dirname "$s")")
            KMS_CARD="${n%%-*}"
            break
        fi
    done
    if [ -z "$KMS_CARD" ]; then
        for d in /sys/class/drm/card*-*; do
            [ -e "$d" ] || continue
            n=$(basename "$d")
            KMS_CARD="${n%%-*}"
            break
        done
    fi
    if [ -n "$KMS_CARD" ] && [ -e "/dev/dri/$KMS_CARD" ]; then
        KMS_CONF="${XDG_RUNTIME_DIR:-/tmp}/240mp-kms.json"
        printf '{ "device": "/dev/dri/%s" }\n' "$KMS_CARD" > "$KMS_CONF"
        export QT_QPA_EGLFS_KMS_CONFIG="$KMS_CONF"
    fi
fi

export QT_QPA_PLATFORM
export MP240_MPV_VT
export QML2_IMPORT_PATH="/usr/lib/aarch64-linux-gnu/qt6/qml"

exec "${INSTALL_DIR}/bin/240mp" "$@"
LAUNCHER
    } | pi240_install_file_from_stdin "$launcher" 0755
}

pi240_install_update_helper() {
    local service_user="${1:-mp240}"
    local helper="${2:-/usr/local/sbin/240mp-update}"
    local source_script="${3:-/opt/240mp/share/240mp/scripts/240mp-update}"

    pi240_install_file_from_stdin "$helper" 0755 <<HELPER
#!/usr/bin/env bash
exec /usr/bin/env bash "$source_script" "\$@"
HELPER

    pi240_install_file_from_stdin /etc/sudoers.d/240mp-update 0440 <<SUDOERS
${service_user} ALL=(root) NOPASSWD: ${helper}
SUDOERS

    if command -v visudo >/dev/null 2>&1; then
        pi240_root visudo -cf /etc/sudoers.d/240mp-update
    fi

    # Compatibility migration: older updater scripts already call this function
    # during OTA, but they do not know about newer system helpers yet.
    pi240_install_bluetooth_control "$service_user" /usr/local/sbin/240mp-bluetooth-control
    pi240_install_retro_mount_helper "$service_user" /usr/local/sbin/240mp-retro-mount
    pi240_install_argon_fan_control "$service_user" /usr/local/sbin/240mp-argon-fan-control
}

pi240_install_ssh_control() {
    local service_user="${1:-mp240}"
    local helper="${2:-/usr/local/sbin/240mp-ssh-control}"
    local default_enabled="${3:-}"

    pi240_install_file_from_stdin "$helper" 0755 <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

unit="ssh.service"
action="${1:-status}"

systemd_live() {
    [ -d /run/systemd/system ]
}

emit_status() {
    local available=0
    local enabled=0
    local active=0

    if systemctl cat "$unit" >/dev/null 2>&1; then
        available=1
    fi
    if systemctl is-enabled --quiet "$unit" >/dev/null 2>&1; then
        enabled=1
    fi
    if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
        active=1
    fi

    printf 'available=%s\n' "$available"
    printf 'enabled=%s\n' "$enabled"
    printf 'active=%s\n' "$active"
}

case "$action" in
    status)
        emit_status
        ;;
    enable)
        systemctl unmask "$unit" >/dev/null 2>&1 || true
        systemctl enable "$unit"
        if systemd_live; then
            systemctl start "$unit"
        fi
        emit_status
        ;;
    disable)
        systemctl disable "$unit"
        if systemd_live; then
            systemctl stop "$unit"
        fi
        emit_status
        ;;
    *)
        echo "usage: $0 [status|enable|disable]" >&2
        exit 2
        ;;
esac
HELPER

    pi240_install_file_from_stdin /etc/sudoers.d/240mp-ssh-control 0440 <<SUDOERS
${service_user} ALL=(root) NOPASSWD: ${helper}
SUDOERS

    if command -v visudo >/dev/null 2>&1; then
        pi240_root visudo -cf /etc/sudoers.d/240mp-ssh-control
    fi

    case "$default_enabled" in
        1|true|TRUE|yes|YES|on|ON)
            pi240_root "$helper" enable || true
            ;;
        0|false|FALSE|no|NO|off|OFF)
            pi240_root "$helper" disable || true
            ;;
    esac
}

pi240_append_file() {
    local path="$1"
    shift

    if pi240_is_root; then
        printf '%s\n' "$@" >> "$path"
    else
        printf '%s\n' "$@" | sudo tee -a "$path" >/dev/null
    fi
}

pi240_set_bluetooth_input_option() {
    local option="$1"
    local value="$2"
    local file="/etc/bluetooth/input.conf"

    pi240_root install -d -m 0755 /etc/bluetooth
    if [ ! -f "$file" ]; then
        pi240_install_file_from_stdin "$file" 0644 <<EOF
[General]
${option}=${value}
EOF
        return 0
    fi

    if grep -q -E "^#?${option}=" "$file"; then
        pi240_root sed -i -E "s/^#?${option}=.*/${option}=${value}/" "$file"
        return 0
    fi

    if ! grep -q -E '^\[General\]' "$file"; then
        pi240_append_file "$file" "" "[General]"
    fi
    pi240_append_file "$file" "${option}=${value}"
}

pi240_configure_bluetooth_input() {
    # DualSense and some other controllers can pair/trust without BlueZ marking
    # them bonded. The default HID input policy then connects but refuses to
    # create /dev/input nodes, so SDL never sees the controller.
    pi240_set_bluetooth_input_option UserspaceHID true
    pi240_set_bluetooth_input_option ClassicBondedOnly false
}

pi240_install_bluetooth_control() {
    local service_user="${1:-mp240}"
    local helper="${2:-/usr/local/sbin/240mp-bluetooth-control}"
    local default_enabled="${3:-}"

    pi240_configure_bluetooth_input

    pi240_install_file_from_stdin "$helper" 0755 <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

unit="bluetooth.service"
action="${1:-status}"
address="${2:-}"

systemd_live() {
    [ -d /run/systemd/system ]
}

truthy() {
    case "${1:-}" in
        yes|Yes|YES|true|TRUE|1|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

valid_address() {
    [[ "$1" =~ ^[A-Fa-f0-9]{2}(:[A-Fa-f0-9]{2}){5}$ ]]
}

available() {
    command -v bluetoothctl >/dev/null 2>&1 && systemctl cat "$unit" >/dev/null 2>&1
}

require_available() {
    available || {
        echo "bluetoothctl or bluetooth.service is not available" >&2
        exit 1
    }
}

adapter_value() {
    local key="$1"
    bluetoothctl show 2>/dev/null | sed -n -E "s/^[[:space:]]*${key}:[[:space:]]*(.*)$/\1/p" | head -n 1
}

controller_addresses() {
    bluetoothctl list 2>/dev/null | sed -n -E 's/^Controller ([A-Fa-f0-9:]{17}) .*/\1/p'
}

emit_status() {
    local is_available=0
    local enabled=0
    local active=0
    local powered=0
    local discovering=0

    if available; then
        is_available=1
    fi
    if systemctl is-enabled --quiet "$unit" >/dev/null 2>&1; then
        enabled=1
    fi
    if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
        active=1
    fi
    if truthy "$(adapter_value Powered)"; then
        powered=1
    fi
    if truthy "$(adapter_value Discovering)"; then
        discovering=1
    fi

    printf 'available=%s\n' "$is_available"
    printf 'enabled=%s\n' "$enabled"
    printf 'active=%s\n' "$active"
    printf 'powered=%s\n' "$powered"
    printf 'discovering=%s\n' "$discovering"
}

device_value() {
    local mac="$1"
    local key="$2"
    bluetoothctl info "$mac" 2>/dev/null | sed -n -E "s/^[[:space:]]*${key}:[[:space:]]*(.*)$/\1/p" | head -n 1
}

emit_device() {
    local mac="$1"
    local fallback_name="${2:-$1}"
    valid_address "$mac" || return 0

    local name
    local paired=0
    local trusted=0
    local connected=0

    name="$(device_value "$mac" Name)"
    name="${name:-$fallback_name}"
    name="${name//$'\t'/ }"

    if truthy "$(device_value "$mac" Paired)"; then paired=1; fi
    if truthy "$(device_value "$mac" Trusted)"; then trusted=1; fi
    if truthy "$(device_value "$mac" Connected)"; then connected=1; fi

    printf 'device\t%s\t%s\t%s\t%s\t%s\n' "$mac" "$name" "$paired" "$trusted" "$connected"
}

emit_devices() {
    local line
    local rest
    local mac
    local name

    bluetoothctl devices 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            Device\ *)
                rest="${line#Device }"
                mac="${rest%% *}"
                name="${rest#"$mac"}"
                name="${name# }"
                emit_device "$mac" "$name"
                ;;
        esac
    done
}

unblock_bluetooth() {
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock bluetooth >/dev/null 2>&1 || true
    fi

    local rfkill_dir
    for rfkill_dir in /sys/class/rfkill/rfkill*; do
        [ -d "$rfkill_dir" ] || continue
        [ "$(cat "$rfkill_dir/type" 2>/dev/null || true)" = "bluetooth" ] || continue
        if [ -w "$rfkill_dir/soft" ]; then
            printf '0\n' > "$rfkill_dir/soft" 2>/dev/null || true
        fi
    done
}

power_on_controllers() {
    local first=""
    local controller

    while IFS= read -r controller; do
        [ -n "$controller" ] || continue
        [ -n "$first" ] || first="$controller"
        bluetoothctl select "$controller" >/dev/null 2>&1 || true
        bluetoothctl power on >/dev/null 2>&1 || true
    done < <(controller_addresses)

    if [ -n "$first" ]; then
        bluetoothctl select "$first" >/dev/null 2>&1 || true
    fi
    bluetoothctl power on >/dev/null 2>&1 || true
}

scan_devices() {
    local seconds="${BLUETOOTH_SCAN_SECONDS:-10}"

    case "$seconds" in
        ''|*[!0-9]*) seconds=10 ;;
    esac
    if [ "$seconds" -lt 4 ]; then seconds=4; fi
    if [ "$seconds" -gt 30 ]; then seconds=30; fi

    bluetoothctl scan off >/dev/null 2>&1 || true
    bluetoothctl --timeout "$seconds" scan on >/dev/null 2>&1 || true
    bluetoothctl scan off >/dev/null 2>&1 || true
}

enable_bluetooth() {
    require_available
    systemctl unmask "$unit" >/dev/null 2>&1 || true
    systemctl enable "$unit" >/dev/null
    if systemd_live; then
        systemctl start "$unit" >/dev/null
        unblock_bluetooth
        power_on_controllers
        bluetoothctl agent on >/dev/null 2>&1 || true
        bluetoothctl default-agent >/dev/null 2>&1 || true
    fi
}

disable_bluetooth() {
    require_available
    if systemd_live; then
        bluetoothctl scan off >/dev/null 2>&1 || true
        bluetoothctl power off >/dev/null 2>&1 || true
    fi
    systemctl disable "$unit" >/dev/null
    if systemd_live; then
        systemctl stop "$unit" >/dev/null
    fi
}

case "$action" in
    status)
        emit_status
        ;;
    enable)
        enable_bluetooth
        emit_status
        ;;
    disable)
        disable_bluetooth
        emit_status
        ;;
    scan)
        enable_bluetooth
        scan_devices
        emit_status
        emit_devices
        ;;
    pair-connect)
        require_available
        valid_address "$address" || {
            echo "invalid Bluetooth address" >&2
            exit 2
        }
        enable_bluetooth
        bluetoothctl pair "$address" >/dev/null 2>&1 || true
        bluetoothctl trust "$address" >/dev/null 2>&1 || true
        bluetoothctl connect "$address" >/dev/null
        emit_status
        emit_device "$address"
        ;;
    connect)
        require_available
        valid_address "$address" || {
            echo "invalid Bluetooth address" >&2
            exit 2
        }
        enable_bluetooth
        bluetoothctl trust "$address" >/dev/null 2>&1 || true
        bluetoothctl connect "$address" >/dev/null
        emit_status
        emit_device "$address"
        ;;
    forget)
        require_available
        valid_address "$address" || {
            echo "invalid Bluetooth address" >&2
            exit 2
        }
        bluetoothctl disconnect "$address" >/dev/null 2>&1 || true
        bluetoothctl remove "$address" >/dev/null
        emit_status
        emit_devices
        ;;
    *)
        echo "usage: $0 [status|enable|disable|scan|pair-connect <mac>|connect <mac>|forget <mac>]" >&2
        exit 2
        ;;
esac
HELPER

    pi240_install_file_from_stdin /etc/sudoers.d/240mp-bluetooth-control 0440 <<SUDOERS
${service_user} ALL=(root) NOPASSWD: ${helper}
SUDOERS

    if command -v visudo >/dev/null 2>&1; then
        pi240_root visudo -cf /etc/sudoers.d/240mp-bluetooth-control
    fi

    case "$default_enabled" in
        1|true|TRUE|yes|YES|on|ON)
            pi240_root "$helper" enable || true
            ;;
        0|false|FALSE|no|NO|off|OFF)
            pi240_root "$helper" disable || true
            ;;
    esac
}

pi240_install_argon_fan_control() {
    local service_user="${1:-mp240}"
    local helper="${2:-/usr/local/sbin/240mp-argon-fan-control}"
    local daemon="/usr/local/sbin/240mp-argon-fan-daemon"
    local config="/etc/240mp-argon-fan.conf"
    local service="/etc/systemd/system/240mp-argon-fan.service"

    pi240_enable_i2c

    pi240_install_file_from_stdin "$daemon" 0755 <<'PY'
#!/usr/bin/env python3
import os
import signal
import sys
import time

CONFIG = "/etc/240mp-argon-fan.conf"
ADDR = 0x1A
REG_DUTY = 0x80
DEFAULT_CURVE = [(65.0, 100), (60.0, 55), (55.0, 30)]

try:
    import smbus
except Exception:
    smbus = None

reload_requested = False

def handle_reload(signum, frame):
    global reload_requested
    reload_requested = True

signal.signal(signal.SIGHUP, handle_reload)

def clamp_speed(value):
    try:
        value = int(float(value))
    except Exception:
        return 0
    return max(0, min(100, value))

def load_config():
    mode = "auto"
    speed = 50
    curve = list(DEFAULT_CURVE)
    parsed_curve = []

    try:
        with open(CONFIG, "r", encoding="utf-8") as fp:
            for raw in fp:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = [part.strip() for part in line.split("=", 1)]
                low_key = key.lower()
                if low_key == "mode":
                    low_value = value.lower()
                    if low_value in ("auto", "off", "fixed"):
                        mode = low_value
                elif low_key == "speed":
                    speed = clamp_speed(value)
                else:
                    try:
                        temp = float(key)
                        fan = clamp_speed(value)
                    except Exception:
                        continue
                    if 0 <= temp <= 100:
                        parsed_curve.append((temp, fan))
    except FileNotFoundError:
        pass

    if parsed_curve:
        curve = sorted(parsed_curve, reverse=True)
    return mode, speed, curve

def cpu_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r", encoding="utf-8") as fp:
            return float(fp.read().strip()) / 1000.0
    except Exception:
        return 0.0

def bus_obj():
    if smbus is None:
        return None
    for bus_id in (1, 0):
        try:
            return smbus.SMBus(bus_id)
        except Exception:
            continue
    return None

def close_bus(bus):
    try:
        bus.close()
    except Exception:
        pass

def has_argon(bus):
    if bus is None:
        return False
    try:
        bus.read_byte_data(ADDR, REG_DUTY)
        return True
    except Exception:
        return False

def current_fan(bus):
    if bus is None:
        return 0
    try:
        return clamp_speed(bus.read_byte_data(ADDR, REG_DUTY))
    except Exception:
        return 0

def write_fan(bus, speed):
    speed = clamp_speed(speed)
    bus.write_byte_data(ADDR, REG_DUTY, speed)
    time.sleep(0.2)

def target_speed(mode, fixed_speed, curve):
    if mode == "off":
        return 0
    if mode == "fixed":
        return clamp_speed(fixed_speed)

    temp = cpu_temp()
    for threshold, fan in curve:
        if temp >= threshold:
            return clamp_speed(fan)
    return 0

def emit_status():
    mode, fixed_speed, curve = load_config()
    bus = bus_obj()
    available = has_argon(bus)
    fan = current_fan(bus) if available else 0
    temp = cpu_temp()
    close_bus(bus)

    print(f"available={1 if available else 0}")
    print(f"mode={mode}")
    print(f"speed={clamp_speed(fixed_speed)}")
    print(f"fan={fan}")
    if temp > 0:
        print(f"temp={temp:.1f}")
    if not available:
        if smbus is None:
            print("message=PYTHON SMBUS IS NOT INSTALLED.")
        else:
            print("message=ARGON ONE FAN CONTROLLER WAS NOT DETECTED.")

def apply_once():
    mode, fixed_speed, curve = load_config()
    bus = bus_obj()
    if not has_argon(bus):
        close_bus(bus)
        return 1
    speed = target_speed(mode, fixed_speed, curve)
    if speed > 0:
        write_fan(bus, 100)
    write_fan(bus, speed)
    close_bus(bus)
    return 0

def daemon_loop():
    global reload_requested
    bus = None
    previous = None

    while True:
        if bus is None:
            bus = bus_obj()

        if not has_argon(bus):
            close_bus(bus)
            bus = None
            previous = None
            time.sleep(60)
            continue

        mode, fixed_speed, curve = load_config()
        speed = target_speed(mode, fixed_speed, curve)

        if speed != previous or reload_requested:
            if speed > 0 and (previous is None or previous <= 0) and speed < 100:
                write_fan(bus, 100)
            write_fan(bus, speed)
            previous = speed
            reload_requested = False

        time.sleep(30)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--status":
        emit_status()
        raise SystemExit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "--once":
        raise SystemExit(apply_once())
    daemon_loop()
PY

    pi240_install_file_from_stdin "$helper" 0755 <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

action="${1:-status}"
value="${2:-auto}"
daemon="/usr/local/sbin/240mp-argon-fan-daemon"
config="/etc/240mp-argon-fan.conf"
unit="240mp-argon-fan.service"

systemd_live() {
    [ -d /run/systemd/system ]
}

bounded_speed() {
    local raw="$1"
    raw="${raw%\%}"
    case "$raw" in
        ''|*[!0-9]*) echo 50 ;;
        *)
            if [ "$raw" -lt 0 ]; then echo 0
            elif [ "$raw" -gt 100 ]; then echo 100
            else echo "$raw"
            fi
            ;;
    esac
}

write_config() {
    local mode="$1"
    local speed="${2:-50}"
    local tmp
    tmp="$(mktemp)"
    {
        echo '# CRT Station Argon ONE fan control'
        echo '# mode=auto|off|fixed'
        printf 'mode=%s\n' "$mode"
        printf 'speed=%s\n' "$(bounded_speed "$speed")"
        echo '55=30'
        echo '60=55'
        echo '65=100'
    } > "$tmp"
    install -D -m 0644 "$tmp" "$config"
    rm -f "$tmp"
}

ensure_default_config() {
    [ -f "$config" ] || write_config auto 50
}

emit_status() {
    local active=0
    if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
        active=1
    fi
    "$daemon" --status || true
    printf 'active=%s\n' "$active"
}

restart_service() {
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$unit" >/dev/null 2>&1 || true
    if systemd_live; then
        systemctl restart "$unit" >/dev/null 2>&1 || true
    else
        "$daemon" --once >/dev/null 2>&1 || true
    fi
}

case "$action" in
    status)
        ensure_default_config
        emit_status
        ;;
    set)
        case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
            auto|automatic)
                write_config auto 50
                ;;
            off|0|0%)
                write_config off 0
                ;;
            *)
                write_config fixed "$(bounded_speed "$value")"
                ;;
        esac
        restart_service
        emit_status
        ;;
    *)
        echo "usage: $0 [status|set <auto|off|percent>]" >&2
        exit 2
        ;;
esac
HELPER

    pi240_install_file_from_stdin "$service" 0644 <<UNIT
[Unit]
Description=CRT Station Argon ONE fan control
After=multi-user.target

[Service]
Type=simple
ExecStart=${daemon}
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
UNIT

    pi240_install_file_from_stdin /etc/sudoers.d/240mp-argon-fan-control 0440 <<SUDOERS
${service_user} ALL=(root) NOPASSWD: ${helper}
SUDOERS

    if command -v visudo >/dev/null 2>&1; then
        pi240_root visudo -cf /etc/sudoers.d/240mp-argon-fan-control
    fi

    pi240_root "$helper" status >/dev/null 2>&1 || true
    pi240_root systemctl daemon-reload || true
    pi240_root systemctl enable 240mp-argon-fan.service || true
    if [ -d /run/systemd/system ]; then
        pi240_root systemctl restart 240mp-argon-fan.service || true
    fi
}

pi240_install_retro_mount_helper() {
    local service_user="${1:-mp240}"
    local helper="${2:-/usr/local/sbin/240mp-retro-mount}"

    pi240_install_file_from_stdin "$helper" 0755 <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
host="${2:-}"
share="${3:-}"
mountpoint_path="${4:-}"
credentials="${5:-}"

die() {
    echo "$*" >&2
    exit 1
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

valid_mountpoint() {
    case "$1" in
        /var/lib/240mp/*|/home/*/.local/share/240-MP/*|/tmp/240mp-*|/private/tmp/240mp-*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_target() {
    valid_name "$host" || die "invalid RetroNAS host"
    valid_name "$share" || die "invalid RetroNAS share"
    [ -n "$mountpoint_path" ] || die "missing mount point"
    valid_mountpoint "$mountpoint_path" || die "invalid mount point"
}

case "$action" in
    mount)
        validate_target
        install -d -m 0755 "$mountpoint_path"

        if mountpoint -q "$mountpoint_path"; then
            echo "mounted=1"
            exit 0
        fi

        uid="${SUDO_UID:-1000}"
        gid="${SUDO_GID:-1000}"
        opts="rw,uid=${uid},gid=${gid},iocharset=utf8,noperm,serverino"
        if [ -n "$credentials" ] && [ "$credentials" != "-" ]; then
            case "$credentials" in
                /var/lib/240mp/*|/home/*/.local/share/240-MP/*|/tmp/240mp-*|/private/tmp/240mp-*) ;;
                *) die "invalid credentials path" ;;
            esac
            [ -f "$credentials" ] || die "credentials file not found"
            opts="${opts},credentials=${credentials}"
        else
            opts="${opts},guest"
        fi

        if mount -t cifs "//$host/$share" "$mountpoint_path" -o "${opts},vers=3.0"; then
            echo "mounted=1"
            exit 0
        fi
        mount -t cifs "//$host/$share" "$mountpoint_path" -o "${opts},vers=2.1"
        echo "mounted=1"
        ;;
    umount|unmount)
        [ -n "$mountpoint_path" ] || die "missing mount point"
        valid_mountpoint "$mountpoint_path" || die "invalid mount point"
        if mountpoint -q "$mountpoint_path"; then
            umount "$mountpoint_path"
        fi
        echo "mounted=0"
        ;;
    status)
        [ -n "$mountpoint_path" ] || die "missing mount point"
        valid_mountpoint "$mountpoint_path" || die "invalid mount point"
        if mountpoint -q "$mountpoint_path"; then
            echo "mounted=1"
        else
            echo "mounted=0"
        fi
        ;;
    *)
        echo "usage: $0 mount <host> <share> <mountpoint> <credentials|-|empty>" >&2
        exit 2
        ;;
esac
HELPER

    pi240_install_file_from_stdin /etc/sudoers.d/240mp-retro-mount 0440 <<SUDOERS
${service_user} ALL=(root) NOPASSWD: ${helper}
SUDOERS

    if command -v visudo >/dev/null 2>&1; then
        pi240_root visudo -cf /etc/sudoers.d/240mp-retro-mount
    fi
}

pi240_install_ir_support() {
    local protocol="${1:-nec}"
    local keymap="${2:-/etc/rc_keymaps/240mp.toml}"
    local default_keymap="/etc/rc_keymaps/240mp-default.toml"
    local gpio_pin="${3:-23}"

    pi240_install_file_from_stdin /etc/default/240mp-ir 0644 <<IR_DEFAULTS
MP240_IR_PROTOCOL=${protocol}
MP240_IR_KEYMAP=${keymap}
MP240_IR_GPIO_PIN=${gpio_pin}
IR_DEFAULTS

    pi240_install_file_from_stdin "$default_keymap" 0644 <<'KEYMAP'
[[protocols]]
name = "240mp-nec-remotes"
protocol = "nec"
variant = "nec"

[protocols.scancodes]
# Argon40 IR Remote for Argon Raspberry Pi cases.
0xca = "KEY_UP"
0xd2 = "KEY_DOWN"
0x99 = "KEY_LEFT"
0xc1 = "KEY_RIGHT"
0xce = "KEY_OK"
0xcb = "KEY_HOME"
0x90 = "KEY_BACK"
0x9d = "KEY_MENU"
0x80 = "KEY_VOLUMEUP"
0x81 = "KEY_VOLUMEDOWN"

# Common 21-key NEC mini remote, short scancodes.
0x45 = "KEY_POWER"
0x46 = "KEY_MENU"
0x47 = "KEY_HOME"
0x44 = "KEY_PREVIOUS"
0x40 = "KEY_NEXT"
0x43 = "KEY_PLAYPAUSE"
0x07 = "KEY_VOLUMEDOWN"
0x15 = "KEY_VOLUMEUP"
0x09 = "KEY_MUTE"
0x16 = "KEY_BACK"
0x0c = "KEY_NUMERIC_1"
0x18 = "KEY_UP"
0x5e = "KEY_NUMERIC_3"
0x08 = "KEY_LEFT"
0x1c = "KEY_OK"
0x5a = "KEY_RIGHT"
0x42 = "KEY_NUMERIC_7"
0x52 = "KEY_DOWN"
0x4a = "KEY_NUMERIC_9"

# Same remote family when the receiver reports NEC address bits too.
0x00ff45 = "KEY_POWER"
0x00ff46 = "KEY_MENU"
0x00ff47 = "KEY_HOME"
0x00ff44 = "KEY_PREVIOUS"
0x00ff40 = "KEY_NEXT"
0x00ff43 = "KEY_PLAYPAUSE"
0x00ff07 = "KEY_VOLUMEDOWN"
0x00ff15 = "KEY_VOLUMEUP"
0x00ff09 = "KEY_MUTE"
0x00ff16 = "KEY_BACK"
0x00ff0c = "KEY_NUMERIC_1"
0x00ff18 = "KEY_UP"
0x00ff5e = "KEY_NUMERIC_3"
0x00ff08 = "KEY_LEFT"
0x00ff1c = "KEY_OK"
0x00ff5a = "KEY_RIGHT"
0x00ff42 = "KEY_NUMERIC_7"
0x00ff52 = "KEY_DOWN"
0x00ff4a = "KEY_NUMERIC_9"
KEYMAP

    if [ ! -f "$keymap" ] || pi240_root grep -q 'name = "240mp-nec-mini"' "$keymap"; then
        pi240_root install -D -m 0644 "$default_keymap" "$keymap"
    fi

    pi240_install_file_from_stdin /usr/local/sbin/240mp-ir-setup 0755 <<'IR_SETUP'
#!/usr/bin/env bash
set -euo pipefail

if [ -f /etc/default/240mp-ir ]; then
    # shellcheck source=/dev/null
    source /etc/default/240mp-ir
fi

PROTOCOL="${MP240_IR_PROTOCOL:-nec}"
KEYMAP="${MP240_IR_KEYMAP:-/etc/rc_keymaps/240mp.toml}"

if ! command -v ir-keytable >/dev/null 2>&1; then
    echo "ir-keytable not installed" >&2
    exit 0
fi

if [ ! -f "$KEYMAP" ]; then
    echo "IR keymap not found: $KEYMAP" >&2
    exit 0
fi

shopt -s nullglob
devices=(/sys/class/rc/rc*)
if [ "${#devices[@]}" -eq 0 ]; then
    echo "No IR receiver devices found"
    exit 0
fi

for device in "${devices[@]}"; do
    name="$(basename "$device")"
    if [ -r "$device/protocols" ] && ! tr '[]' '  ' < "$device/protocols" | grep -qw "$PROTOCOL"; then
        continue
    fi
    ir-keytable -s "$name" -c -p "$PROTOCOL" -w "$KEYMAP" || true
done
IR_SETUP

    pi240_install_file_from_stdin /usr/local/bin/240mp-ir-learn 0755 <<'IR_LEARN'
#!/usr/bin/env bash
set -euo pipefail

cat <<'MSG'
Press buttons on the IR remote. Use the printed scancode values in
/etc/rc_keymaps/240mp.toml, then run:

  sudo systemctl restart 240mp-ir-keymap.service

Stop with Ctrl+C.
MSG

exec ir-keytable -t
IR_LEARN

    pi240_install_file_from_stdin /etc/systemd/system/240mp-ir-keymap.service 0644 <<'IR_SERVICE'
[Unit]
Description=CRT Station IR remote keymap
After=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 1
ExecStart=/usr/local/sbin/240mp-ir-setup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
IR_SERVICE

    pi240_root systemctl daemon-reload || true
    pi240_root systemctl enable 240mp-ir-keymap.service || true
}

pi240_create_service_user() {
    local service_user="${1:-mp240}"
    local service_home="${2:-/var/lib/240mp}"
    local media_groups
    media_groups="$(pi240_join_existing_groups "," tty video input audio render)"

    if id "$service_user" >/dev/null 2>&1; then
        if [ -n "$media_groups" ]; then
            pi240_root usermod -aG "$media_groups" "$service_user" || true
        fi
        return 0
    fi

    local group_args=()
    if [ -n "$media_groups" ]; then
        group_args=(--groups "$media_groups")
    fi

    pi240_root useradd \
        --system \
        --create-home \
        --home-dir "$service_home" \
        "${group_args[@]}" \
        --shell /usr/sbin/nologin \
        "$service_user"
}

pi240_install_autostart() {
    local service_user="${1:-pi}"
    local launcher="${2:-/usr/local/bin/240mp}"
    local systemd_service="${3:-/etc/systemd/system/240mp.service}"
    local service_home="${4:-}"

    if [ -z "$service_home" ]; then
        service_home="$(getent passwd "$service_user" 2>/dev/null | cut -d: -f6 || true)"
    fi
    service_home="${service_home:-/home/${service_user}}"
    local service_groups
    local supplementary_groups_line=""
    service_groups="$(pi240_join_existing_groups " " tty video input audio render)"
    if [ -n "$service_groups" ]; then
        supplementary_groups_line="SupplementaryGroups=${service_groups}"
    fi

    pi240_install_file_from_stdin "$systemd_service" 0644 <<UNIT
[Unit]
Description=CRT Station Media Player
After=multi-user.target sound.target

[Service]
Type=simple
User=${service_user}
${supplementary_groups_line}
AmbientCapabilities=CAP_SYS_TTY_CONFIG
RuntimeDirectory=240mp
RuntimeDirectoryMode=0700
Environment=HOME=${service_home}
Environment=XDG_RUNTIME_DIR=/run/240mp
Environment=QT_QPA_PLATFORM=eglfs
Environment=QT_QPA_EGLFS_ALWAYS_SET_MODE=1
Environment=QT_QPA_EGLFS_KMS_ATOMIC=0
Environment=QML2_IMPORT_PATH=/usr/lib/aarch64-linux-gnu/qt6/qml
Environment=MP240_AUTOSTART=1
Environment=MP240_MPV_VT=12
ExecStartPre=+-/usr/bin/systemctl stop 240mp-terminal.service
ExecStartPre=+-/usr/bin/plymouth quit --retain-splash
ExecStart=${launcher}
Restart=on-failure
RestartSec=5s
RestartPreventExitStatus=10
ExecStopPost=+/usr/local/bin/240mp-stop
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

pi240_install_file_from_stdin /usr/local/bin/240mp-stop 0755 <<'STOP_HELPER'
#!/usr/bin/env bash
# Called by 240mp.service ExecStopPost. systemd sets $EXIT_STATUS to the app's exit code.
blank_update_console() {
    local ttys=(/dev/tty1 /dev/tty0 /dev/tty12)
    local active_tty=""
    local tty

    if [ -r /sys/class/tty/tty0/active ]; then
        active_tty="$(cat /sys/class/tty/tty0/active 2>/dev/null || true)"
        case "$active_tty" in
            tty[0-9]*) ttys+=("/dev/$active_tty") ;;
        esac
    fi

    for tty in "${ttys[@]}"; do
        [ -e "$tty" ] || continue
        printf '\033c\033[?25l\033[0m\033[40m\033[37m\033[2J\033[3J\033[H' > "$tty" 2>/dev/null || true
        if command -v setterm >/dev/null 2>&1; then
            TERM=linux setterm --cursor off --clear all --blank force > "$tty" 2>/dev/null || true
        fi
    done
}

if [ -e /run/240mp-updating ]; then
    systemctl stop 240mp-terminal.service >/dev/null 2>&1 || true
    blank_update_console
    exit 0
fi
if systemctl list-units --no-legend --type=service --state=activating,running '240mp-update-*.service' 2>/dev/null | grep -q '^240mp-update-'; then
    systemctl stop 240mp-terminal.service >/dev/null 2>&1 || true
    blank_update_console
    exit 0
fi

case "${EXIT_STATUS:-}" in
    0)
        systemctl poweroff
        ;;
    10)
        systemctl start 240mp-terminal.service
        ;;
    *)
        systemctl start 240mp-terminal.service
        ;;
esac
STOP_HELPER

    pi240_install_file_from_stdin /etc/systemd/system/240mp-terminal.service 0644 <<'TERMINAL_UNIT'
[Unit]
Description=CRT Station exit-to-terminal login shell

[Service]
Type=idle
ExecStart=-/sbin/agetty --noclear tty1 linux
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
KillMode=process
Restart=no
TERMINAL_UNIT

    # Keep tty1 reserved for the app and tty12 quiet for mpv playback, but
    # leave autovt available so Ctrl+Alt+F2 can open a recovery login if the
    # display stack fails.
    pi240_root systemctl mask getty@tty1.service
    pi240_root systemctl mask getty@tty12.service
    pi240_root systemctl unmask autovt@.service || true
    pi240_root systemctl daemon-reload || true
    pi240_root systemctl enable 240mp.service
}
