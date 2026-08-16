#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMPOSE_FILE="$PROJECT_DIR/compose.yml"
ENV_FILE="$PROJECT_DIR/.env"

command -v docker >/dev/null || { echo "[!] Docker is required" >&2; exit 1; }

DEFAULT_ROOT="/opt/plex"
DEFAULT_MEDIA="/mnt/plexmedia"

read -r -p "Plex root directory [$DEFAULT_ROOT]: " ROOT_INPUT
ROOT="${ROOT_INPUT:-$DEFAULT_ROOT}"
case "$ROOT" in
    /*) ;;
    *) echo "[!] Plex root must be an absolute path" >&2; exit 1 ;;
esac

read -r -p "Media directory [$DEFAULT_MEDIA]: " MEDIA_INPUT
MEDIA_DIR="${MEDIA_INPUT:-$DEFAULT_MEDIA}"
case "$MEDIA_DIR" in
    /*) ;;
    *) echo "[!] Media directory must be an absolute path" >&2; exit 1 ;;
esac

mkdir -p "$ROOT/config/plex/db" "$ROOT/config/plex/transcode" "$MEDIA_DIR"

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
