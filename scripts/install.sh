#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 240-MP installer for Raspberry Pi OS Trixie (arm64)
#
# Usage:
#   bash install.sh             # install latest release
#   bash install.sh v1.2.0      # install a specific release tag
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="TaterTotterson/240-MP-Emby-Jelly"
INSTALL_DIR="/opt/240mp"
LAUNCHER="/usr/local/bin/240mp"
SYSTEMD_SERVICE="/etc/systemd/system/240mp.service"

# ── Resolve version ────────────────────────────────────────────────────────────
VERSION="${1:-latest}"
if [ "$VERSION" = "latest" ]; then
    echo "Fetching latest release tag..."
    VERSION=$(curl -fsSL \
        "https://api.github.com/repos/${REPO}/releases/latest" \
        | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'])")
fi
echo "Installing 240-MP ${VERSION}"

TARBALL="240-MP-${VERSION}-linux-arm64.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${TARBALL}"

# ── Verify architecture ────────────────────────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "Error: this installer is for arm64 (aarch64). Detected: $ARCH"
    exit 1
fi

# ── Load shared Raspberry Pi setup helpers ────────────────────────────────────
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/lib/pi-setup.sh" ]; then
    # shellcheck source=lib/pi-setup.sh
    source "${SCRIPT_DIR}/lib/pi-setup.sh"
else
    # install.sh is commonly run through bash <(curl ...), so fetch its helper
    # from the same release tag when there is no local checkout beside it.
    # shellcheck source=/dev/null
    source <(curl -fsSL "https://raw.githubusercontent.com/${REPO}/${VERSION}/scripts/lib/pi-setup.sh")
fi

# ── Install runtime dependencies ──────────────────────────────────────────────
echo "Installing runtime dependencies..."
pi240_install_runtime_dependencies

# ── udev rule: allow tty group to open /dev/tty0 for VT switching ─────────────
pi240_install_tty_rule

# ── Download tarball ───────────────────────────────────────────────────────────
echo "Downloading ${TARBALL}..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL -o "${TMP_DIR}/${TARBALL}" "${DOWNLOAD_URL}"

# ── Extract to install directory ───────────────────────────────────────────────
# Tarball structure: usr/local/bin/240mp + usr/local/share/240mp/...
# We strip the usr/local prefix and place files directly in $INSTALL_DIR.
echo "Extracting to ${INSTALL_DIR}..."
sudo mkdir -p "${INSTALL_DIR}"
sudo tar -xzf "${TMP_DIR}/${TARBALL}" \
    --strip-components=3 \
    -C "${INSTALL_DIR}"

# ── Create launcher ────────────────────────────────────────────────────────────
echo "Creating launcher at ${LAUNCHER}..."
pi240_install_launcher "${INSTALL_DIR}" "${LAUNCHER}"

# ── Optional: systemd autostart ───────────────────────────────────────────────
echo ""
read -r -p "Install systemd autostart service? [y/N] " REPLY
if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    read -r -p "Run service as user [default: pi]: " SERVICE_USER
    SERVICE_USER="${SERVICE_USER:-pi}"

    pi240_install_autostart "${SERVICE_USER}" "${LAUNCHER}" "${SYSTEMD_SERVICE}"
    pi240_install_ssh_control "${SERVICE_USER}" /usr/local/sbin/240mp-ssh-control
    pi240_auto_force_composite_video
    pi240_install_boot_splash
    echo "Service installed and enabled."
    echo "Start now with: sudo systemctl start 240mp"
fi

echo ""
echo "240-MP ${VERSION} installed successfully."
echo "Run: 240mp"
