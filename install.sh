#!/bin/bash
# Surface Laptop 2 OV9734 webcam installer
# Fixes the camera on Surface Laptop 2 running linux-surface kernel.
#
# Must be run with sudo:  sudo ./install.sh
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=/usr/local/share/surface-laptop-2-camera

# ── Must run as root ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Run with sudo: sudo ./install.sh"

# Detect the real user (the one who invoked sudo)
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_UID=$(id -u "$REAL_USER")
[[ "$REAL_USER" == "root" ]] && error "Do not run as root directly. Use: sudo ./install.sh"

# ── Hardware check ────────────────────────────────────────────────────────────
DMI_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
if [[ "$DMI_PRODUCT" != "Surface Laptop 2" ]]; then
    warn "This machine reports itself as: '$DMI_PRODUCT'"
    warn "This fix is designed for Surface Laptop 2 (Model 1769)."
    read -rp "Continue anyway? [y/N] " yn
    [[ "${yn,,}" == "y" ]] || exit 1
fi

# ── Kernel check ─────────────────────────────────────────────────────────────
KERNEL=$(uname -r)
if [[ "$KERNEL" != *surface* ]]; then
    warn "Running kernel '$KERNEL' does not appear to be a linux-surface kernel."
    warn "This fix requires the linux-surface kernel (https://github.com/linux-surface/linux-surface)."
    read -rp "Continue anyway? [y/N] " yn
    [[ "${yn,,}" == "y" ]] || exit 1
fi
info "Kernel: $KERNEL"

# ── Dependencies ──────────────────────────────────────────────────────────────
info "Installing apt dependencies..."
# Ubuntu Jammy ships v4l2loopback 0.12.7, which does not compile against
# current linux-surface kernels (including 6.19). Remove any half-configured
# copy left by apt before installing the remaining dependencies.
if dpkg-query -W -f='${db:Status-Abbrev}' v4l2loopback-dkms 2>/dev/null | grep -q '^i'; then
    warn "Removing incompatible Ubuntu v4l2loopback-dkms package..."
    dpkg --remove --force-remove-reinstreq v4l2loopback-dkms || true
fi
apt-get install -y \
    dkms \
    git \
    "linux-headers-${KERNEL}" \
    v4l-utils \
    python3-numpy \
    python3-gi \
    python3-gst-1.0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-pipewire

# Jammy's v4l2loopback 0.12.7 uses kernel APIs removed long ago. Install the
# maintained upstream DKMS source, which supports kernel 6.19.
info "Installing current v4l2loopback DKMS module..."
V4L2_VER=0.15.4
V4L2_SRC=/usr/src/v4l2loopback-$V4L2_VER
LOCAL_V4L2_SRC="$SCRIPT_DIR/../v4l2loopback-upstream"
if [[ -f "$LOCAL_V4L2_SRC/dkms.conf" ]]; then
    rm -rf "$V4L2_SRC"
    cp -a "$LOCAL_V4L2_SRC" "$V4L2_SRC"
else
    rm -rf "$V4L2_SRC"
    git clone --depth 1 https://github.com/v4l2loopback/v4l2loopback.git "$V4L2_SRC"
fi
dkms remove "v4l2loopback/$V4L2_VER" --all 2>/dev/null || true
dkms add "v4l2loopback/$V4L2_VER"
dkms build "v4l2loopback/$V4L2_VER"
dkms install --force "v4l2loopback/$V4L2_VER"
info "  v4l2loopback/$V4L2_VER installed"

# ── Layer 1: ipu-bridge-ov9734 DKMS ──────────────────────────────────────────
info "Installing ipu-bridge-ov9734 DKMS module (Layer 1: OVTI9734 sensor support)..."
MOD1=ipu-bridge-ov9734
VER1=$(grep PACKAGE_VERSION "$SCRIPT_DIR/dkms/$MOD1/dkms.conf" | cut -d'"' -f2)
SRC1=/usr/src/$MOD1-$VER1
dkms remove "$MOD1/$VER1" --all 2>/dev/null || true
rm -rf "$SRC1"
cp -r "$SCRIPT_DIR/dkms/$MOD1" "$SRC1"
dkms add    "$MOD1/$VER1"
dkms build  "$MOD1/$VER1"
dkms install --force "$MOD1/$VER1"
info "  ipu-bridge-ov9734/$VER1 installed"

# ── Layer 3: ov9734-surface DKMS ─────────────────────────────────────────────
info "Installing ov9734-surface DKMS module (Layer 3: MCLK + reset GPIO handling)..."
MOD3=ov9734-surface
VER3=$(grep PACKAGE_VERSION "$SCRIPT_DIR/dkms/$MOD3/dkms.conf" | cut -d'"' -f2)
SRC3=/usr/src/$MOD3-$VER3
dkms remove "$MOD3/$VER3" --all 2>/dev/null || true
rm -rf "$SRC3"
cp -r "$SCRIPT_DIR/dkms/$MOD3" "$SRC3"
dkms add    "$MOD3/$VER3"
dkms build  "$MOD3/$VER3"
dkms install --force "$MOD3/$VER3"
info "  ov9734-surface/$VER3 installed"

# ── Layer 2: udev rebind rule ─────────────────────────────────────────────────
info "Installing udev rebind rule (Layer 2: probe ordering fix)..."
install -m 755 "$SCRIPT_DIR/udev/ipu3-camera-rebind.sh" /usr/local/sbin/
install -m 644 "$SCRIPT_DIR/udev/99-ov9734-rebind.rules" /etc/udev/rules.d/
udevadm control --reload-rules
info "  udev rule installed"

# ── v4l2loopback config ───────────────────────────────────────────────────────
info "Installing v4l2loopback modprobe config..."
install -m 644 "$SCRIPT_DIR/modprobe.d/v4l2loopback.conf" /etc/modprobe.d/
printf '%s\n' v4l2loopback > /etc/modules-load.d/surface-laptop-2-camera.conf
info "  /etc/modprobe.d/v4l2loopback.conf installed"
info "  v4l2loopback enabled for boot-time loading"

# ── Bridge script ─────────────────────────────────────────────────────────────
info "Installing camera bridge script..."
install -d "$INSTALL_DIR"
install -m 755 "$SCRIPT_DIR/bridge/camera-bridge.py" "$INSTALL_DIR/"
info "  $INSTALL_DIR/camera-bridge.py installed"

# ── WirePlumber config ────────────────────────────────────────────────────────
# Prevents WirePlumber from negotiating MJPG on /dev/video20, which would
# conflict with the bridge's YUYV output format.
info "Installing WirePlumber config for $REAL_USER..."
WP_CONF_DIR="$REAL_HOME/.config/wireplumber/wireplumber.conf.d"
mkdir -p "$WP_CONF_DIR"
install -m 644 "$SCRIPT_DIR/wireplumber/51-disable-v4l2loopback.conf" "$WP_CONF_DIR/"
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/wireplumber"
info "  WirePlumber config installed"

# ── User systemd service ──────────────────────────────────────────────────────
info "Installing user systemd service for $REAL_USER..."
SERVICE_DIR="$REAL_HOME/.config/systemd/user"
mkdir -p "$SERVICE_DIR"
install -m 644 "$SCRIPT_DIR/bridge/camera-bridge.service" "$SERVICE_DIR/"
chown "$REAL_USER:$REAL_USER" "$SERVICE_DIR/camera-bridge.service"

# Enable linger so the user service starts at boot without a login session
loginctl enable-linger "$REAL_USER"
info "  Linger enabled for $REAL_USER"

# Reload and enable the service
XDG_RUNTIME_DIR="/run/user/$REAL_UID"
if sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        systemctl --user daemon-reload 2>/dev/null && \
   sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        systemctl --user enable camera-bridge.service 2>/dev/null; then
    info "  camera-bridge.service enabled"
else
    warn "  Could not enable service automatically. After rebooting, run:"
    warn "    systemctl --user daemon-reload"
    warn "    systemctl --user enable --now camera-bridge.service"
fi

# The stock camera drivers may be embedded in the current initramfs. Rebuild it
# after DKMS installation so the patched ov9734 and ipu_bridge modules win at
# the next boot instead of the old in-tree copies.
info "Rebuilding initramfs with patched camera modules..."
depmod -a "$KERNEL"
update-initramfs -u -k "$KERNEL"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}Installation complete!${NC}"
echo
echo "  Please REBOOT for all changes to take effect."
echo
echo "  After rebooting, check the camera with:"
echo "    systemctl --user status camera-bridge.service"
echo "    cheese"
echo
echo "  The camera light will only turn on when an application requests it."
echo "  It turns off automatically ~5 seconds after the last app disconnects."
