#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_ROOT="/opt/plex"
COMPOSE_FILE="$INSTALL_ROOT/compose.yml"
ENV_FILE="$INSTALL_ROOT/.env"

command -v docker >/dev/null || { echo "[!] Docker is required" >&2; exit 1; }

DEFAULT_MEDIA="/mnt/plexmedia"

ROOT="$INSTALL_ROOT"

read -r -p "Media directory [$DEFAULT_MEDIA]: " MEDIA_INPUT
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
cp "$PROJECT_DIR/run.sh" "$ROOT/run.sh"
chmod 755 "$ROOT/run.sh"

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
