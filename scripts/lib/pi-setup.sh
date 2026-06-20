#!/usr/bin/env bash
# Shared Raspberry Pi install helpers for the release installer and pi-gen image.

PI240_RUNTIME_PACKAGES=(
    libqt6quick6
    libqt6qml6
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
    mpv
    openssh-server
    plymouth
    plymouth-themes
    v4l-utils
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

pi240_force_composite_video() {
    # The Pi composite KMS connector reports "unknown" unless it is force-enabled.
    # mpv rejects that as disconnected, even though Qt can render through vc4drmfb.
    pi240_append_boot_cmdline_args "video=Composite-1:720x480ie"
}

pi240_auto_force_composite_video() {
    if compgen -G "/sys/class/drm/*-Composite-1" >/dev/null; then
        pi240_force_composite_video
    fi
}

pi240_enable_ir_overlay() {
    local gpio_pin="${1:-17}"
    local config_txt
    config_txt="$(pi240_boot_config_path)"

    pi240_root install -d -m 0755 "$(dirname "$config_txt")"
    pi240_root touch "$config_txt"

    if pi240_root grep -Eq '^[[:space:]]*dtoverlay=gpio-ir([,[:space:]]|$)' "$config_txt"; then
        return 0
    fi

    if pi240_is_root; then
        {
            printf '\n# --- 240-MP IR remote receiver ---\n'
            printf 'dtoverlay=gpio-ir,gpio_pin=%s\n' "$gpio_pin"
        } >> "$config_txt"
    else
        {
            printf '\n# --- 240-MP IR remote receiver ---\n'
            printf 'dtoverlay=gpio-ir,gpio_pin=%s\n' "$gpio_pin"
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
Name=240-MP
Description=240-MP boot splash
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

fun center_sprite(sprite, image, y) {
    sprite.SetX((screen_width - image.GetWidth()) / 2);
    sprite.SetY(y);
}

title_image = Image.Text("VIDEO ON DEMAND", 1.0, 1.0, 1.0);
title_sprite = Sprite(title_image);
center_sprite(title_sprite, title_image, screen_height * 0.38);

line_image = Image.Text("////////////////////////////", 1.0, 0.42, 0.0);
line_sprite = Sprite(line_image);
center_sprite(line_sprite, line_image, screen_height * 0.50);

sub_image = Image.Text("240-MP", 0.55, 0.55, 0.55);
sub_sprite = Sprite(sub_image);
center_sprite(sub_sprite, sub_image, screen_height * 0.59);

load_image = Image.Text("LOADING", 1.0, 0.42, 0.0);
load_sprite = Sprite(load_image);
center_sprite(load_sprite, load_image, screen_height * 0.73);
PLYMOUTH_SCRIPT

    pi240_install_file_from_stdin /etc/plymouth/plymouthd.conf 0644 <<'PLYMOUTH_CONF'
[Daemon]
Theme=240mp
ShowDelay=0
PLYMOUTH_CONF

    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        pi240_root plymouth-set-default-theme 240mp || true
    fi

    # Keep the splash visible for the appliance instead of letting the default
    # multi-user boot path clear it before the Qt kiosk service starts.
    pi240_root systemctl mask plymouth-quit.service plymouth-quit-wait.service || true
}

pi240_install_launcher() {
    local install_dir="${1:-/opt/240mp}"
    local launcher="${2:-/usr/local/bin/240mp}"

    {
        printf '#!/usr/bin/env bash\n'
        printf '# 240-MP launcher - auto-detects display platform\n'
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

pi240_install_ir_support() {
    local protocol="${1:-nec}"
    local keymap="${2:-/etc/rc_keymaps/240mp.toml}"
    local default_keymap="/etc/rc_keymaps/240mp-default.toml"
    local gpio_pin="${3:-17}"

    pi240_install_file_from_stdin /etc/default/240mp-ir 0644 <<IR_DEFAULTS
MP240_IR_PROTOCOL=${protocol}
MP240_IR_KEYMAP=${keymap}
MP240_IR_GPIO_PIN=${gpio_pin}
IR_DEFAULTS

    pi240_install_file_from_stdin "$default_keymap" 0644 <<'KEYMAP'
[[protocols]]
name = "240mp-nec-mini"
protocol = "nec"
variant = "nec"

[protocols.scancodes]
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

    if [ ! -f "$keymap" ]; then
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
Description=240-MP IR remote keymap
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
Description=240-MP Media Player
After=multi-user.target sound.target

[Service]
Type=simple
User=${service_user}
${supplementary_groups_line}
AmbientCapabilities=CAP_SYS_TTY_CONFIG
CapabilityBoundingSet=CAP_SYS_TTY_CONFIG
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
if [ -e /run/240mp-updating ]; then
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
Description=240-MP exit-to-terminal login shell

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
