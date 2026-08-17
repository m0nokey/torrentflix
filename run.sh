#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
HOST_OS="$(uname -s 2>/dev/null || printf 'unknown')"

if [ -t 1 ]; then
    RESET=$'\033[0m'; LINE=$'\033[38;5;117m'; TEXT=$'\033[97m'; MUTED=$'\033[3;38;5;245m'
else
    RESET=''; LINE=''; TEXT=''; MUTED=''
fi

readonly DEFAULT_MEDIA_GID=10000
readonly DEFAULT_DELUGE_UID=10001
readonly DEFAULT_PLEX_UID=10002
readonly DELUGE_IMAGE='lscr.io/linuxserver/deluge:2.2.0@sha256:33a939576f7ecfc1227db1a0cb2afce030ce983e620ec9d93c956e3700e21fe9'
readonly WEB_DIR='/lsiopy/lib/python3.12/site-packages/deluge/ui/web'
readonly THEME_COMMIT='dbef18e3c9a2cb0f2448d16bb95dca868f94440e'
readonly THEME_SHA256='5c3e6a4453fb06c16bc89f3b3789f12ba56b01addc111477211cb63e93f291bb'

die() { echo "[!] $*" >&2; exit 1; }
clear_terminal() { if [ -t 1 ] && command -v clear >/dev/null 2>&1; then clear; else printf '\033c'; fi; }

env_value() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

write_env() {
    local file="$1"
    shift
    umask 077
    : > "$file"
    while [ "$#" -gt 1 ]; do printf '%s=%s\n' "$1" "$2" >> "$file"; shift 2; done
    chmod 600 "$file"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

canonical_path() {
    if command -v realpath >/dev/null 2>&1; then realpath -m -- "$1" 2>/dev/null && return; fi
    python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(os.path.abspath(sys.argv[1])))
PY
}

path_contains() {
    local parent child
    parent="$(canonical_path "$1")"; child="$(canonical_path "$2")"
    [ "$parent" = "$child" ] || [[ "$child" == "$parent"/* ]]
}

assert_no_source_overlap() {
    local runtime_root="$1" downloads="$2"
    if path_contains "$SCRIPT_DIR" "$runtime_root" || path_contains "$runtime_root" "$SCRIPT_DIR" ||
       path_contains "$SCRIPT_DIR" "$downloads" || path_contains "$downloads" "$SCRIPT_DIR"; then
        die 'Git checkout, runtime and downloads must be separate directories'
    fi
}

write_marker() {
    local root="$1" type="$2"
    printf 'managed-by=torrentflix\ntype=%s\n' "$type" > "$root/.torrentflix-managed"
    chmod 600 "$root/.torrentflix-managed"
}

marker_matches() {
    local root="$1" type="$2"
    [ -f "$root/.torrentflix-managed" ] && grep -qx 'managed-by=torrentflix' "$root/.torrentflix-managed" && grep -qx "type=$type" "$root/.torrentflix-managed"
}

managed_dir() {
    local path="$1" owner="$2" group="$3" mode="$4" type="$5"
    [ -n "$path" ] && [ "$path" != / ] || die 'Refusing an empty or root path'
    [ ! -L "$path" ] || die "Refusing a symbolic-link managed path: $path"
    if [ -e "$path" ]; then
        [ -d "$path" ] || die "Managed path is not a directory: $path"
        if [ -f "$path/.torrentflix-managed" ]; then
            marker_matches "$path" "$type" || die "Managed marker mismatch: $path"
        elif [ -n "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
            die "Refusing to take ownership of a non-empty unmarked directory: $path"
        else
            write_marker "$path" "$type"
        fi
    else
        install -d -o "$owner" -g "$group" -m "$mode" "$path"
        write_marker "$path" "$type"
    fi
    chown "$owner:$group" "$path" "$path/.torrentflix-managed"
    chmod "$mode" "$path"
}

id_in_use() { getent passwd "$1" >/dev/null 2>&1 || getent group "$1" >/dev/null 2>&1; }
next_free_id() {
    local id="$1"
    while id_in_use "$id" || [ "$id" = "${MEDIA_GID:-}" ] || [ "$id" = "${DELUGE_UID:-}" ] || [ "$id" = "${PLEX_UID:-}" ]; do id=$((id + 1)); done
    printf '%s\n' "$id"
}

configure_paths() {
    if [ "$MODE" = local ]; then
        if [ "$HOST_OS" = Darwin ]; then LOCAL_ROOT="$REAL_HOME/Library/Application Support/Torrentflix"; else LOCAL_ROOT="${XDG_DATA_HOME:-$REAL_HOME/.local/share}/torrentflix"; fi
        DELUGE_ROOT="$LOCAL_ROOT/deluge"
        DEFAULT_DOWNLOAD_DIR="$REAL_HOME/Downloads/torrentflix-downloads"
        WEB_BIND_IP=127.0.0.1
    else
        SERVER_ROOT=/opt/torrentflix; DELUGE_ROOT="$SERVER_ROOT/deluge"; PLEX_ROOT="$SERVER_ROOT/plex"
        DEFAULT_DOWNLOAD_DIR="$DELUGE_ROOT/downloads"; DEFAULT_MEDIA_DIR="$PLEX_ROOT/media"; WEB_BIND_IP=0.0.0.0
    fi
    DELUGE_ENV="$DELUGE_ROOT/.env"; DELUGE_CONFIG_DIR="$DELUGE_ROOT/config"; SECRETS_DIR="$DELUGE_ROOT/secrets"; PASSWORD_FILE="$SECRETS_DIR/webui.password"
    COMPOSE_FILE="$DELUGE_ROOT/compose.yml"; VPS_COMPOSE_FILE="$DELUGE_ROOT/compose.vps.yml"; THEME_DIR="$DELUGE_ROOT/theme"; NGINX_DIR="$DELUGE_ROOT/nginx"; NGINX_RUNTIME_CONF="$NGINX_DIR/conf.d.runtime"
    if [ "$MODE" != local ]; then PLEX_ENV="$PLEX_ROOT/.env"; PLEX_CONFIG_DIR="$PLEX_ROOT/config"; PLEX_TRANSCODE_DIR="$PLEX_ROOT/transcode"; fi
}

prepare_mode_context() {
    if [ "$MODE" = local ]; then
        prepare_identity
        configure_paths
    else
        configure_paths
        prepare_identity
    fi
}

prepare_identity() {
    local saved_media saved_deluge saved_plex candidate
    if [ "$MODE" = local ]; then
        if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ] && [ "${SUDO_UID}" != 0 ]; then
            REAL_UID="$SUDO_UID"; REAL_GID="$SUDO_GID"
            if [ "$HOST_OS" = Linux ]; then REAL_HOME="$(getent passwd "$REAL_UID" | awk -F: 'NR==1 {print $6}')"; else REAL_HOME="$(dscl . -search /Users UniqueID "$REAL_UID" 2>/dev/null | awk '{print $1; exit}' | xargs -I{} dscl . -read /Users/{} NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; fi
        else
            REAL_UID="$(id -u)"; REAL_GID="$(id -g)"; REAL_HOME="${HOME:-}"
        fi
        [ -n "$REAL_HOME" ] && [ "$REAL_UID" != 0 ] || die 'Could not determine the non-root local user'
        DELUGE_UID="$REAL_UID"; DELUGE_GID="$REAL_GID"; PLEX_UID="$REAL_UID"; PLEX_GID="$REAL_GID"; MEDIA_GID="$REAL_GID"
        return
    fi
    [ "$(id -u)" -eq 0 ] || die 'Server installation must be run as root. Run: sudo ./run.sh'
    command -v getent >/dev/null 2>&1 || die 'getent is required for server identity checks'
    saved_media="$(env_value "$DELUGE_ENV" MEDIA_GID)"; saved_deluge="$(env_value "$DELUGE_ENV" DELUGE_UID)"; saved_plex="$(env_value "$PLEX_ENV" PLEX_UID)"
    MEDIA_GID="${TORRENTFLIX_MEDIA_GID:-${saved_media:-$DEFAULT_MEDIA_GID}}"; DELUGE_UID="${TORRENTFLIX_DELUGE_UID:-${saved_deluge:-$DEFAULT_DELUGE_UID}}"; PLEX_UID="${TORRENTFLIX_PLEX_UID:-${saved_plex:-$DEFAULT_PLEX_UID}}"
    [[ "$MEDIA_GID" =~ ^[1-9][0-9]*$ && "$DELUGE_UID" =~ ^[1-9][0-9]*$ && "$PLEX_UID" =~ ^[1-9][0-9]*$ ]] || die 'Server service IDs must be positive integers'
    if [ -n "${TORRENTFLIX_MEDIA_GID:-$saved_media}" ]; then id_in_use "$MEDIA_GID" && die "Saved media group ID $MEDIA_GID is now used by a host account"; elif id_in_use "$MEDIA_GID"; then candidate="$MEDIA_GID"; MEDIA_GID=''; MEDIA_GID="$(next_free_id "$candidate")"; fi
    if [ -n "${TORRENTFLIX_DELUGE_UID:-$saved_deluge}" ]; then id_in_use "$DELUGE_UID" && die "Saved Deluge UID $DELUGE_UID is now used by a host account"; elif id_in_use "$DELUGE_UID" || [ "$DELUGE_UID" = "$MEDIA_GID" ]; then candidate="$DELUGE_UID"; DELUGE_UID=''; DELUGE_UID="$(next_free_id "$candidate")"; fi
    while [ "$DELUGE_UID" = "$MEDIA_GID" ]; do DELUGE_UID="$(next_free_id "$((DELUGE_UID + 1))")"; done
    if [ -n "${TORRENTFLIX_PLEX_UID:-$saved_plex}" ]; then id_in_use "$PLEX_UID" && die "Saved Plex UID $PLEX_UID is now used by a host account"; elif id_in_use "$PLEX_UID" || [ "$PLEX_UID" = "$MEDIA_GID" ] || [ "$PLEX_UID" = "$DELUGE_UID" ]; then candidate="$PLEX_UID"; PLEX_UID=''; PLEX_UID="$(next_free_id "$candidate")"; fi
    while [ "$PLEX_UID" = "$MEDIA_GID" ] || [ "$PLEX_UID" = "$DELUGE_UID" ]; do PLEX_UID="$(next_free_id "$((PLEX_UID + 1))")"; done
    [ "$MEDIA_GID" != "$DELUGE_UID" ] && [ "$MEDIA_GID" != "$PLEX_UID" ] && [ "$DELUGE_UID" != "$PLEX_UID" ] || die 'Server service IDs must be distinct'
    DELUGE_GID="$MEDIA_GID"; PLEX_GID="$MEDIA_GID"
}

prepare_deluge_dirs() {
    local root_owner=root root_group=root
    if [ "$MODE" = local ]; then root_owner="$DELUGE_UID"; root_group="$DELUGE_GID"; fi
    managed_dir "$DELUGE_ROOT" "$root_owner" "$root_group" 0755 runtime; managed_dir "$DELUGE_CONFIG_DIR" "$DELUGE_UID" "$DELUGE_GID" 0700 config; managed_dir "$SECRETS_DIR" "$DELUGE_UID" "$DELUGE_GID" 0700 secrets
    if [ "$DOWNLOAD_MANAGED" = true ]; then managed_dir "$DOWNLOAD_DIR" "$DELUGE_UID" "$MEDIA_GID" 2775 downloads; else [ -d "$DOWNLOAD_DIR" ] && [ -w "$DOWNLOAD_DIR" ] || die "External download directory is not writable: $DOWNLOAD_DIR"; fi
    chown -R "$DELUGE_UID:$DELUGE_GID" "$DELUGE_CONFIG_DIR" "$SECRETS_DIR"
}

prepare_plex_dirs() {
    managed_dir "$PLEX_ROOT" root root 0755 runtime; managed_dir "$PLEX_CONFIG_DIR" "$PLEX_UID" "$PLEX_GID" 0700 config; managed_dir "$PLEX_TRANSCODE_DIR" "$PLEX_UID" "$PLEX_GID" 0700 transcode
    if [ "$MEDIA_MANAGED" = true ]; then managed_dir "$MEDIA_DIR" "$PLEX_UID" "$MEDIA_GID" 2775 media; else [ -d "$MEDIA_DIR" ] && [ -r "$MEDIA_DIR" ] || die "External media directory is not readable: $MEDIA_DIR"; fi
    chown -R "$PLEX_UID:$PLEX_GID" "$PLEX_CONFIG_DIR" "$PLEX_TRANSCODE_DIR"
}

select_download_dir() {
    local saved; saved="$(env_value "$DELUGE_ENV" DOWNLOAD_DIR)"; DEFAULT_DOWNLOAD_DIR="${saved:-$DEFAULT_DOWNLOAD_DIR}"
    read -r -p "Download directory [$DEFAULT_DOWNLOAD_DIR]: " DOWNLOAD_INPUT; DOWNLOAD_DIR="${DOWNLOAD_INPUT:-$DEFAULT_DOWNLOAD_DIR}"
    case "$DOWNLOAD_DIR" in /*) ;; *) die 'Download directory must be absolute' ;; esac
    [ "$DOWNLOAD_DIR" != / ] || die 'The filesystem root cannot be used as downloads'
    if [ "$DOWNLOAD_DIR" = "$DELUGE_ROOT/downloads" ]; then DOWNLOAD_MANAGED=true; else DOWNLOAD_MANAGED=false; [ -d "$DOWNLOAD_DIR" ] && [ -w "$DOWNLOAD_DIR" ] || die 'External download directory must exist and be writable'; fi
}

select_media_dir() {
    local saved_media saved_managed mount choice index
    saved_media="$(env_value "$PLEX_ENV" MEDIA_DIR)"; saved_managed="$(env_value "$PLEX_ENV" MEDIA_MANAGED)"
    if [ -n "$saved_media" ] && [ "$saved_managed" = false ] && [ -d "$saved_media" ]; then MEDIA_DIR="$saved_media"; MEDIA_MANAGED=false; return; fi
    if [ -n "$saved_media" ] && [ "$saved_managed" = true ]; then MEDIA_DIR="$saved_media"; MEDIA_MANAGED=true; return; fi
    MOUNTS=(); if command -v findmnt >/dev/null 2>&1; then while IFS= read -r mount; do [ -d "$mount" ] && MOUNTS+=("$mount"); done < <(findmnt -rn -o TARGET | awk '$0 ~ /^\/mnt\// || $0 ~ /^\/media\// || $0 ~ /^\/run\/media\//'); fi
    echo; echo 'Plex media location:'; index=1
    for mount in "${MOUNTS[@]}"; do printf '%s%s.%s %s%s%s\n' "$LINE" "$index" "$RESET" "$TEXT" "$mount" "$RESET"; index=$((index + 1)); done
    printf '%sC.%s Enter another path\n' "$LINE" "$RESET"; printf '%sF.%s Use Torrentflix default (%s)\n' "$LINE" "$RESET" "$DEFAULT_MEDIA_DIR"
    read -r -p '?: ' choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MOUNTS[@]}" ]; then MEDIA_DIR="${MOUNTS[$((choice - 1))]}"; MEDIA_MANAGED=false
    elif [ "$choice" = c ] || [ "$choice" = C ]; then read -r -p 'Media directory: ' MEDIA_DIR; case "$MEDIA_DIR" in /*) ;; *) die 'Media directory must be absolute' ;; esac; [ "$MEDIA_DIR" != / ] || die 'The filesystem root cannot be used as media'; [ -d "$MEDIA_DIR" ] && [ -r "$MEDIA_DIR" ] || die 'Media directory must exist and be readable'; MEDIA_MANAGED=false
    else MEDIA_DIR="$DEFAULT_MEDIA_DIR"; MEDIA_MANAGED=true; fi
}

write_deluge_env() {
    write_env "$DELUGE_ENV" MODE "$MODE" MEDIA_GID "$MEDIA_GID" DELUGE_UID "$DELUGE_UID" DELUGE_GID "$DELUGE_GID" DELUGE_CONFIG_DIR "$DELUGE_CONFIG_DIR" DOWNLOAD_DIR "$DOWNLOAD_DIR" DOWNLOAD_MANAGED "$DOWNLOAD_MANAGED" DELUGE_IMAGE "$DELUGE_IMAGE" WEB_DIR "$WEB_DIR" WEB_PORT 8112 WEB_BIND_IP "$WEB_BIND_IP" PRIMARY_DOMAIN "${DOMAIN:-}" HSTS_POLICY "$HSTS_POLICY" TZ UTC
}
write_plex_env() {
    write_env "$PLEX_ENV" MODE "$MODE" MEDIA_GID "$MEDIA_GID" PLEX_UID "$PLEX_UID" PLEX_GID "$PLEX_GID" PLEX_CONFIG_DIR "$PLEX_CONFIG_DIR" PLEX_TRANSCODE_DIR "$PLEX_TRANSCODE_DIR" MEDIA_DIR "$MEDIA_DIR" MEDIA_MANAGED "$MEDIA_MANAGED" TZ UTC PLEX_CLAIM "${PLEX_CLAIM:-}" PLEX_IMAGE 'plexinc/pms-docker:1.43.3.10861-07dfddaeb@sha256:5bc1d13f48da6366f46aaf2a3ce1a6292897eadc1f8efcbbd7321d30e94f2ed4' PLEX_MEM_LIMIT 4g PLEX_MEM_RESERVATION 512m PLEX_CPUS 2.0 PLEX_PIDS_LIMIT 512
}

install_deluge_files() {
    cp "$SCRIPT_DIR/deluge/Dockerfile" "$DELUGE_ROOT/Dockerfile"; cp "$SCRIPT_DIR/deluge/compose.yml" "$DELUGE_ROOT/compose.yml"; cp "$SCRIPT_DIR/deluge/.dockerignore" "$DELUGE_ROOT/.dockerignore"; rm -f "$VPS_COMPOSE_FILE"; rm -rf "$THEME_DIR" "$NGINX_DIR"; mkdir -p "$THEME_DIR"
    if [ "$MODE" = vps ]; then cp "$SCRIPT_DIR/deluge/compose.vps.yml" "$VPS_COMPOSE_FILE"; mkdir -p "$NGINX_RUNTIME_CONF" "$NGINX_DIR/www"; cp "$SCRIPT_DIR/deluge/nginx/Dockerfile" "$NGINX_DIR/Dockerfile"; sed "s|__HSTS_POLICY__|$HSTS_POLICY|g" "$SCRIPT_DIR/deluge/nginx/nginx.conf" > "$NGINX_DIR/nginx.conf"; cp "$SCRIPT_DIR/deluge/nginx/conf.d/00-acme.conf" "$NGINX_RUNTIME_CONF/00-acme.conf"; sed "s/domain\.com/$DOMAIN/g" "$SCRIPT_DIR/deluge/nginx/conf.d/domain.com.conf" > "$NGINX_RUNTIME_CONF/$DOMAIN.conf"; fi
}

download_theme() {
    local archive theme_url="https://raw.githubusercontent.com/joelacus/deluge-web-dark-theme/$THEME_COMMIT/deluge_web_dark_theme.tar.gz"; archive="$(mktemp)"
    curl -fsSL "$theme_url" -o "$archive"; [ "$(sha256_file "$archive")" = "$THEME_SHA256" ] || { rm -f "$archive"; die 'Theme checksum verification failed'; }; tar -xzf "$archive" -C "$THEME_DIR"; rm -f "$archive"
    [ -d "$THEME_DIR/icons" ] && [ -d "$THEME_DIR/images" ] && [ -f "$THEME_DIR/themes/css/xtheme-dark.css" ] || die 'Theme assets are incomplete'
}

compose_args_deluge() { COMPOSE_ARGS=(--env-file "$DELUGE_ENV" -f "$([ "$MODE" = vps ] && printf '%s' "$VPS_COMPOSE_FILE" || printf '%s' "$COMPOSE_FILE")"); }
run_deluge_rpc() {
    if [ "$MODE" = vps ]; then printf '%s' "$1" | docker compose "${COMPOSE_ARGS[@]}" exec -T nginx sh -c 'curl -fsS -c /tmp/torrentflix-rpc.cookies -b /tmp/torrentflix-rpc.cookies -H "Content-Type: application/json" --data-binary @- http://deluge:8112/json'; else printf '%s' "$1" | curl -fsS -c "$COOKIE" -b "$COOKIE" -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8112/json; fi
}

run_deluge() {
    command -v docker >/dev/null || die 'Docker is required'; command -v curl >/dev/null || die 'curl is required'; command -v tar >/dev/null || die 'tar is required'; command -v openssl >/dev/null || die 'openssl is required'; command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die 'sha256sum or shasum is required'
    prepare_mode_context; assert_no_source_overlap "$DELUGE_ROOT" "$DEFAULT_DOWNLOAD_DIR"; DOMAIN=''; HSTS_POLICY='max-age=63072000'
    if [ "$MODE" = vps ]; then read -r -p 'Hostname for Deluge HTTPS [deluge.example.com]: ' DOMAIN; DOMAIN="${DOMAIN:-deluge.example.com}"; [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die 'Invalid hostname'; read -r -p 'Enable HSTS subdomains/preload? [y/N]: ' HSTS_INPUT; case "$HSTS_INPUT" in y|Y|yes|YES) HSTS_POLICY='max-age=63072000; includeSubDomains; preload' ;; esac; fi
    select_download_dir; assert_no_source_overlap "$DELUGE_ROOT" "$DOWNLOAD_DIR"; prepare_deluge_dirs; install_deluge_files; write_deluge_env; [ -s "$PASSWORD_FILE" ] || { umask 077; openssl rand -hex 16 > "$PASSWORD_FILE"; }; chmod 600 "$PASSWORD_FILE"; echo '[+] Downloading theme...'; download_theme; compose_args_deluge
    echo '[+] Building Deluge image...'; docker compose "${COMPOSE_ARGS[@]}" build --pull; echo '[+] Starting Deluge...'; docker compose "${COMPOSE_ARGS[@]}" up -d; echo '[+] Waiting for Deluge WebUI...'; READY=0
    for _ in $(seq 1 60); do if [ "$MODE" = vps ]; then docker compose "${COMPOSE_ARGS[@]}" exec -T nginx sh -c 'curl -fsS http://deluge:8112/ >/dev/null' >/dev/null 2>&1 && READY=1; else curl -fsS http://127.0.0.1:8112/ >/dev/null 2>&1 && READY=1; fi; [ "$READY" = 1 ] && break; sleep 1; done
    [ "$READY" = 1 ] || { docker compose "${COMPOSE_ARGS[@]}" logs --tail=100 deluge; die 'WebUI failed'; }
    COOKIE="$(mktemp)"; trap 'rm -f "$COOKIE"' EXIT; WEB_PASSWORD="$(cat "$PASSWORD_FILE")"; LOGIN="$(run_deluge_rpc "{\"method\":\"auth.login\",\"params\":[\"$WEB_PASSWORD\"],\"id\":1}")"
    if echo "$LOGIN" | grep -q '"result": true'; then echo '[+] Existing WebUI password accepted'; else LOGIN="$(run_deluge_rpc '{"method":"auth.login","params":["deluge"],"id":1}')"; echo "$LOGIN" | grep -q '"result": true' || die "WebUI login failed: $LOGIN"; PASSWORD_RESULT="$(run_deluge_rpc "{\"method\":\"auth.change_password\",\"params\":[\"deluge\",\"$WEB_PASSWORD\"],\"id\":2}")"; echo "$PASSWORD_RESULT" | grep -q '"result": true' || die "Password change failed: $PASSWORD_RESULT"; fi
    THEME_RESULT="$(run_deluge_rpc '{"method":"web.set_theme","params":["dark"],"id":3}')"; echo "$THEME_RESULT" | grep -Eq '"result": true|"error": null' || die "Theme API failed: $THEME_RESULT"
    clear_terminal; echo "Runtime root:   $DELUGE_ROOT"; [ "$MODE" = vps ] && echo "WebUI URL:     https://$DOMAIN/deluge/"; [ "$MODE" = home_server ] && echo 'WebUI URL:     http://SERVER_IP:8112'; [ "$MODE" = local ] && echo 'WebUI URL:     http://localhost:8112'; echo "Password file: $PASSWORD_FILE"; echo "WebUI password: $WEB_PASSWORD"; echo "Downloads:     $DOWNLOAD_DIR"; echo 'Peer traffic:  Docker internal only'
}

run_plex() {
    [ "$MODE" != local ] || die 'Plex is available only in server modes'; command -v docker >/dev/null || die 'Docker is required'; prepare_mode_context; assert_no_source_overlap "$PLEX_ROOT" "$DEFAULT_MEDIA_DIR"; PLEX_CLAIM=''; clear_terminal; printf '%sTorrentflix Plex%s\n\n' "$LINE" "$RESET"; printf '%sPlex claim token (optional): %s' "$LINE" "$RESET"; read -r -s PLEX_CLAIM; echo; select_media_dir; assert_no_source_overlap "$PLEX_ROOT" "$MEDIA_DIR"; prepare_plex_dirs; cp "$SCRIPT_DIR/plex/compose.yml" "$PLEX_ROOT/compose.yml"; write_plex_env; echo '[+] Starting Plex Media Server...'; docker compose --env-file "$PLEX_ENV" -f "$PLEX_ROOT/compose.yml" up -d
    if [ -n "$PLEX_CLAIM" ]; then sed -i.bak '/^PLEX_CLAIM=/d' "$PLEX_ENV"; rm -f "$PLEX_ENV.bak"; printf 'PLEX_CLAIM=\n' >> "$PLEX_ENV"; chmod 600 "$PLEX_ENV"; fi
    echo; echo 'Plex is running.'; echo 'WebUI:  http://SERVER_IP:32400/web'; echo "Media:  $MEDIA_DIR"; echo "Config: $PLEX_CONFIG_DIR"; echo; echo 'Headless setup without a claim token:'; echo '  ssh -N -L 32400:127.0.0.1:32400 user@SERVER_IP'; echo '  Then open http://localhost:32400/web'
}

safe_delete_root() {
    local root="$1" type="$2"; [ -n "$root" ] && [ "$root" != / ] && [ ! -L "$root" ] || die 'Unsafe delete target'; [ "$root" != "$SCRIPT_DIR" ] || die 'Refusing to delete the git checkout'
    case "$type" in
        service) [ "$root" = /opt/torrentflix/deluge ] || [ "$root" = /opt/torrentflix/plex ] || die 'Path is not an approved service root' ;;
        local) path_contains "$REAL_HOME" "$root" || die 'Path is outside the local runtime root' ;;
        downloads) [ "$root" = "$REAL_HOME/Downloads/torrentflix-downloads" ] || die 'Path is not the managed downloads path' ;;
        *) die 'Unknown delete type' ;;
    esac
    if [ "$type" = downloads ]; then
        marker_matches "$root" downloads || die 'Managed downloads marker is missing or invalid'
    else
        marker_matches "$root" runtime || die 'Managed runtime marker is missing or invalid'
    fi
}

run_uninstall() {
    prepare_mode_context; local target choice confirm
    if [ "$MODE" = local ]; then target="$DELUGE_ROOT"; else read -r -p 'Remove Deluge or Plex? [deluge/plex]: ' target; case "$target" in deluge) target="$DELUGE_ROOT" ;; plex) target="$PLEX_ROOT" ;; *) die 'Choose deluge or plex' ;; esac; fi
    [ -d "$target" ] || { echo "Nothing installed at $target"; return; }
    if [ "$target" = "$DELUGE_ROOT" ]; then
        if [ -f "$COMPOSE_FILE" ] || [ -f "$VPS_COMPOSE_FILE" ]; then compose_args_deluge; docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans 2>/dev/null || true; fi
        DOWNLOAD_DIR="$(env_value "$DELUGE_ENV" DOWNLOAD_DIR)"; DOWNLOAD_MANAGED="$(env_value "$DELUGE_ENV" DOWNLOAD_MANAGED)"; read -r -p '1) Remove configuration only  2) Also remove downloaded torrents [1]: ' choice; choice="${choice:-1}"
        if [ "$choice" = 2 ] && [ "$DOWNLOAD_MANAGED" = true ]; then read -r -p 'Type DELETE DOWNLOADS to permanently remove downloads: ' confirm; [ "$confirm" = 'DELETE DOWNLOADS' ] || die 'Downloads were not removed'; safe_delete_root "$DOWNLOAD_DIR" downloads; rm -rf -- "$DOWNLOAD_DIR"; fi
        if [ "$MODE" = local ]; then safe_delete_root "$target" local; else safe_delete_root "$target" service; fi
        if [ "$DOWNLOAD_MANAGED" = true ] && [ "$DOWNLOAD_DIR" = "$DELUGE_ROOT/downloads" ] && [ -d "$DOWNLOAD_DIR" ]; then
            find "$target" -mindepth 1 -maxdepth 1 ! -name downloads ! -name .torrentflix-managed -exec rm -rf -- {} +
        else
            rm -rf -- "$target"
        fi
        echo '[+] Deluge configuration removed; downloads preserved unless explicitly deleted'
    else
        docker compose --env-file "$PLEX_ENV" -f "$PLEX_ROOT/compose.yml" down --remove-orphans 2>/dev/null || true; MEDIA_DIR="$(env_value "$PLEX_ENV" MEDIA_DIR)"; MEDIA_MANAGED="$(env_value "$PLEX_ENV" MEDIA_MANAGED)"; safe_delete_root "$target" service
        if [ "$MEDIA_MANAGED" = true ] && [ "$MEDIA_DIR" = "$PLEX_ROOT/media" ] && [ -d "$MEDIA_DIR" ]; then
            find "$target" -mindepth 1 -maxdepth 1 ! -name media ! -name .torrentflix-managed -exec rm -rf -- {} +
            echo '[+] Plex configuration removed; managed media preserved'
        else
            rm -rf -- "$target"; echo '[+] Plex configuration removed; external media was not touched'
        fi
        [ "$MEDIA_MANAGED" = true ] && echo "Managed Plex media preserved at: $MEDIA_DIR"
    fi
}

select_installation_mode() {
    clear_terminal; printf '%sTorrentflix%s\n\n' "$LINE" "$RESET"; echo 'Select installation mode.'; echo; printf '%s1.%s VPS (Public Server)\n' "$LINE" "$RESET"; printf '%b%s%b\n' "$MUTED" '   Linux server, public HTTPS, bundled Nginx and Let’s Encrypt.' "$RESET"; printf '%s2.%s Home Server (LAN Only)\n' "$LINE" "$RESET"; printf '%b%s%b\n' "$MUTED" '   Always-on Linux server or NAS. No domain or public Nginx.' "$RESET"; printf '%s3.%s Local (macOS/Linux)\n' "$LINE" "$RESET"; printf '%b%s%b\n' "$MUTED" '   Personal computer. Deluge only; no Plex in Local mode.' "$RESET"; echo; read -r -p '?: ' MODE_CHOICE; MODE_CHOICE="${MODE_CHOICE:-$([ "$HOST_OS" = Darwin ] && echo 3 || echo 1)}"; case "$MODE_CHOICE" in 1) MODE=vps ;; 2) MODE=home_server ;; 3) MODE=local ;; *) die 'Choose 1, 2 or 3' ;; esac
    if [ "$MODE" != local ]; then [ "$HOST_OS" = Linux ] || die 'Server modes require Linux'; [ "$(id -u)" -eq 0 ] || die 'Run server mode as root: sudo ./run.sh'; else [ "$HOST_OS" = Linux ] || [ "$HOST_OS" = Darwin ] || die 'Local mode supports Linux and macOS'; fi
}

select_installation_mode; clear_terminal; printf '%sTorrentflix%s\n\n' "$LINE" "$RESET"; echo 'What would you like to do?'; echo; printf '%s1.%s Install Deluge\n' "$LINE" "$RESET"
if [ "$MODE" != local ]; then printf '%s2.%s Install Plex\n' "$LINE" "$RESET"; printf '%s3.%s Uninstall a service\n' "$LINE" "$RESET"; else printf '%s2.%s Uninstall Deluge\n' "$LINE" "$RESET"; fi
echo; read -r -p '?: ' SERVICE; SERVICE="${SERVICE:-1}"
if [ "$MODE" = local ]; then case "$SERVICE" in 1) run_deluge ;; 2) run_uninstall ;; *) die 'Choose 1 or 2' ;; esac; else case "$SERVICE" in 1) run_deluge ;; 2) run_plex ;; 3) run_uninstall ;; *) die 'Choose 1, 2 or 3' ;; esac; fi
