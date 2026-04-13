#!/usr/bin/env bash
set -euo pipefail

# ── Styling ────────────────────────────────────────────────
BOLD="\033[1m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

info()    { echo -e "${GREEN}==>${RESET} ${BOLD}$*${RESET}"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}────── $* ──────${RESET}"; }

# ── Preflight ──────────────────────────────────────────────
section "Preflight"

[[ -f /etc/arch-release ]] || error "Arch Linux only."
command -v pacman &>/dev/null || error "pacman missing."
command -v sudo   &>/dev/null || error "sudo missing."

info "System OK"

# ── Packages ───────────────────────────────────────────────
section "Installing packages"

PACKAGES=(
  sway swaybg swaylock swayidle
  foot waybar wofi fuzzel
  xorg-xwayland
  vulkan-intel vulkan-icd-loader

  networkmanager network-manager-applet
  polkit-gnome gnome-keyring

  pipewire wireplumber pipewire-audio pipewire-pulse pipewire-alsa
  xdg-desktop-portal-wlr

  grim slurp wl-clipboard
  brightnessctl playerctl

  noto-fonts noto-fonts-emoji ttf-dejavu otf-font-awesome
  git curl base-devel

  pavucontrol blueman power-profiles-daemon
  wdisplays

  gnome-calendar gnome-online-accounts evolution-data-server evolution
)

sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"

# ── Install yay (AUR helper) ───────────────────────────────
section "Installing yay (AUR helper)"

if ! command -v yay &>/dev/null; then
  info "Installing yay..."
  tmpdir=$(mktemp -d)
  git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  pushd "$tmpdir/yay" >/dev/null
  makepkg -si --noconfirm
  popd >/dev/null
  rm -rf "$tmpdir"
else
  info "yay already installed"
fi

# ── Install wlogout ────────────────────────────────────────
section "Installing wlogout"
yay -S --needed --noconfirm wlogout || warn "wlogout install failed"
yay -S --needed --noconfirm nwg-look || warn "nwg-look install failed"

# ── Services ───────────────────────────────────────────────
section "Enabling services"

sudo systemctl enable --now NetworkManager
sudo systemctl enable --now power-profiles-daemon
systemctl --user enable --now pipewire pipewire-pulse wireplumber || true

# ── PAM (keyring unlock) ───────────────────────────────────
section "Configuring PAM"

PAM_FILE="/etc/pam.d/login"

if ! grep -q pam_gnome_keyring.so "$PAM_FILE"; then
  warn "Patching PAM for keyring"
  sudo sed -i '/^auth/a auth        optional     pam_gnome_keyring.so' "$PAM_FILE"
  sudo sed -i '/^session/a session    optional     pam_gnome_keyring.so auto_start' "$PAM_FILE"
fi

# ── User groups (GPU access) ──────────────────────────────
section "Ensuring video/render group membership"

for grp in video render; do
  if ! id -nG | grep -qw "$grp"; then
    sudo usermod -aG "$grp" "$USER"
    info "Added $USER to $grp group"
  else
    info "$USER already in $grp group"
  fi
done

# ── Environment ────────────────────────────────────────────
section "Environment"

mkdir -p ~/.config/environment.d

cat > ~/.config/environment.d/sway.conf <<EOF
XDG_CURRENT_DESKTOP=sway
XDG_SESSION_TYPE=wayland
CLUTTER_BACKEND=wayland
QT_QPA_PLATFORM=wayland;xcb
MOZ_ENABLE_WAYLAND=1
EOF

# ── GDM session (Intel iGPU only) ─────────────────────────
section "Patching GDM session entry for Intel iGPU"

# Wrapper script sets WLR_DRM_DEVICES to the Intel iGPU.
# We use a script instead of inline env in the .desktop file
# because the desktop entry format splits values on colons,
# which breaks by-path device paths.
SWAY_WRAPPER="/usr/local/bin/sway-igpu"
# Resolve by-path symlinks to real /dev/dri/cardN devices.
# WLR_DRM_DEVICES uses ':' as a multi-device separator, so
# by-path names (which contain colons) cannot be used directly.
# Intel is listed first so it becomes the primary renderer.
# NVIDIA is second so Sway can output to HDMI/DP wired through it.
INTEL_CARD=$(readlink -f /dev/dri/by-path/pci-0000:00:02.0-card)
NVIDIA_CARD=$(readlink -f /dev/dri/by-path/pci-0000:01:00.0-card)
sudo tee "$SWAY_WRAPPER" > /dev/null <<WRAPPER
#!/bin/sh
export WLR_DRM_DEVICES=${INTEL_CARD}:${NVIDIA_CARD}
export WLR_RENDERER=vulkan
exec sway --unsupported-gpu "\$@"
WRAPPER
sudo chmod +x "$SWAY_WRAPPER"
info "Installed $SWAY_WRAPPER"

SWAY_DESKTOP="/usr/share/wayland-sessions/sway.desktop"
if [ -f "$SWAY_DESKTOP" ]; then
  sudo sed -i "s|^Exec=.*|Exec=sway-igpu|" "$SWAY_DESKTOP"
  info "Set sway.desktop to launch via sway-igpu wrapper"
fi

# ── Sway config ────────────────────────────────────────────
section "Configuring Sway"

SWAY_CFG="$HOME/.config/sway/config"
mkdir -p ~/.config/sway

if [[ -f "$SWAY_CFG" ]]; then
  BACKUP="${SWAY_CFG}.bak.$(date +%s)"
  warn "Backing up config → $BACKUP"
  cp "$SWAY_CFG" "$BACKUP"
else
  cp /etc/sway/config "$SWAY_CFG"
fi

# Remove previous managed block
sed -i '/# >>> sway-setup/,/# <<< sway-setup/d' "$SWAY_CFG"

# Remove conflicting default bindings
sed -i '/set \$menu wmenu-run/d' "$SWAY_CFG"
sed -i '/bindsym \$mod+d exec \$menu/d' "$SWAY_CFG"

# Remove default bar
sed -i '/^bar {/,/^}/d' "$SWAY_CFG"

# Append clean config
cat >> "$SWAY_CFG" <<'EOF'

# >>> sway-setup (managed)

# Launcher
set $menu wofi --show drun
bindsym $mod+d exec $menu

# Keybinding Cheat Sheet (Searchable)
bindsym $mod+Shift+slash exec grep -E '^ *bindsym' ~/.config/sway/config | sed 's/bindsym //g' | wofi --dmenu -p "Keybinds" -i

# Power menu
bindsym $mod+Shift+p exec wlogout

# Environment sync
exec_always dbus-update-activation-environment --systemd \
  WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE SSH_AUTH_SOCK

exec_always systemctl --user import-environment \
  WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE SSH_AUTH_SOCK

# Start gnome-keyring
exec_always eval $(gnome-keyring-daemon --start --components=secrets,ssh,pkcs11)

# Autostart apps
exec nm-applet --indicator
exec blueman-applet
exec waybar
exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

# Portal
exec_always /usr/lib/xdg-desktop-portal-wlr

# Touchpad
input type:touchpad {
    tap enabled
    natural_scroll enabled
    tap_button_map lrm
    pointer_accel 0.0
    accel_profile adaptive
}

# Mouse
input type:pointer {
    pointer_accel 0.0
    accel_profile flat
    natural_scroll disabled
}

# Display settings
bindsym $mod+Shift+d exec wdisplays

# Appearance settings (GTK theme, cursor, fonts)
bindsym $mod+Shift+a exec nwg-look

# Idle
exec swayidle -w \
  timeout 300  'swaylock -f -c 1a1a2e' \
  timeout 600  'swaymsg "output * dpms off"' \
  resume        'swaymsg "output * dpms on"' \
  before-sleep 'swaylock -f -c 1a1a2e'

# <<< sway-setup
EOF

# ── Waybar ────────────────────────────────────────────────
section "Waybar (Config & Style)"

mkdir -p ~/.config/waybar

# (Rest of your Waybar and Wofi config remains identical...)
cat > ~/.config/waybar/config <<'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 34,
    "spacing": 4,
    "modules-left": ["sway/workspaces", "sway/mode"],
    "modules-center": ["clock"],
    "modules-right": ["cpu", "memory", "pulseaudio", "network", "battery", "tray"],

    "sway/workspaces": {
        "disable-scroll": true,
        "all-outputs": true,
        "format": "{icon}",
        "format-icons": {
            "default": "",
            "focused": ""
        }
    },

    "clock": {
        "format": " {:%H:%M   %d/%m}",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>",
        "on-click": "gnome-calendar"
    },

    "cpu": {
        "format": " {usage}%",
        "tooltip": false
    },

    "memory": {
        "format": " {}%",
        "tooltip-format": "Used: {used:0.1f}G / Total: {total:0.1f}G"
    },

    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "",
        "format-icons": {
            "default": ["", "", ""]
        },
        "on-click": "pavucontrol"
    },

    "network": {
        "format-wifi": " {essid}",
        "format-ethernet": " {ifname}",
        "format-disconnected": "⚠ Disconnected"
    },

    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-icons": ["", "", "", "", ""]
    }
}
EOF

cat > ~/.config/waybar/style.css <<'EOF'
* {
    font-family: "Noto Sans", "Font Awesome 6 Free", "Font Awesome 6 Brands", sans-serif;
    font-size: 13px;
    border: none;
    border-radius: 0;
}

window#waybar {
    background: rgba(43, 48, 59, 0.5);
    color: #ffffff;
    transition-property: background-color;
    transition-duration: .5s;
}

#workspaces button {
    padding: 0 5px;
    background: transparent;
    color: #ffffff;
}

#workspaces button.focused {
    color: #64727D;
    background-color: rgba(255, 255, 255, 0.1);
}

#clock, #cpu, #memory, #pulseaudio, #network, #battery, #tray {
    padding: 0 10px;
    margin: 4px 2px;
    border-radius: 8px;
    background-color: #383c4a;
}

#clock {
    background-color: #64727D;
    color: #ffffff;
    font-weight: bold;
}

#cpu { background-color: #4b5263; color: #fb8c00; }
#memory { background-color: #4b5263; color: #8e44ad; }
#pulseaudio { background-color: #4b5263; color: #2ecc71; }
#network { background-color: #4b5263; color: #3498db; }
#battery { background-color: #4b5263; color: #f1c40f; }

#battery.critical:not(.charging) {
    background-color: #f53c3c;
    color: #ffffff;
    animation-name: blink;
    animation-duration: 0.5s;
    animation-timing-function: linear;
    animation-iteration-count: infinite;
    animation-direction: alternate;
}

@keyframes blink {
    to { background-color: #ffffff; color: #000000; }
}
EOF

# ── Wofi ──────────────────────────────────────────────────
section "Wofi"

mkdir -p ~/.config/wofi

cat > ~/.config/wofi/config <<'EOF'
show=drun
prompt=Run:
width=400
height=300
EOF

# ── Done ──────────────────────────────────────────────────
section "Done"

echo -e "
${GREEN}${BOLD}✔ SETUP COMPLETE (PRETTIFIED)${RESET}

✔ Added Searchable Keybinding Cheat Sheet
✔ Press Mod+Shift+? to search keybinds
✔ Waybar now has Icons & Pill style
✔ Click Clock for Calendar

👉 Restart Sway to see the new bar and keybind!
"
