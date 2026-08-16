#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_ROOT="/opt/deluge"
SOURCE_NGINX_DIR="$PROJECT_DIR/nginx"
NGINX_DIR="$INSTALL_ROOT/nginx"
CONFIG_DIR="$INSTALL_ROOT/config"
THEME_DIR="$INSTALL_ROOT/theme"
SECRETS_DIR="$INSTALL_ROOT/secrets"
PASSWORD_FILE="$SECRETS_DIR/webui.password"
ENV_FILE="$INSTALL_ROOT/.env"
NGINX_ENV_FILE="$INSTALL_ROOT/nginx/.env"
NGINX_RUNTIME_CONF="$INSTALL_ROOT/nginx/conf.d.runtime"
IMAGE="lscr.io/linuxserver/deluge:2.2.0"
WEB_DIR="/lsiopy/lib/python3.12/site-packages/deluge/ui/web"
THEME_URL="https://github.com/joelacus/deluge-web-dark-theme/raw/main/deluge_web_dark_theme.tar.gz"

die() { echo "[!] $*" >&2; exit 1; }
command -v docker >/dev/null || die "Docker is required"
command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"
command -v openssl >/dev/null || die "openssl is required"

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

echo "[+] Installing the Compose project into $INSTALL_ROOT..."
mkdir -p "$NGINX_DIR"
cp "$PROJECT_DIR/Dockerfile" "$INSTALL_ROOT/Dockerfile"
cp "$PROJECT_DIR/compose.yml" "$INSTALL_ROOT/compose.yml"
cp "$PROJECT_DIR/.dockerignore" "$INSTALL_ROOT/.dockerignore"
cp "$PROJECT_DIR/run.sh" "$INSTALL_ROOT/run.sh"
chmod 755 "$INSTALL_ROOT/run.sh"
cp "$SOURCE_NGINX_DIR/Dockerfile" "$NGINX_DIR/Dockerfile"
cp "$SOURCE_NGINX_DIR/compose.yml" "$NGINX_DIR/compose.yml"
cp "$SOURCE_NGINX_DIR/nginx.conf" "$NGINX_DIR/nginx.conf"
cp "$SOURCE_NGINX_DIR/.env.example" "$NGINX_DIR/.env.example"
rm -rf "$NGINX_DIR/conf.d"
cp -a "$SOURCE_NGINX_DIR/conf.d" "$NGINX_DIR/conf.d"

echo "Select deployment mode:"
echo "  1) VPS: Deluge + bundled Nginx + automatic Let's Encrypt certificate"
echo "  2) LAN: Deluge only, direct WebUI access, no Nginx"
echo "  3) Existing Nginx: Deluge + generated reverse-proxy configuration"
read -r -p "Mode [1]: " DEPLOYMENT_MODE
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-1}"
case "$DEPLOYMENT_MODE" in
    1|2|3) ;;
    *) die "Choose 1, 2 or 3" ;;
esac

DOMAIN=""
WWW_DOMAIN=""
if [ "$DEPLOYMENT_MODE" != 2 ]; then
    read -r -p "Public domain [domain.com]: " DOMAIN_INPUT
    DOMAIN="${DOMAIN_INPUT:-domain.com}"
    case "$DOMAIN" in
        ''|*[!A-Za-z0-9.-]*) die "Domain contains unsupported characters" ;;
    esac
    WWW_DOMAIN="www.$DOMAIN"
fi

mkdir -p "$CONFIG_DIR" "$SECRETS_DIR"
DEFAULT_DOWNLOAD_DIR="/mnt/downloads"
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

echo "[+] Building Deluge image..."
docker compose --env-file "$ENV_FILE" -f "$INSTALL_ROOT/compose.yml" build --pull
echo "[+] Starting Deluge..."
docker compose --env-file "$ENV_FILE" -f "$INSTALL_ROOT/compose.yml" up -d

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
    docker compose --env-file "$ENV_FILE" -f "$INSTALL_ROOT/compose.yml" logs --tail=100 deluge
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
    WEBUI_URL="https://$WWW_DOMAIN/deluge/"
    echo "[+] Generating configuration for an existing Nginx..."
    rm -rf "$NGINX_RUNTIME_CONF"
    mkdir -p "$NGINX_RUNTIME_CONF"
    cat > "$NGINX_RUNTIME_CONF/$DOMAIN.conf" <<EOF
server {
    listen 80;
    server_name $DOMAIN $WWW_DOMAIN;

    location = /deluge {
        return 301 /deluge/;
    }

    location ^~ /deluge/ {
        proxy_pass http://127.0.0.1:8112/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Deluge-Base "/deluge/";
        proxy_redirect off;
        proxy_buffering off;
    }
}
EOF
    cp "$NGINX_DIR/.env.example" "$NGINX_ENV_FILE"
    sed -i \
        -e "s/^PRIMARY_DOMAIN=.*/PRIMARY_DOMAIN=$DOMAIN/" \
        -e "s/^WWW_DOMAIN=.*/WWW_DOMAIN=$WWW_DOMAIN/" \
        -e "s#^NGINX_CONF_DIR=.*#NGINX_CONF_DIR=$NGINX_RUNTIME_CONF#" \
        "$NGINX_ENV_FILE"
    chmod 600 "$NGINX_ENV_FILE"

    echo
    echo "Deluge is running without a bundled Nginx."
    echo "Generated Nginx config: $NGINX_RUNTIME_CONF/$DOMAIN.conf"
    echo "WebUI: http://SERVER_IP:8112"
else
    WEBUI_URL="https://$WWW_DOMAIN/deluge/"
    echo "[+] Preparing the bundled Nginx and ACME certificate..."
    rm -rf "$NGINX_RUNTIME_CONF"
    mkdir -p "$NGINX_RUNTIME_CONF"
    cp "$NGINX_DIR/conf.d/00-acme.conf" "$NGINX_RUNTIME_CONF/00-acme.conf"
    sed "s/domain\.com/$DOMAIN/g" \
        "$NGINX_DIR/conf.d/domain.com.conf" > "$NGINX_RUNTIME_CONF/$DOMAIN.conf"

    mkdir -p "$(dirname "$NGINX_ENV_FILE")"
    cp "$NGINX_DIR/.env.example" "$NGINX_ENV_FILE"
    sed -i \
        -e "s/^PRIMARY_DOMAIN=.*/PRIMARY_DOMAIN=$DOMAIN/" \
        -e "s/^WWW_DOMAIN=.*/WWW_DOMAIN=$WWW_DOMAIN/" \
        -e "s#^NGINX_CONF_DIR=.*#NGINX_CONF_DIR=$NGINX_RUNTIME_CONF#" \
        "$NGINX_ENV_FILE"
    chmod 600 "$NGINX_ENV_FILE"

    docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null
    docker volume inspect nginx_acme_state >/dev/null 2>&1 || docker volume create nginx_acme_state >/dev/null
    docker network connect edge deluge >/dev/null 2>&1 || true

    docker compose --env-file "$NGINX_ENV_FILE" -f "$NGINX_DIR/compose.yml" build --pull
    docker compose --env-file "$NGINX_ENV_FILE" -f "$NGINX_DIR/compose.yml" up -d

    echo
    echo "Deluge and bundled Nginx are running."
    echo "URL: https://$WWW_DOMAIN/deluge/"
fi

if command -v clear >/dev/null 2>&1 && [ -t 1 ]; then
    clear
else
    printf '\033c'
fi

echo "======================================"
echo " Torrentflix Deluge installation done"
echo "======================================"
echo "Compose source: $INSTALL_ROOT"
echo "Compose file:   $INSTALL_ROOT/compose.yml"
echo "Runtime root:   $INSTALL_ROOT"
echo "WebUI URL:     $WEBUI_URL"
echo "Password file: $PASSWORD_FILE"
echo "WebUI password: $WEB_PASSWORD"
echo "Downloads:     $DOWNLOAD_DIR"
