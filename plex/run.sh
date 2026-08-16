#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_ROOT="/opt/plex"
COMPOSE_FILE="$INSTALL_ROOT/compose.yml"
ENV_FILE="$INSTALL_ROOT/.env"

command -v docker >/dev/null || { echo "[!] Docker is required" >&2; exit 1; }

if [ -t 1 ]; then
    COLOR_RESET=$'\033[0m'
    COLOR_LINE=$'\033[38;5;117m'
else
    COLOR_RESET=''
    COLOR_LINE=''
fi

if command -v clear >/dev/null 2>&1 && [ -t 1 ]; then
    clear
else
    printf '\033c'
fi
printf '%s%s%s\n' "$COLOR_LINE" "Torrentflix Plex" "$COLOR_RESET"
echo

DEFAULT_MEDIA="/mnt/plexmedia"

ROOT="$INSTALL_ROOT"

printf '%sMedia directory [%s]: %s' "$COLOR_LINE" "$DEFAULT_MEDIA" "$COLOR_RESET"
read -r MEDIA_INPUT
MEDIA_DIR="${MEDIA_INPUT:-$DEFAULT_MEDIA}"
case "$MEDIA_DIR" in
    /*) ;;
    *) echo "[!] Media directory must be an absolute path" >&2; exit 1 ;;
esac

mkdir -p "$ROOT/config/plex/db" "$ROOT/config/plex/transcode" "$MEDIA_DIR"

echo "[+] Installing the Compose project into $ROOT..."
mkdir -p "$ROOT"
cp "$PROJECT_DIR/compose.yml" "$ROOT/compose.yml"
cp "$PROJECT_DIR/.env.example" "$ROOT/.env.example"

cat > "$ENV_FILE" <<EOF
ROOT=$ROOT
TZ=UTC
MEDIA_DIR=$MEDIA_DIR
EOF
chmod 600 "$ENV_FILE"

echo "[+] Starting Plex Media Server..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

echo
echo "Plex is running."
echo "WebUI:  http://SERVER_IP:32400/web"
echo "Media:  $MEDIA_DIR"
echo "Config: $ROOT/config/plex"
