#!/usr/bin/env bash
#
# googledrive.rclone.setup.sh
#
# Mounts a Google Drive account into GNOME Files (Nautilus) on Arch Linux
# using rclone + a systemd --user service.
#
# WHY THIS EXISTS
#   GNOME dropped native Google Drive support. The gvfs Google backend depended
#   on libgdata/libsoup2, unmaintained for ~4 years, and was removed upstream in
#   gvfs 1.60 (GNOME 50). Arch consequently dropped the `gvfs-google` package.
#   The "Files" toggle in Settings -> Online Accounts therefore does nothing for
#   Google accounts. rclone replaces that backend without touching any system
#   package, so it survives future gvfs/GNOME updates untouched.
#
# USAGE
#   ./googledrive.rclone.setup.sh              # install + configure + mount
#   ./googledrive.rclone.setup.sh --uninstall  # unmount, remove service+bookmark
#   ./googledrive.rclone.setup.sh --status     # show current state
#
# TUNABLES (override via environment)
#   REMOTE_NAME   rclone remote name              (default: gdrive-unisa)
#   MOUNT_DIR     where Drive appears             (default: $HOME/GoogleDrive-unisa)
#   BOOKMARK_NAME label in the Nautilus sidebar   (default: Google Drive (unisa))
#   CACHE_SIZE    local VFS cache cap             (default: 4G)
#   CLIENT_ID     your own Google OAuth client id (optional, see NOTE below)
#   CLIENT_SECRET your own Google OAuth secret    (optional)
#
# NOTE ON CLIENT_ID
#   rclone's built-in OAuth client is shared by every rclone user on earth and is
#   heavily rate-limited by Google, which shows up as slow directory listings.
#   For daily use, create your own (free, ~5 min):
#     https://rclone.org/drive/#making-your-own-client-id
#   Then re-run this script with CLIENT_ID=... CLIENT_SECRET=... set.
#
#   Google Workspace accounts (e.g. @unisa.it) may have third-party API access
#   restricted by the domain admin. If the OAuth consent screen refuses, that is
#   a domain policy, not a script bug.

set -euo pipefail

REMOTE_NAME="${REMOTE_NAME:-gdrive-unisa}"
MOUNT_DIR="${MOUNT_DIR:-$HOME/GoogleDrive-unisa}"
BOOKMARK_NAME="${BOOKMARK_NAME:-Google Drive (unisa)}"
CACHE_SIZE="${CACHE_SIZE:-4G}"
CLIENT_ID="${CLIENT_ID:-}"
CLIENT_SECRET="${CLIENT_SECRET:-}"

SERVICE_NAME="rclone-${REMOTE_NAME}.service"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/${SERVICE_NAME}"
RCLONE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf"
BOOKMARK_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"

if [[ -t 1 ]]; then
	B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
else
	B=""; R=""; G=""; Y=""; N=""
fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s  !!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------
preflight() {
	[[ $EUID -ne 0 ]] || die "Run as your normal user, not root. The mount and the systemd service are per-user."
	command -v pacman >/dev/null || die "This script targets Arch Linux (pacman not found)."
	command -v systemctl >/dev/null || die "systemd is required."
	# A user systemd instance must be reachable, otherwise `systemctl --user` fails
	# in confusing ways (e.g. over a bare SSH session with no lingering enabled).
	systemctl --user show-environment >/dev/null 2>&1 \
		|| die "No systemd --user instance reachable. Run this from your desktop session."
}

# --------------------------------------------------------------------------
# 1. packages
# --------------------------------------------------------------------------
install_packages() {
	local missing=()
	pacman -Qq rclone  >/dev/null 2>&1 || missing+=(rclone)
	pacman -Qq fuse3   >/dev/null 2>&1 || missing+=(fuse3)

	if ((${#missing[@]} == 0)); then
		ok "rclone and fuse3 already installed"
		return
	fi

	info "Installing: ${missing[*]}"
	sudo pacman -S --needed --noconfirm "${missing[@]}"
	ok "packages installed"
}

# --------------------------------------------------------------------------
# 2. rclone remote (interactive OAuth, opens a browser)
# --------------------------------------------------------------------------
configure_remote() {
	if rclone listremotes 2>/dev/null | grep -qx "${REMOTE_NAME}:"; then
		ok "rclone remote '${REMOTE_NAME}' already configured"
		return
	fi

	info "Creating rclone remote '${REMOTE_NAME}'"
	echo
	echo "  A browser window will open for Google sign-in."
	echo "  Sign in with the account you want mounted, then grant access."
	echo "  If no browser opens, copy the http://127.0.0.1:53682/ URL it prints."
	echo

	local args=("$REMOTE_NAME" drive scope=drive)
	if [[ -n $CLIENT_ID ]]; then
		args+=(client_id="$CLIENT_ID" client_secret="$CLIENT_SECRET")
		info "Using your own OAuth client id"
	else
		warn "Using rclone's shared OAuth client (rate-limited). See NOTE at the top of this script."
	fi

	if ! rclone config create "${args[@]}"; then
		die "OAuth failed. Run 'rclone config' manually: n -> ${REMOTE_NAME} -> drive -> scope 1 (full access)."
	fi
	ok "remote '${REMOTE_NAME}' created"
}

verify_remote() {
	info "Verifying access to ${REMOTE_NAME}:"
	if ! rclone about "${REMOTE_NAME}:" 2>/dev/null; then
		# `about` is unsupported on some Shared Drive setups; fall back to a listing.
		rclone lsd --max-depth 1 "${REMOTE_NAME}:" >/dev/null \
			|| die "Cannot read ${REMOTE_NAME}:. Re-run 'rclone config reconnect ${REMOTE_NAME}:'."
	fi
	ok "remote reachable"
}

# --------------------------------------------------------------------------
# 3. mount point
# --------------------------------------------------------------------------
create_mountpoint() {
	if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
		ok "already mounted at $MOUNT_DIR"
		return
	fi
	if [[ -d $MOUNT_DIR ]]; then
		# A non-empty mount point silently hides its contents once mounted over.
		if [[ -n $(ls -A "$MOUNT_DIR" 2>/dev/null) ]]; then
			die "$MOUNT_DIR exists and is not empty. Move its contents aside or set MOUNT_DIR=..."
		fi
		ok "mount point $MOUNT_DIR exists and is empty"
	else
		mkdir -p "$MOUNT_DIR"
		ok "created $MOUNT_DIR"
	fi
}

# --------------------------------------------------------------------------
# 4. systemd --user service
# --------------------------------------------------------------------------
write_service() {
	info "Writing $SERVICE_FILE"
	mkdir -p "$SERVICE_DIR"

	# --vfs-cache-mode=full is what makes ordinary desktop apps (LibreOffice,
	# GIMP, text editors) work against the mount: they expect seekable,
	# rewritable files, which the lighter cache modes do not provide.
	#
	# --dir-cache-time is long because --poll-interval picks up remote changes
	# via Drive's change API anyway; the long cache only affects how stale a
	# listing can get if polling fails.
	#
	# Careful: systemd splits ExecStart on whitespace and does NOT apply shell
	# quoting. Never interpolate a value that may contain spaces into a flag
	# here without wrapping it in double quotes, or the words after the first
	# space silently become extra positional arguments to rclone.
	cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=rclone mount of ${REMOTE_NAME} at ${MOUNT_DIR}
Documentation=https://rclone.org/commands/rclone_mount/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount ${REMOTE_NAME}: ${MOUNT_DIR} \\
    --config=${RCLONE_CONF} \\
    --vfs-cache-mode=full \\
    --vfs-cache-max-size=${CACHE_SIZE} \\
    --vfs-cache-max-age=48h \\
    --vfs-read-chunk-size=32M \\
    --vfs-read-chunk-size-limit=1G \\
    --dir-cache-time=72h \\
    --poll-interval=15s \\
    --drive-export-formats=docx,xlsx,pptx,svg \\
    --umask=077 \\
    --log-level=INFO
ExecStop=/usr/bin/fusermount3 -uz ${MOUNT_DIR}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

	systemctl --user daemon-reload
	ok "service written"
}

start_service() {
	info "Enabling and starting $SERVICE_NAME"
	systemctl --user enable --now "$SERVICE_NAME"

	# Type=notify means systemd returns once rclone reports the mount is live,
	# but give FUSE a moment before asserting on it.
	local i
	for i in {1..15}; do
		if mountpoint -q "$MOUNT_DIR"; then
			ok "mounted at $MOUNT_DIR"
			return
		fi
		sleep 1
	done

	systemctl --user status "$SERVICE_NAME" --no-pager --lines=20 || true
	die "Mount did not come up. Inspect: journalctl --user -u ${SERVICE_NAME} -e"
}

enable_lingering() {
	# Without lingering the mount dies when the last session closes, which is
	# surprising if anything (backup job, cron) expects it to be there.
	if loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
		ok "user lingering already enabled"
	else
		info "Enabling user lingering so the mount survives logout"
		sudo loginctl enable-linger "$USER" && ok "lingering enabled" \
			|| warn "could not enable lingering (mount will stop at logout)"
	fi
}

# --------------------------------------------------------------------------
# 5. Nautilus sidebar bookmark
# --------------------------------------------------------------------------
add_bookmark() {
	# Nautilus (still, on GNOME 50) reads GTK's bookmarks file.
	mkdir -p "$(dirname "$BOOKMARK_FILE")"
	touch "$BOOKMARK_FILE"

	local uri
	uri="file://$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$MOUNT_DIR" 2>/dev/null || echo "$MOUNT_DIR")"

	if grep -qF "$uri" "$BOOKMARK_FILE"; then
		ok "Nautilus bookmark already present"
		return
	fi
	printf '%s %s\n' "$uri" "$BOOKMARK_NAME" >> "$BOOKMARK_FILE"
	ok "added '$BOOKMARK_NAME' to the Nautilus sidebar"
}

# --------------------------------------------------------------------------
# uninstall / status
# --------------------------------------------------------------------------
do_uninstall() {
	info "Removing $SERVICE_NAME"
	systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
	mountpoint -q "$MOUNT_DIR" && fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
	rm -f "$SERVICE_FILE"
	systemctl --user daemon-reload
	ok "service removed"

	if [[ -f $BOOKMARK_FILE ]]; then
		local tmp; tmp=$(mktemp)
		grep -vF "$MOUNT_DIR" "$BOOKMARK_FILE" > "$tmp" || true
		mv "$tmp" "$BOOKMARK_FILE"
		ok "bookmark removed"
	fi

	[[ -d $MOUNT_DIR && -z $(ls -A "$MOUNT_DIR") ]] && rmdir "$MOUNT_DIR" && ok "removed empty $MOUNT_DIR"

	echo
	echo "The rclone remote '${REMOTE_NAME}' and its OAuth token were kept."
	echo "To drop those too:  rclone config delete ${REMOTE_NAME}"
}

do_status() {
	printf '%sremote%s   %s\n' "$B" "$N" "$(rclone listremotes 2>/dev/null | grep -x "${REMOTE_NAME}:" || echo 'not configured')"
	printf '%smount%s    %s\n' "$B" "$N" "$(mountpoint -q "$MOUNT_DIR" && echo "mounted at $MOUNT_DIR" || echo 'not mounted')"
	printf '%sservice%s  %s\n' "$B" "$N" "$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || echo inactive) / $(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null || echo disabled)"
	echo
	systemctl --user status "$SERVICE_NAME" --no-pager --lines=10 2>/dev/null || true
}

# --------------------------------------------------------------------------
main() {
	case "${1:-}" in
		--uninstall) preflight; do_uninstall; exit 0 ;;
		--status)    do_status; exit 0 ;;
		-h|--help)   sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		"")          ;;
		*)           die "Unknown option: $1 (try --help)" ;;
	esac

	preflight
	install_packages
	configure_remote
	verify_remote
	create_mountpoint
	write_service
	start_service
	enable_lingering
	add_bookmark

	echo
	ok "Done."
	echo
	echo "  Google Drive is mounted at: ${B}${MOUNT_DIR}${N}"
	echo "  It appears in the GNOME Files sidebar as '${BOOKMARK_NAME}'."
	echo "  (Press Ctrl+R in an open Nautilus window if the sidebar looks stale.)"
	echo
	echo "  logs      journalctl --user -u ${SERVICE_NAME} -f"
	echo "  stop      systemctl --user stop ${SERVICE_NAME}"
	echo "  start     systemctl --user start ${SERVICE_NAME}"
	echo "  status    $0 --status"
	echo "  remove    $0 --uninstall"
}

main "$@"
