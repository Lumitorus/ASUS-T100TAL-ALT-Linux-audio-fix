#!/bin/sh
# ASUS T100TAL / ALT Linux / WirePlumber 0.5. No external snapshot required.
set -eu
umask 077
MODE=check
TARGET_USER=
SNAPSHOT=
usage() {
    cat <<'EOF'
Usage: sh restore-t100-audio.sh [MODE] [--user LOGIN]
  --check          Read-only check (default).
  --install        Back up and install the two known working settings.
  --restart        Restart the selected user's audio services only.
  --backup         Save the current two settings without changing them.
  --restore DIR    Restore a snapshot made by this script.
  --help           Show this help.
Run from your regular desktop account. Root must specify --user LOGIN.
No firmware replacement, module unloading or automatic reboot is performed.
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
mode_seen=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --user) [ "$#" -ge 2 ] || die '--user requires a login'; TARGET_USER=$2; shift 2 ;;
        --check|--install|--restart|--backup)
            [ "$mode_seen" -eq 0 ] || die 'Choose one mode only'
            MODE=${1#--}; mode_seen=1; shift ;;
        --restore)
            [ "$mode_seen" -eq 0 ] || die 'Choose one mode only'
            [ "$#" -ge 2 ] || die '--restore requires a snapshot directory'
            MODE=restore; SNAPSHOT=$2; mode_seen=1; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[ "$(uname -s)" = Linux ] || die 'This script runs on Linux only'
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
[ "$MODEL" = T100TAL ] || die "Supported model is T100TAL; detected: $MODEL"
[ -r /etc/os-release ] || die 'Missing /etc/os-release'
# os-release is a system-owned shell-format file.
. /etc/os-release
[ "${ID:-}" = altlinux ] || die "Supported distribution is ALT Linux; detected: ${ID:-unknown}"
if [ -z "$TARGET_USER" ]; then
    TARGET_USER=${SUDO_USER:-$(id -un)}
fi
[ "$TARGET_USER" != root ] || die 'Specify the desktop account with --user LOGIN'
case "$TARGET_USER" in ''|*[!a-zA-Z0-9_.-]*) die 'Invalid login' ;; esac
ACCOUNT=$(getent passwd "$TARGET_USER") || die "Account not found: $TARGET_USER"
USER_ID=$(printf '%s\n' "$ACCOUNT" | cut -d: -f3)
USER_HOME=$(printf '%s\n' "$ACCOUNT" | cut -d: -f6)
case "$USER_HOME" in /*) ;; *) die 'Home directory is not absolute' ;; esac
[ "$USER_HOME" != / ] && [ -d "$USER_HOME" ] || die 'Invalid home directory'
[ "$USER_ID" -ne 0 ] || die 'The desktop account cannot have UID 0'
USER_GROUP=$(id -gn "$TARGET_USER")
SOF=/etc/modprobe.d/codex-t100-sof.conf
WP_DIR=$USER_HOME/.config/wireplumber/wireplumber.conf.d
WP=$WP_DIR/51-codex-t100-alsa.conf
run_user() {
    if [ "$(id -u)" = "$USER_ID" ]; then
        env HOME="$USER_HOME" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" "$@"
    else
        sudo -u "$TARGET_USER" env HOME="$USER_HOME" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" "$@"
    fi
}
check_session() {
    [ -S "/run/user/$USER_ID/bus" ] || die "Log into the desktop as $TARGET_USER first"
    run_user systemctl --user show-environment >/dev/null || die 'User systemd is unavailable'
}
check_versions() {
    command -v wireplumber >/dev/null || die 'WirePlumber is not installed'
    wireplumber --version | grep -Eq '(^|[^0-9])0\.5\.' || die 'This configuration requires WirePlumber 0.5.x'
    command -v pipewire >/dev/null || die 'PipeWire is not installed'
}
sof_contents() {
    printf '%s\n' '# Bay Trail SOF: enable DMA trace' 'options snd_sof sof_debug=1'
}
wp_contents() {
    cat <<'EOF'
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_.*platform-bytcr_rt5640.*" } ]
    actions = {
      update-props = {
        audio.format = "S16LE"
        api.alsa.disable-mmap = true
      }
    }
  }
]
EOF
}
if [ "$MODE" = check ]; then
    printf 'Model: %s\nUser: %s\nKernel: %s\n' "$MODEL" "$TARGET_USER" "$(uname -r)"
    cat /proc/asound/cards 2>/dev/null || true
    printf 'sof_debug: '; cat /sys/module/snd_sof/parameters/sof_debug 2>/dev/null || printf 'not loaded\n'
    command -v wireplumber >/dev/null && wireplumber --version || true
    command -v pipewire >/dev/null && pipewire --version || true
    if [ -r "$SOF" ] && sof_contents | cmp -s - "$SOF"; then
        printf 'SOF configuration matches\n'
    else
        printf 'SOF configuration missing, unreadable or different\n'
    fi
    if [ -r "$WP" ] && wp_contents | cmp -s - "$WP"; then
        printf 'WirePlumber configuration matches\n'
    else
        printf 'WirePlumber configuration missing, unreadable or different\n'
    fi
    if [ -S "/run/user/$USER_ID/bus" ]; then
        run_user systemctl --user is-active pipewire wireplumber || true
        run_user wpctl status || true
    fi
    exit 0
fi
if [ "$(id -u)" -ne 0 ]; then
    SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
    if [ "$MODE" = restore ]; then
        SNAPSHOT=$(CDPATH= cd -- "$SNAPSHOT" && pwd) || die 'Snapshot directory not found'
        exec sudo sh "$SELF" --restore "$SNAPSHOT" --user "$TARGET_USER"
    fi
    exec sudo sh "$SELF" "--$MODE" --user "$TARGET_USER"
fi
[ ! -L "$SOF" ] && [ ! -L "$WP" ] || die 'Refusing to replace symlinked settings'
backup() {
    BACKUP=$(mktemp -d /var/backups/t100-audio-XXXXXXXX)
    printf '%s\n' "$TARGET_USER" > "$BACKUP/user.txt"
    printf '%s\n' "$MODEL" > "$BACKUP/model.txt"
    uname -r > "$BACKUP/kernel.txt"
    if [ -f "$SOF" ]; then cp -p "$SOF" "$BACKUP/sof.conf"; else : > "$BACKUP/sof.absent"; fi
    if [ -f "$WP" ]; then cp -p "$WP" "$BACKUP/wireplumber.conf"; else : > "$BACKUP/wireplumber.absent"; fi
    (cd "$BACKUP"; for f in ./*.txt ./*.conf ./*.absent; do
        [ ! -f "$f" ] || sha256sum "$f"
    done) > "$BACKUP/SHA256SUMS"
    printf 'Snapshot saved: %s\n' "$BACKUP"
}
prepare_wp_dir() {
    [ -d "$USER_HOME/.config" ] || install -d -o "$TARGET_USER" -g "$USER_GROUP" -m 700 "$USER_HOME/.config"
    [ -d "$USER_HOME/.config/wireplumber" ] || install -d -o "$TARGET_USER" -g "$USER_GROUP" -m 700 "$USER_HOME/.config/wireplumber"
    [ -d "$WP_DIR" ] || install -d -o "$TARGET_USER" -g "$USER_GROUP" -m 700 "$WP_DIR"
}
restart_audio() {
    run_user systemctl --user restart pipewire pipewire-pulse wireplumber
    printf 'Audio services restarted; restart playback in your player if needed.\n'
}
case "$MODE" in
    backup) backup; exit 0 ;;
    restart) check_session; restart_audio; exit 0 ;;
    install)
        check_versions
        check_session
        grep -q 'sof-bytcht.*rt5640' /proc/asound/cards || die 'SOF/RT5640 card not registered; investigate the kernel first'
        # Do not silently override settings created by another guide.
        for f in /etc/modprobe.d/*.conf; do
            [ -f "$f" ] || continue
            [ "$f" = "$SOF" ] && continue
            if grep -Eq '^[[:space:]]*(options[[:space:]]+snd_(sof|intel_dspcfg|soc_sst_bytcr_rt5640)[[:space:]]|blacklist[[:space:]]+snd_sof)' "$f"; then
                die "Review conflicting driver settings before installation: $f"
            fi
        done
        for dir in "$WP_DIR" /etc/wireplumber/wireplumber.conf.d; do
            for f in "$dir"/*.conf; do
                [ -f "$f" ] || continue
                [ "$f" = "$WP" ] && continue
                if grep -Eq 'bytcr_rt5640|api\.alsa\.(disable-mmap|period-size|headroom)|audio\.format' "$f"; then
                    die "Review overlapping WirePlumber rules before installation: $f"
                fi
            done
        done
        backup
        prepare_wp_dir
        sof_contents > "$BACKUP/new-sof.conf"
        wp_contents > "$BACKUP/new-wireplumber.conf"
        install -m 644 "$BACKUP/new-sof.conf" "$SOF"
        install -o "$TARGET_USER" -g "$USER_GROUP" -m 644 "$BACKUP/new-wireplumber.conf" "$WP"
        restart_audio
        printf 'Settings installed. Save your work, then reboot normally: sudo systemctl reboot\n'
        ;;
    restore)
        check_session
        SNAPSHOT=$(CDPATH= cd -- "$SNAPSHOT" && pwd) || die 'Snapshot directory not found'
        [ -f "$SNAPSHOT/SHA256SUMS" ] || die 'Missing snapshot checksums'
        [ "$(cat "$SNAPSHOT/user.txt")" = "$TARGET_USER" ] || die 'Snapshot belongs to a different user'
        [ "$(cat "$SNAPSHOT/model.txt")" = "$MODEL" ] || die 'Snapshot belongs to a different model'
        # Accept only our fixed filenames; never treat a manifest as a path list to restore.
        for entry in sof wireplumber; do
            [ -f "$SNAPSHOT/$entry.conf" ] && [ ! -f "$SNAPSHOT/$entry.absent" ] || {
                [ -f "$SNAPSHOT/$entry.absent" ] && [ ! -f "$SNAPSHOT/$entry.conf" ] || die "Invalid snapshot entry: $entry"
            }
        done
        [ "$(wc -l < "$SNAPSHOT/SHA256SUMS")" -eq 5 ] || die 'Incomplete snapshot manifest'
        for name in user.txt model.txt kernel.txt; do
            grep -Eq "^[a-f0-9]{64} [ *]\\./$name$" "$SNAPSHOT/SHA256SUMS" || die "Missing checksum: $name"
        done
        for entry in sof wireplumber; do
            if [ -f "$SNAPSHOT/$entry.conf" ]; then name=$entry.conf; else name=$entry.absent; fi
            grep -Eq "^[a-f0-9]{64} [ *]\\./$name$" "$SNAPSHOT/SHA256SUMS" || die "Missing checksum: $name"
        done
        (cd "$SNAPSHOT" && sha256sum -c SHA256SUMS) || die 'Snapshot checksum verification failed'
        SOURCE=$SNAPSHOT
        backup
        prepare_wp_dir
        if [ -f "$SOURCE/sof.conf" ]; then install -m 644 "$SOURCE/sof.conf" "$SOF"; else rm -f "$SOF"; fi
        if [ -f "$SOURCE/wireplumber.conf" ]; then
            install -o "$TARGET_USER" -g "$USER_GROUP" -m 644 "$SOURCE/wireplumber.conf" "$WP"
        else rm -f "$WP"; fi
        restart_audio
        printf 'Snapshot restored. Save your work, then reboot normally: sudo systemctl reboot\n'
        ;;
esac
