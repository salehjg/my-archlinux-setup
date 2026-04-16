#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Sway WM Setup Script
# ==========================================================
#
# KEYBINDINGS
# -----------
# Mod = Super (Windows) key
#
# Launching
#   Mod+Return          Open terminal (kitty)
#   Mod+D               App launcher (wofi)
#   Mod+Shift+P         Power menu (wlogout)
#   Mod+Shift+Q         Kill focused window
#
# System
#   Mod+Shift+C         Reload sway config
#   Mod+Shift+E         Exit sway
#   Mod+Shift+BackSpace  Lock screen (swaylock)
#   Mod+Shift+/         Searchable keybind cheat sheet
#
# Settings
#   Mod+Shift+D         Display settings (wdisplays)
#   Mod+Shift+A         Appearance/GTK settings (nwg-look)
#   Mod+Shift+M         Mouse speed picker
#
# Focus (vim-style or arrow keys)
#   Mod+H/J/K/L         Focus left/down/up/right
#   Mod+Left/Down/Up/Right
#
# Move windows
#   Mod+Shift+H/J/K/L   Move window left/down/up/right
#   Mod+Shift+Arrows
#
# Workspaces
#   Mod+1..10           Switch to workspace
#   Mod+Shift+1..10     Move window to workspace
#   Mod+ScrollUp/Down   Switch workspace
#   Mod+Shift+Scroll    Move window to prev/next workspace
#
# Layout
#   Mod+B               Split horizontal
#   Mod+V               Split vertical
#   Mod+S               Stacking layout
#   Mod+W               Tabbed layout
#   Mod+E               Toggle split
#   Mod+F               Fullscreen
#   Mod+Shift+Space     Toggle floating
#   Mod+Space           Focus mode toggle
#   Mod+A               Focus parent
#   Mod+R               Enter resize mode
#
# Scratchpad
#   Mod+Shift+-         Move window to scratchpad
#   Mod+-               Show scratchpad
#
# Media / Brightness
#   XF86AudioMute       Mute
#   XF86AudioLower/RaiseVolume
#   XF86MonBrightnessDown/Up
#   Print               Screenshot (region select, saves + copies to clipboard)
#
# Waybar (click)
#   Power profile       Click to cycle: performance / balanced / power-saver
#   Clock               Click to open calendar
#   Pulseaudio          Click to open pavucontrol
# ==========================================================

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

# ── Laptop selection ──────────────────────────────────────
echo ""
echo -e "${BOLD}Which laptop is this?${RESET}"
echo "  1) p16g2       — ThinkPad P16 Gen 2 (Intel + NVIDIA)"
echo "  2) pavilionx360 — HP Pavilion x360"
echo ""
read -rp "Enter 1 or 2: " laptop_choice
case "$laptop_choice" in
  1) LAPTOP="p16g2" ;;
  2) LAPTOP="pavilionx360" ;;
  *) error "Invalid choice." ;;
esac
info "Selected: $LAPTOP"

if [[ "$LAPTOP" == "pavilionx360" ]]; then
  error "pavilionx360 is not implemented yet."
fi

# ── Packages ───────────────────────────────────────────────
section "Installing packages"

PACKAGES=(
  sway swaybg swaylock swayidle
  kitty waybar wofi fuzzel
  xorg-xwayland
  vulkan-intel vulkan-icd-loader

  networkmanager network-manager-applet
  polkit-gnome gnome-keyring

  pipewire wireplumber pipewire-audio pipewire-pulse pipewire-alsa
  xdg-desktop-portal-wlr

  grim slurp wl-clipboard
  brightnessctl playerctl
  mako
  xdg-desktop-portal-gtk

  noto-fonts noto-fonts-emoji ttf-dejavu otf-font-awesome
  ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono
  git curl base-devel

  pavucontrol blueman power-profiles-daemon
  wdisplays
  intel-gpu-tools

  gnome-calendar gnome-online-accounts evolution-data-server evolution
)

sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"

# Grant intel_gpu_top permission to read performance counters without root
sudo setcap cap_perfmon+ep "$(which intel_gpu_top)"
info "Set cap_perfmon on intel_gpu_top"

# Rebuild font cache so waybar and apps find newly installed fonts
fc-cache -fv &>/dev/null
info "Font cache rebuilt"

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

# ── AUR packages ───────────────────────────────────────────
section "Installing AUR packages"
yay -S --needed --noconfirm wlogout       || warn "wlogout install failed"
yay -S --needed --noconfirm nwg-look      || warn "nwg-look install failed"
yay -S --needed --noconfirm forticlient-vpn || warn "forticlient-vpn install failed"
yay -S --needed --noconfirm way-displays   || warn "way-displays install failed"

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

GROUP_CHANGED=false
for grp in video render; do
  if ! id -nG | grep -qw "$grp"; then
    sudo usermod -aG "$grp" "$USER"
    info "Added $USER to $grp group"
    GROUP_CHANGED=true
  else
    info "$USER already in $grp group"
  fi
done
if [[ "$GROUP_CHANGED" == true ]]; then
  warn "Group membership changed — a reboot is required before launching Sway"
fi

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
# Detect Intel and NVIDIA DRM card devices by PCI vendor ID
find_gpu_card() {
  local vendor_id="$1"
  for p in /sys/bus/pci/devices/*/; do
    [[ "$(cat "$p/vendor" 2>/dev/null)" == "$vendor_id" ]] || continue
    [[ "$(cat "$p/class"  2>/dev/null)" == "0x030000"   ]] || continue
    for card in "$p"drm/card*/; do
      [[ -d "$card" ]] || continue
      card="${card%/}"
      echo "/dev/dri/${card##*drm/}"
      return
    done
  done
}

INTEL_CARD=$(find_gpu_card "0x8086")
NVIDIA_CARD=$(find_gpu_card "0x10de")

[[ -e "$INTEL_CARD" ]]  || error "Intel GPU DRM device not found"
[[ -e "$NVIDIA_CARD" ]] || error "NVIDIA GPU DRM device not found"
info "Intel GPU: $INTEL_CARD   NVIDIA GPU: $NVIDIA_CARD"
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

# ── Portal config ─────────────────────────────────────────
section "Configuring xdg-desktop-portal"

mkdir -p ~/.config/xdg-desktop-portal
cat > ~/.config/xdg-desktop-portal/sway-portals.conf <<EOF
[preferred]
default=gtk
org.freedesktop.impl.portal.Screenshot=wlr
org.freedesktop.impl.portal.ScreenCast=wlr
EOF
info "Portal: wlr for screen capture, gtk for everything else"

# ── way-displays (display persistence) ────────────────────
section "way-displays"

# way-displays auto-manages displays. Config is persisted in cfg.yaml.
# External display (HDMI-A-1) above internal (eDP-1), centered.
mkdir -p ~/.config/way-displays

cat > ~/.config/way-displays/cfg.yaml <<'EOF'
ARRANGE: COLUMN
ALIGN: MIDDLE
ORDER:
  - 'HDMI-A-1'
  - 'eDP-1'
MODE:
  - NAME_DESC: 'HDMI-A-1'
    MAX: TRUE
  - NAME_DESC: 'eDP-1'
    MAX: TRUE
SCALE:
  - NAME_DESC: 'eDP-1'
    SCALE: 1.5
VRR_OFF:
  - 'HDMI-A-1'
EOF
info "way-displays config written"

# ── Sway config ────────────────────────────────────────────
section "Configuring Sway"

SWAY_CFG="$HOME/.config/sway/config"
mkdir -p ~/.config/sway

# Always start from the distro default so re-running the script produces
# a clean, reproducible config with no leftover manual edits.
cp /etc/sway/config "$SWAY_CFG"
info "Reset sway config from /etc/sway/config"

# Remove conflicting default bindings
sed -i '/set \$menu wmenu-run/d' "$SWAY_CFG"
sed -i '/bindsym \$mod+d exec \$menu/d' "$SWAY_CFG"
sed -i '/bindsym Print exec grim$/d' "$SWAY_CFG"

# Remove default bar
sed -i '/^bar {/,/^}/d' "$SWAY_CFG"

# Append clean config
cat >> "$SWAY_CFG" <<'EOF'

# >>> sway-setup (managed)

# Terminal
set $term kitty

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
exec_always sh -c 'eval $(gnome-keyring-daemon --start --components=secrets,ssh 2>/dev/null)'

# Autostart apps
exec nm-applet --indicator
exec blueman-applet
exec waybar
exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
# way-displays: auto-manages display layout, persists to ~/.config/way-displays/cfg.yaml
exec way-displays > /tmp/way-displays.${XDG_VTNR}.${USER}.log 2>&1

# Notifications
exec mako

# FortiClient tray (handles VPN SAML trust dialogs)
exec /opt/forticlient/fortitraylauncher

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

# Keyboard
input type:keyboard {
    xkb_layout gb
    xkb_model pc105
    xkb_numlock enabled
}

# Mouse
input type:pointer {
    pointer_accel 0.0
    accel_profile flat
    natural_scroll disabled
}

# Lock screen
bindsym $mod+Shift+BackSpace exec swaylock -f -c 1a1a2e

# Screenshot (region select → save to ~/Pictures/Screenshots + copy to clipboard)
bindsym Print exec ~/.config/waybar/scripts/screenshot.sh

# Display settings
bindsym $mod+Shift+d exec wdisplays

# Appearance settings (GTK theme, cursor, fonts)
bindsym $mod+Shift+a exec nwg-look

# Mouse speed picker
bindsym $mod+Shift+m exec ~/.config/waybar/scripts/mouse-speed.sh

# Scroll through workspaces with mouse wheel
bindsym --whole-window $mod+button4 workspace prev
bindsym --whole-window $mod+button5 workspace next
bindsym --whole-window $mod+Shift+button4 move container to workspace prev; workspace prev
bindsym --whole-window $mod+Shift+button5 move container to workspace next; workspace next

# Idle
exec swayidle -w \
  timeout 300  'swaylock -f -c 1a1a2e' \
  timeout 600  'swaymsg "output * dpms off"' \
  resume        'swaymsg "output * dpms on"' \
  before-sleep 'swaylock -f -c 1a1a2e'

# <<< sway-setup
EOF

# ── Waybar scripts ────────────────────────────────────────
section "Waybar scripts"

mkdir -p ~/.config/waybar/scripts

# Intel iGPU usage — reads from sysfs (no root needed on xe/i915)
cat > ~/.config/waybar/scripts/gpu-intel.sh <<'EOF'
#!/bin/bash
intel_gpu_top -J -s 500 -n 1 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list): data = data[-1]
    engines = data.get('engines', {})
    vals = [e.get('busy', 0) for e in engines.values()]
    freq = data.get('frequency', {}).get('actual', 0)
    usage = int(max(vals)) if vals else 0
    print(json.dumps({'text': f'{usage}%', 'tooltip': f'Intel iGPU\nUsage: {usage}%\nFreq: {freq:.0f} MHz'}))
except:
    print(json.dumps({'text': '?%', 'tooltip': 'Intel iGPU\nData unavailable'}))
"
EOF
chmod +x ~/.config/waybar/scripts/gpu-intel.sh

# NVIDIA GPU usage
cat > ~/.config/waybar/scripts/gpu-nvidia.sh <<'EOF'
#!/bin/bash
nvidia-smi --query-gpu=utilization.gpu,clocks.current.graphics,temperature.gpu \
  --format=csv,noheader,nounits 2>/dev/null | python3 -c "
import json, sys
try:
    line = sys.stdin.read().strip()
    parts = [p.strip() for p in line.split(',')]
    usage, freq, temp = parts[0], parts[1], parts[2]
    print(json.dumps({'text': f'{usage}%', 'tooltip': f'NVIDIA RTX 2000\nUsage: {usage}%\nFreq: {freq} MHz\nTemp: {temp} C'}))
except:
    print(json.dumps({'text': '?%', 'tooltip': 'NVIDIA RTX 2000\nData unavailable'}))
"
EOF
chmod +x ~/.config/waybar/scripts/gpu-nvidia.sh

# Power profile: show current / cycle on click
cat > ~/.config/waybar/scripts/power-profile.sh <<'EOF'
#!/bin/bash
if [[ "$1" == "cycle" ]]; then
  current=$(powerprofilesctl get)
  case $current in
    performance) powerprofilesctl set balanced ;;
    balanced)    powerprofilesctl set power-saver ;;
    power-saver) powerprofilesctl set performance ;;
  esac
  exit 0
fi
current=$(powerprofilesctl get)
case $current in
  performance) echo '{"text":"󰓅 perf","class":"performance","tooltip":"Performance"}' ;;
  balanced)    echo '{"text":"󰾅 bal","class":"balanced","tooltip":"Balanced"}' ;;
  power-saver) echo '{"text":"󰾆 save","class":"power-saver","tooltip":"Power Saver"}' ;;
  *)           echo '{"text":"? '"$current"'","class":"unknown"}' ;;
esac
EOF
chmod +x ~/.config/waybar/scripts/power-profile.sh

# Mouse speed picker (wofi-based)
cat > ~/.config/waybar/scripts/mouse-speed.sh <<'EOF'
#!/bin/bash
choice=$(printf "very slow (-0.75)\nslow (-0.5)\nslightly slow (-0.25)\nnormal (0.0)\nslightly fast (0.25)\nfast (0.5)\nvery fast (0.75)\nmax (1.0)" | wofi --dmenu -p "Mouse speed" -i | grep -oP '[0-9.-]+')
[[ -z "$choice" ]] && exit 0
swaymsg "input type:pointer pointer_accel $choice"
swaymsg "input type:touchpad pointer_accel $choice"
notify-send "Mouse speed" "Set to $choice" 2>/dev/null || true
EOF
chmod +x ~/.config/waybar/scripts/mouse-speed.sh

# Screenshot: region select, save to file, copy to clipboard
cat > ~/.config/waybar/scripts/screenshot.sh <<'EOF'
#!/bin/bash
DIR="$HOME/Pictures/Screenshots"
mkdir -p "$DIR"
FILE="$DIR/$(date +%Y%m%d-%H%M%S).png"
region=$(slurp 2>/dev/null) || exit 0   # exit cleanly if user cancels
grim -g "$region" - | tee "$FILE" | wl-copy --type image/png
notify-send "Screenshot" "Saved to $FILE" 2>/dev/null || true
EOF
chmod +x ~/.config/waybar/scripts/screenshot.sh

info "Waybar scripts installed"

# ── Waybar ────────────────────────────────────────────────
section "Waybar (Config & Style)"

mkdir -p ~/.config/waybar

cat > ~/.config/waybar/config <<'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 34,
    "spacing": 4,
    "modules-left": ["sway/workspaces", "sway/mode"],
    "modules-center": ["clock"],
    "modules-right": ["custom/power-profile", "cpu", "custom/gpu-intel", "custom/gpu-nvidia", "memory", "pulseaudio", "network", "battery", "tray"],

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
    },

    "custom/gpu-intel": {
        "exec": "~/.config/waybar/scripts/gpu-intel.sh",
        "return-type": "json",
        "interval": 2,
        "format": "󰘚 {text}",
        "tooltip": true
    },

    "custom/gpu-nvidia": {
        "exec": "~/.config/waybar/scripts/gpu-nvidia.sh",
        "return-type": "json",
        "interval": 2,
        "format": "󰢮 {text}",
        "tooltip": true
    },

    "custom/power-profile": {
        "exec": "~/.config/waybar/scripts/power-profile.sh",
        "return-type": "json",
        "interval": 5,
        "on-click": "~/.config/waybar/scripts/power-profile.sh cycle",
        "format": "{}",
        "tooltip": true
    }
}
EOF

cat > ~/.config/waybar/style.css <<'EOF'
* {
    font-family: "Noto Sans", "Font Awesome 6 Free", "Font Awesome 6 Brands", "Symbols Nerd Font Mono", sans-serif;
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

#clock, #cpu, #memory, #pulseaudio, #network, #battery, #tray,
#custom-gpu-intel, #custom-gpu-nvidia, #custom-power-profile {
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

#cpu { background-color: #4b5263; color: #fb8c00; min-width: 58px; }
#memory { background-color: #4b5263; color: #8e44ad; min-width: 58px; }
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

#custom-gpu-intel  { background-color: #4b5263; color: #00bfff; min-width: 58px; }
#custom-gpu-nvidia { background-color: #4b5263; color: #76b900; min-width: 58px; }
#custom-power-profile { background-color: #4b5263; color: #ffffff; min-width: 68px; }
#custom-power-profile.performance { color: #ff6b6b; }
#custom-power-profile.balanced    { color: #ffffff; }
#custom-power-profile.power-saver { color: #a8e6cf; }
EOF

# ── Kitty (terminal) ──────────────────────────────────────
section "Kitty"

mkdir -p ~/.config/kitty

cat > ~/.config/kitty/kitty.conf <<'EOF'
font_family      monospace
font_size        12.0
enable_audio_bell no
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
${GREEN}${BOLD}SETUP COMPLETE${RESET}

Log out and select Sway from GDM to start.
See the top of this script for all keybindings.
"
