#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ -t 1 ]; then
    COLOR_RESET=$'\033[0m'
    COLOR_LINE=$'\033[38;5;117m'
    COLOR_TEXT=$'\033[97m'
else
    COLOR_RESET=''
    COLOR_LINE=''
    COLOR_TEXT=''
fi

if command -v clear >/dev/null 2>&1 && [ -t 1 ]; then
    clear
else
    printf '\033c'
fi

printf '%s%s%s\n' "$COLOR_LINE" "Torrentflix" "$COLOR_RESET"
echo
printf '%s%s%s\n' "$COLOR_TEXT" "What would you like to install?" "$COLOR_RESET"
echo
printf '%s1.%s %sDeluge%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_TEXT" "$COLOR_RESET"
printf '   Download files with magnet links or torrent files.\n'
printf '%s2.%s %sPlex%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_TEXT" "$COLOR_RESET"
printf '   Stream your media library on your server.\n'
echo
read -r -p "?: " SERVICE
SERVICE="${SERVICE:-1}"

case "$SERVICE" in
    1)
        exec "$PROJECT_DIR/deluge/run.sh"
        ;;
    2)
        exec "$PROJECT_DIR/plex/run.sh"
        ;;
    *)
        echo "[!] Choose 1 or 2" >&2
        exit 1
        ;;
esac
