#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NGINX_DIR="$PROJECT_DIR/nginx"
CONFIG_DIR="$PROJECT_DIR/config"
THEME_DIR="$PROJECT_DIR/theme"
SECRETS_DIR="$PROJECT_DIR/secrets"
PASSWORD_FILE="$SECRETS_DIR/webui.password"
ENV_FILE="$PROJECT_DIR/.env"
NGINX_ENV_FILE="$NGINX_DIR/.env"
NGINX_RUNTIME_CONF="$NGINX_DIR/conf.d.runtime"
IMAGE="lscr.io/linuxserver/deluge:2.2.0"
WEB_DIR="/lsiopy/lib/python3.12/site-packages/deluge/ui/web"
THEME_URL="https://github.com/joelacus/deluge-web-dark-theme/raw/main/deluge_web_dark_theme.tar.gz"

die() { echo "[!] $*" >&2; exit 1; }
command -v docker >/dev/null || die "Docker is required"
command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"
command -v openssl >/dev/null || die "openssl is required"

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

cd "$PROJECT_DIR"
echo "[+] Building Deluge image..."
docker compose --env-file "$ENV_FILE" -f compose.yml build --pull
echo "[+] Starting Deluge..."
docker compose --env-file "$ENV_FILE" -f compose.yml up -d

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
    docker compose --env-file "$ENV_FILE" -f compose.yml logs --tail=100 deluge
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
    echo
    echo "Deluge is running in LAN/direct mode."
    echo "WebUI: http://SERVER_IP:8112"
elif [ "$DEPLOYMENT_MODE" = 3 ]; then
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
        -e "s#^NGINX_CONF_DIR=.*#NGINX_CONF_DIR=./conf.d.runtime#" \
        "$NGINX_ENV_FILE"
    chmod 600 "$NGINX_ENV_FILE"

    echo
    echo "Deluge is running without a bundled Nginx."
    echo "Generated Nginx config: $NGINX_RUNTIME_CONF/$DOMAIN.conf"
    echo "WebUI: http://SERVER_IP:8112"
else
    echo "[+] Preparing the bundled Nginx and ACME certificate..."
    rm -rf "$NGINX_RUNTIME_CONF"
    mkdir -p "$NGINX_RUNTIME_CONF"
    cp "$NGINX_DIR/conf.d/00-acme.conf" "$NGINX_RUNTIME_CONF/00-acme.conf"
    sed "s/domain\.com/$DOMAIN/g" \
        "$NGINX_DIR/conf.d/domain.com.conf" > "$NGINX_RUNTIME_CONF/$DOMAIN.conf"

    cp "$NGINX_DIR/.env.example" "$NGINX_ENV_FILE"
    sed -i \
        -e "s/^PRIMARY_DOMAIN=.*/PRIMARY_DOMAIN=$DOMAIN/" \
        -e "s/^WWW_DOMAIN=.*/WWW_DOMAIN=$WWW_DOMAIN/" \
        -e "s#^NGINX_CONF_DIR=.*#NGINX_CONF_DIR=./conf.d.runtime#" \
        "$NGINX_ENV_FILE"
    chmod 600 "$NGINX_ENV_FILE"

    docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null
    docker volume inspect nginx_acme_state >/dev/null 2>&1 || docker volume create nginx_acme_state >/dev/null
    docker network connect edge deluge >/dev/null 2>&1 || true

    (cd "$NGINX_DIR" && docker compose --env-file .env -f compose.yml build --pull)
    (cd "$NGINX_DIR" && docker compose --env-file .env -f compose.yml up -d)

    echo
    echo "Deluge and bundled Nginx are running."
    echo "URL: https://$WWW_DOMAIN/deluge/"
fi

echo "Password file: $PASSWORD_FILE"
echo "Downloads:     $DOWNLOAD_DIR"
