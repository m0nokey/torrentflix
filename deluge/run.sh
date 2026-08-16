#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SOURCE_NGINX_DIR="$PROJECT_DIR/nginx"
IMAGE="lscr.io/linuxserver/deluge:2.2.0"
WEB_DIR="/lsiopy/lib/python3.12/site-packages/deluge/ui/web"
THEME_URL="https://github.com/joelacus/deluge-web-dark-theme/raw/main/deluge_web_dark_theme.tar.gz"

if [ -t 1 ]; then
    COLOR_RESET=$'\033[0m'
    COLOR_TEXT=$'\033[97m'
    COLOR_LINE=$'\033[38;5;117m'
    COLOR_MUTED_ITALIC=$'\033[3;38;5;245m'
else
    COLOR_RESET=''
    COLOR_TEXT=''
    COLOR_LINE=''
    COLOR_MUTED_ITALIC=''
fi

die() { echo "[!] $*" >&2; exit 1; }
clear_terminal() {
    if command -v clear >/dev/null 2>&1 && [ -t 1 ]; then
        clear
    else
        printf '\033c'
    fi
}
compose_is_running() {
    local compose_file="$1" root="${2%/*}" args=(-f "$1")
    if [ -f "$root/.env" ]; then
        args=(--env-file "$root/.env" "${args[@]}")
    fi
    [ -n "$(docker compose "${args[@]}" ps -q 2>/dev/null || true)" ]
}
stop_compose_stack() {
    local compose_file="$1" root="${1%/*}" args=(-f "$1")
    if [ -f "$root/.env" ]; then
        args=(--env-file "$root/.env" "${args[@]}")
    fi
    docker compose "${args[@]}" down --remove-orphans
}
command -v docker >/dev/null || die "Docker is required"
command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"
command -v openssl >/dev/null || die "openssl is required"

clear_terminal
printf '%s%s%s\n' "$COLOR_LINE" "Torrentflix Deluge" "$COLOR_RESET"
echo
printf '%s%s%s\n' "$COLOR_TEXT" "Select deployment mode." "$COLOR_RESET"
echo
printf '%s%s.%s %s%s%s\n' "$COLOR_LINE" "1" "$COLOR_RESET" "$COLOR_TEXT" "VPS / public HTTPS access" "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Requires a domain pointing to this VPS and open ports 80/443." "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Bundled Nginx obtains and renews the Let's Encrypt certificate." "$COLOR_RESET"
printf '%s%s.%s %s%s%s\n' "$COLOR_LINE" "2" "$COLOR_RESET" "$COLOR_TEXT" "LAN / local network access" "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   No domain and no Nginx required. Open http://SERVER_IP:8112." "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Suitable for a home network or an existing reverse proxy." "$COLOR_RESET"
printf '%s%s.%s %s%s%s\n' "$COLOR_LINE" "3" "$COLOR_RESET" "$COLOR_TEXT" "macOS / Docker Desktop" "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   No root access, domain, or Nginx required. Open http://localhost:8112." "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Project and downloads stay under ~/Downloads/deluge." "$COLOR_RESET"
echo
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "Technical: VPS mode keeps Deluge on 127.0.0.1:8112 and publishes HTTPS through Nginx." "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "           LAN mode publishes Deluge WebUI directly on port 8112." "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "           macOS mode binds WebUI to 127.0.0.1 and uses Docker Desktop." "$COLOR_RESET"
echo
read -r -p "?: " DEPLOYMENT_MODE
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-1}"
case "$DEPLOYMENT_MODE" in
    1|2|3) ;;
    *) die "Choose 1, 2 or 3" ;;
esac

clear_terminal

if [ "$DEPLOYMENT_MODE" = 3 ]; then
    [ -n "${HOME:-}" ] || die "HOME is not set"
    INSTALL_ROOT="$HOME/Downloads/deluge"
    DEFAULT_DOWNLOAD_DIR="$INSTALL_ROOT/downloads"
    WEB_BIND_IP="127.0.0.1"
else
    INSTALL_ROOT="/opt/deluge"
    DEFAULT_DOWNLOAD_DIR="/mnt/downloads"
    WEB_BIND_IP="0.0.0.0"
fi

NGINX_DIR="$INSTALL_ROOT/nginx"
CONFIG_DIR="$INSTALL_ROOT/config"
THEME_DIR="$INSTALL_ROOT/theme"
SECRETS_DIR="$INSTALL_ROOT/secrets"
PASSWORD_FILE="$SECRETS_DIR/webui.password"
ENV_FILE="$INSTALL_ROOT/.env"
NGINX_RUNTIME_CONF="$INSTALL_ROOT/nginx/conf.d.runtime"
COMPOSE_FILE="$INSTALL_ROOT/compose.yml"

declare -a EXISTING_STACKS=()
declare -a CANDIDATE_ROOTS=("/opt/deluge")
if [ -n "${HOME:-}" ]; then
    CANDIDATE_ROOTS+=("$HOME/Downloads/deluge")
fi

for candidate_root in "${CANDIDATE_ROOTS[@]}"; do
    for candidate_file in \
        "$candidate_root/compose.vps.yml" \
        "$candidate_root/compose.yml" \
        "$candidate_root/nginx/compose.yml"
    do
        if [ -f "$candidate_file" ] && compose_is_running "$candidate_file"; then
            EXISTING_STACKS+=("$candidate_file")
        fi
    done
done

if [ "${#EXISTING_STACKS[@]}" -gt 0 ]; then
    clear_terminal
    printf '%s%s%s\n' "$COLOR_LINE" "A running Torrentflix installation was found" "$COLOR_RESET"
    echo
    for existing_stack in "${EXISTING_STACKS[@]}"; do
        printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Running: $existing_stack" "$COLOR_RESET"
    done
    echo
    printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   The container will be stopped. Config, password and downloads will be kept." "$COLOR_RESET"
    echo
    printf '%s%s.%s %s%s%s\n' "$COLOR_LINE" "1" "$COLOR_RESET" "$COLOR_TEXT" "Stop it and continue installation" "$COLOR_RESET"
    printf '%s%s.%s %s%s%s\n' "$COLOR_LINE" "2" "$COLOR_RESET" "$COLOR_TEXT" "Cancel" "$COLOR_RESET"
    echo
    read -r -p "?: " STOP_EXISTING
    STOP_EXISTING="${STOP_EXISTING:-1}"
    case "$STOP_EXISTING" in
        1)
            clear_terminal
            for existing_stack in "${EXISTING_STACKS[@]}"; do
                echo "[+] Stopping $existing_stack..."
                stop_compose_stack "$existing_stack"
            done
            ;;
        2) exit 0 ;;
        *) die "Choose 1 or 2" ;;
    esac
fi

mkdir -p "$INSTALL_ROOT"

# Migrate runtime data from an older checkout-based installation.
if [ "$PROJECT_DIR/config" != "$CONFIG_DIR" ] && [ -d "$PROJECT_DIR/config" ] && [ ! -e "$CONFIG_DIR/.migrated" ]; then
    mkdir -p "$CONFIG_DIR"
    cp -a "$PROJECT_DIR/config/." "$CONFIG_DIR/"
    touch "$CONFIG_DIR/.migrated"
fi
if [ "$PROJECT_DIR/secrets" != "$SECRETS_DIR" ] && [ -f "$PROJECT_DIR/secrets/webui.password" ] && [ ! -f "$PASSWORD_FILE" ]; then
    mkdir -p "$SECRETS_DIR"
    cp -a "$PROJECT_DIR/secrets/webui.password" "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
fi

DOMAIN=""
WWW_DOMAIN=""
if [ "$DEPLOYMENT_MODE" = 1 ]; then
    read -r -p "Domain pointing to this VPS [domain.com]: " DOMAIN_INPUT
    DOMAIN="${DOMAIN_INPUT:-domain.com}"
    case "$DOMAIN" in
        ''|*[!A-Za-z0-9.-]*) die "Domain contains unsupported characters" ;;
    esac
    WWW_DOMAIN="www.$DOMAIN"
fi

echo "[+] Installing the required project files into $INSTALL_ROOT..."
cp "$PROJECT_DIR/Dockerfile" "$INSTALL_ROOT/Dockerfile"
cp "$PROJECT_DIR/compose.yml" "$INSTALL_ROOT/compose.yml"
cp "$PROJECT_DIR/.dockerignore" "$INSTALL_ROOT/.dockerignore"

rm -rf "$NGINX_DIR" "$INSTALL_ROOT/compose.vps.yml"

if [ "$DEPLOYMENT_MODE" = 1 ]; then
    COMPOSE_FILE="$INSTALL_ROOT/compose.vps.yml"
    NGINX_RUNTIME_CONF="$NGINX_DIR/conf.d.runtime"
    cp "$PROJECT_DIR/compose.vps.yml" "$COMPOSE_FILE"
    mkdir -p "$NGINX_DIR/conf.d.runtime" "$NGINX_DIR/www"
    cp "$SOURCE_NGINX_DIR/Dockerfile" "$NGINX_DIR/Dockerfile"
    cp "$SOURCE_NGINX_DIR/nginx.conf" "$NGINX_DIR/nginx.conf"
fi

mkdir -p "$CONFIG_DIR" "$SECRETS_DIR"
read -r -p "Download directory [$DEFAULT_DOWNLOAD_DIR]: " DOWNLOAD_DIR_INPUT
DOWNLOAD_DIR="${DOWNLOAD_DIR_INPUT:-$DEFAULT_DOWNLOAD_DIR}"
case "$DOWNLOAD_DIR" in
    /*) ;;
    *) die "Download directory must be absolute" ;;
esac
mkdir -p "$DOWNLOAD_DIR"

PUID="$(id -u)"
PGID="$(id -g)"
cat > "$ENV_FILE" <<EOF
DOWNLOAD_DIR=$DOWNLOAD_DIR
DELUGE_IMAGE=$IMAGE
WEB_DIR=$WEB_DIR
DELUGE_ROOT=$INSTALL_ROOT
PUID=$PUID
PGID=$PGID
WEB_PORT=8112
WEB_BIND_IP=$WEB_BIND_IP
DEPLOYMENT_MODE=$DEPLOYMENT_MODE
PRIMARY_DOMAIN=$DOMAIN
WWW_DOMAIN=$WWW_DOMAIN
EOF
chmod 600 "$ENV_FILE"

if [ ! -s "$PASSWORD_FILE" ]; then
    umask 077
    openssl rand -hex 16 > "$PASSWORD_FILE"
fi
chmod 600 "$PASSWORD_FILE"

echo "[+] Downloading theme..."
rm -rf "$THEME_DIR"
mkdir -p "$THEME_DIR"
curl -fsSL "$THEME_URL" | tar -xz -C "$THEME_DIR"
[ -d "$THEME_DIR/icons" ] || die "Theme icons are missing"
[ -d "$THEME_DIR/images" ] || die "Theme images are missing"
[ -f "$THEME_DIR/themes/css/xtheme-dark.css" ] || die "Theme CSS is missing"

if [ "$DEPLOYMENT_MODE" = 1 ]; then
    echo "[+] Generating bundled Nginx configuration..."
    rm -rf "$NGINX_RUNTIME_CONF"
    mkdir -p "$NGINX_RUNTIME_CONF"
    cp "$SOURCE_NGINX_DIR/conf.d/00-acme.conf" "$NGINX_RUNTIME_CONF/00-acme.conf"
    sed "s/domain\.com/$DOMAIN/g" \
        "$SOURCE_NGINX_DIR/conf.d/domain.com.conf" > "$NGINX_RUNTIME_CONF/$DOMAIN.conf"
fi

echo "[+] Building Deluge image..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" build --pull
echo "[+] Starting Deluge..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

echo "[+] Waiting for Deluge WebUI..."
READY=0
for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:8112/" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done

if [ "$READY" != 1 ]; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --tail=100 deluge
    die "WebUI failed"
fi

COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
WEB_URL="http://127.0.0.1:8112/json"
WEB_PASSWORD="$(cat "$PASSWORD_FILE")"

rpc() {
    printf '%s' "$1" | curl -fsS -c "$COOKIE" -b "$COOKIE" \
        -H 'Content-Type: application/json' --data-binary @- "$WEB_URL"
}

LOGIN="$(rpc "{\"method\":\"auth.login\",\"params\":[\"$WEB_PASSWORD\"],\"id\":1}")"

if echo "$LOGIN" | grep -q '"result": true'; then
    echo "[+] Existing WebUI password accepted"
else
    LOGIN="$(rpc '{"method":"auth.login","params":["deluge"],"id":1}')"
    echo "$LOGIN" | grep -q '"result": true' || die "WebUI login failed: $LOGIN"

    echo "[+] Changing WebUI password..."
    PASSWORD_RESULT="$(
        printf '%s' \
            "{\"method\":\"auth.change_password\",\"params\":[\"deluge\",\"$WEB_PASSWORD\"],\"id\":2}" |
        curl -fsS -c "$COOKIE" -b "$COOKIE" \
            -H 'Content-Type: application/json' --data-binary @- "$WEB_URL"
    )"
    echo "$PASSWORD_RESULT" | grep -q '"result": true' || {
        echo "[!] Password change failed: $PASSWORD_RESULT"
        exit 1
    }
fi

THEME_RESULT="$(rpc '{"method":"web.set_theme","params":["dark"],"id":3}')"
echo "$THEME_RESULT" | grep -Eq '"result": true|"error": null' || die "Theme API failed: $THEME_RESULT"

if [ "$DEPLOYMENT_MODE" = 2 ]; then
    WEBUI_URL="http://SERVER_IP:8112"
    echo
    echo "Deluge is running in LAN/direct mode."
    echo "WebUI: http://SERVER_IP:8112"
elif [ "$DEPLOYMENT_MODE" = 3 ]; then
    WEBUI_URL="http://localhost:8112"
    echo
    echo "Deluge is running on macOS through Docker Desktop."
    echo "WebUI: http://localhost:8112"
else
    WEBUI_URL="https://$WWW_DOMAIN/deluge/"
    echo
    echo "Deluge and bundled Nginx are running."
    echo "URL: https://$WWW_DOMAIN/deluge/"
fi

clear_terminal
echo "Runtime root:   $INSTALL_ROOT"
echo "WebUI URL:     $WEBUI_URL"
echo "Password file: $PASSWORD_FILE"
echo "WebUI password: $WEB_PASSWORD"
echo "Downloads:     $DOWNLOAD_DIR"
