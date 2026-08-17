#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
HOST_OS="$(uname -s 2>/dev/null || printf '%s' 'unknown')"

if [[ -t 1 ]]; then
    RESET=$'\033[0m'
    LINE=$'\033[38;5;117m'
    TEXT=$'\033[97m'
    MUTED=$'\033[3;38;5;245m'
else
    RESET=''
    LINE=''
    TEXT=''
    MUTED=''
fi

readonly DEFAULT_MEDIA_GID=10000
readonly DEFAULT_DELUGE_UID=10001
readonly DEFAULT_PLEX_UID=10002
readonly DELUGE_IMAGE='lscr.io/linuxserver/deluge:2.2.0@sha256:33a939576f7ecfc1227db1a0cb2afce030ce983e620ec9d93c956e3700e21fe9'
readonly WEB_DIR='/lsiopy/lib/python3.12/site-packages/deluge/ui/web'
readonly THEME_COMMIT='dbef18e3c9a2cb0f2448d16bb95dca868f94440e'
readonly THEME_SHA256='5c3e6a4453fb06c16bc89f3b3789f12ba56b01addc111477211cb63e93f291bb'

die() {
    printf '[!] %s\n' "$*" >&2
    exit 1
}

clear_terminal() {
    if [[ -t 1 ]]; then
        if command -v clear >/dev/null 2>&1; then
            clear
            return
        fi
    fi

    printf '\033c'
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "Required command is missing: $command_name"
    fi
}

read_env_value() {
    local env_file="$1"
    local key="$2"

    if [[ ! -f "$env_file" ]]; then
        return 0
    fi

    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$env_file"
}

write_env_file() {
    local env_file="$1"

    shift
    umask 077
    : > "$env_file"

    while [[ $# -gt 1 ]]; do
        printf '%s=%s\n' "$1" "$2" >> "$env_file"
        shift 2
    done

    chmod 600 "$env_file"
}

sha256_file() {
    local file_path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print $1}'
    else
        shasum -a 256 "$file_path" | awk '{print $1}'
    fi
}

canonical_path() {
    local path="$1"
    local unresolved_path
    local unresolved_suffix=''
    local resolved_path

    if command -v realpath >/dev/null 2>&1; then
        if realpath -m -- "$path" 2>/dev/null; then
            return
        fi
    fi

    if [[ "$path" != /* ]]; then
        path="$(pwd -P)/$path"
    fi

    unresolved_path="$path"
    while [[ ! -e "$unresolved_path" && "$unresolved_path" != '/' ]]; do
        unresolved_suffix="/$(basename -- "$unresolved_path")$unresolved_suffix"
        unresolved_path="$(dirname -- "$unresolved_path")"
    done

    if [[ ! -d "$unresolved_path" ]]; then
        unresolved_suffix="/$(basename -- "$unresolved_path")$unresolved_suffix"
        unresolved_path="$(dirname -- "$unresolved_path")"
    fi

    resolved_path="$(CDPATH= cd -P -- "$unresolved_path" && pwd -P)"
    printf '%s%s\n' "$resolved_path" "$unresolved_suffix"
}

path_contains() {
    local parent_path="$1"
    local child_path="$2"
    local canonical_parent
    local canonical_child

    canonical_parent="$(canonical_path "$parent_path")"
    canonical_child="$(canonical_path "$child_path")"

    if [[ "$canonical_parent" == "$canonical_child" ]]; then
        return 0
    fi

    [[ "$canonical_child" == "$canonical_parent"/* ]]
}

assert_no_source_overlap() {
    local runtime_root="$1"
    local data_path="$2"

    if path_contains "$SCRIPT_DIR" "$runtime_root"; then
        die 'The Git checkout cannot contain the runtime directory'
    fi

    if path_contains "$runtime_root" "$SCRIPT_DIR"; then
        die 'The runtime directory cannot contain the Git checkout'
    fi

    if path_contains "$SCRIPT_DIR" "$data_path"; then
        die 'The Git checkout cannot contain downloads or media'
    fi

    if path_contains "$data_path" "$SCRIPT_DIR"; then
        die 'Downloads or media cannot contain the Git checkout'
    fi
}

write_managed_marker() {
    local root_path="$1"
    local managed_type="$2"

    printf 'managed-by=torrentflix\ntype=%s\n' "$managed_type" > "$root_path/.torrentflix-managed"
    chmod 600 "$root_path/.torrentflix-managed"
}

has_managed_marker() {
    local root_path="$1"
    local expected_type="$2"

    if [[ ! -f "$root_path/.torrentflix-managed" ]]; then
        return 1
    fi

    if ! grep -qx 'managed-by=torrentflix' "$root_path/.torrentflix-managed"; then
        return 1
    fi

    grep -qx "type=$expected_type" "$root_path/.torrentflix-managed"
}

prepare_managed_directory() {
    local directory_path="$1"
    local owner_uid="$2"
    local owner_gid="$3"
    local directory_mode="$4"
    local managed_type="$5"
    local first_child

    if [[ -z "$directory_path" || "$directory_path" == '/' ]]; then
        die 'Refusing an empty path or filesystem root'
    fi

    if [[ -L "$directory_path" ]]; then
        die "Refusing a symbolic-link managed path: $directory_path"
    fi

    if [[ -e "$directory_path" ]]; then
        if [[ ! -d "$directory_path" ]]; then
            die "Managed path is not a directory: $directory_path"
        fi

        if [[ -f "$directory_path/.torrentflix-managed" ]]; then
            if ! has_managed_marker "$directory_path" "$managed_type"; then
                die "Managed marker does not match: $directory_path"
            fi
        else
            first_child="$(find "$directory_path" ! -path "$directory_path" -prune -print -quit 2>/dev/null)"
            if [[ -n "$first_child" ]]; then
                die "Refusing to manage a non-empty unmarked directory: $directory_path"
            fi

            write_managed_marker "$directory_path" "$managed_type"
        fi
    else
        install -d -o "$owner_uid" -g "$owner_gid" -m "$directory_mode" "$directory_path"
        write_managed_marker "$directory_path" "$managed_type"
    fi

    chown "$owner_uid:$owner_gid" "$directory_path" "$directory_path/.torrentflix-managed"
    chmod "$directory_mode" "$directory_path"
}

id_in_use() {
    local numeric_id="$1"

    if getent passwd "$numeric_id" >/dev/null 2>&1; then
        return 0
    fi

    getent group "$numeric_id" >/dev/null 2>&1
}

next_free_id() {
    local candidate_id="$1"

    while true; do
        if id_in_use "$candidate_id"; then
            candidate_id=$((candidate_id + 1))
            continue
        fi

        if [[ "${MEDIA_GID:-}" == "$candidate_id" || "${DELUGE_UID:-}" == "$candidate_id" || "${PLEX_UID:-}" == "$candidate_id" ]]; then
            candidate_id=$((candidate_id + 1))
            continue
        fi

        printf '%s\n' "$candidate_id"
        return 0
    done
}

configure_paths() {
    if [[ "$MODE" == local ]]; then
        if [[ "$HOST_OS" == Darwin ]]; then
            LOCAL_ROOT="$REAL_HOME/Library/Application Support/Torrentflix"
        else
            LOCAL_ROOT="${XDG_DATA_HOME:-$REAL_HOME/.local/share}/torrentflix"
        fi

        DELUGE_ROOT="$LOCAL_ROOT/deluge"
        DEFAULT_DOWNLOAD_DIR="$REAL_HOME/Downloads/torrentflix-downloads"
        WEB_BIND_IP='127.0.0.1'
    else
        SERVER_ROOT='/opt/torrentflix'
        DELUGE_ROOT="$SERVER_ROOT/deluge"
        PLEX_ROOT="$SERVER_ROOT/plex"
        DEFAULT_DOWNLOAD_DIR="$DELUGE_ROOT/downloads"
        DEFAULT_MEDIA_DIR="$PLEX_ROOT/media"
        WEB_BIND_IP='0.0.0.0'
    fi

    DELUGE_ENV="$DELUGE_ROOT/.env"
    DELUGE_CONFIG_DIR="$DELUGE_ROOT/config"
    SECRETS_DIR="$DELUGE_ROOT/secrets"
    PASSWORD_FILE="$SECRETS_DIR/webui.password"
    DELUGE_COMPOSE_FILE="$DELUGE_ROOT/compose.yml"
    VPS_COMPOSE_FILE="$DELUGE_ROOT/compose.vps.yml"
    THEME_DIR="$DELUGE_ROOT/theme"
    NGINX_DIR="$DELUGE_ROOT/nginx"
    NGINX_RUNTIME_CONF="$NGINX_DIR/conf.d.runtime"

    if [[ "$MODE" != local ]]; then
        PLEX_ENV="$PLEX_ROOT/.env"
        PLEX_CONFIG_DIR="$PLEX_ROOT/config"
        PLEX_TRANSCODE_DIR="$PLEX_ROOT/transcode"
    fi
}

resolve_local_identity() {
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" && "$SUDO_UID" != 0 ]]; then
        REAL_UID="$SUDO_UID"
        REAL_GID="$SUDO_GID"

        if [[ "$HOST_OS" == Linux ]]; then
            REAL_HOME="$(getent passwd "$REAL_UID" | awk -F: 'NR == 1 { print $6 }')"
        else
            REAL_HOME="$(dscl . -search /Users UniqueID "$REAL_UID" 2>/dev/null | awk '{ print $1; exit }' | xargs -I{} dscl . -read /Users/{} NFSHomeDirectory 2>/dev/null | awk '{ print $2 }')"
        fi
    else
        REAL_UID="$(id -u)"
        REAL_GID="$(id -g)"
        REAL_HOME="${HOME:-}"
    fi

    if [[ -z "$REAL_HOME" || "$REAL_UID" == 0 ]]; then
        die 'Could not determine a non-root local user and home directory'
    fi

    DELUGE_UID="$REAL_UID"
    DELUGE_GID="$REAL_GID"
    PLEX_UID="$REAL_UID"
    PLEX_GID="$REAL_GID"
    MEDIA_GID="$REAL_GID"
}

resolve_server_identity() {
    local saved_media_gid
    local saved_deluge_uid
    local saved_plex_uid
    local candidate_id

    if [[ "$(id -u)" != 0 ]]; then
        die 'Server installation must be run as root. Run: sudo ./run.sh'
    fi

    require_command getent

    saved_media_gid="$(read_env_value "$DELUGE_ENV" MEDIA_GID)"
    saved_deluge_uid="$(read_env_value "$DELUGE_ENV" DELUGE_UID)"
    saved_plex_uid="$(read_env_value "$PLEX_ENV" PLEX_UID)"

    MEDIA_GID="${TORRENTFLIX_MEDIA_GID:-${saved_media_gid:-$DEFAULT_MEDIA_GID}}"
    DELUGE_UID="${TORRENTFLIX_DELUGE_UID:-${saved_deluge_uid:-$DEFAULT_DELUGE_UID}}"
    PLEX_UID="${TORRENTFLIX_PLEX_UID:-${saved_plex_uid:-$DEFAULT_PLEX_UID}}"

    if [[ ! "$MEDIA_GID" =~ ^[1-9][0-9]*$ || ! "$DELUGE_UID" =~ ^[1-9][0-9]*$ || ! "$PLEX_UID" =~ ^[1-9][0-9]*$ ]]; then
        die 'Server service IDs must be positive integers'
    fi

    if [[ -n "${TORRENTFLIX_MEDIA_GID:-$saved_media_gid}" ]]; then
        if id_in_use "$MEDIA_GID"; then
            die "Saved media group ID $MEDIA_GID is now used by a host account"
        fi
    elif id_in_use "$MEDIA_GID"; then
        candidate_id="$MEDIA_GID"
        MEDIA_GID=''
        MEDIA_GID="$(next_free_id "$candidate_id")"
    fi

    if [[ -n "${TORRENTFLIX_DELUGE_UID:-$saved_deluge_uid}" ]]; then
        if id_in_use "$DELUGE_UID"; then
            die "Saved Deluge UID $DELUGE_UID is now used by a host account"
        fi
    elif id_in_use "$DELUGE_UID"; then
        candidate_id="$DELUGE_UID"
        DELUGE_UID=''
        DELUGE_UID="$(next_free_id "$candidate_id")"
    elif [[ "$DELUGE_UID" == "$MEDIA_GID" ]]; then
        candidate_id="$DELUGE_UID"
        DELUGE_UID=''
        DELUGE_UID="$(next_free_id "$candidate_id")"
    fi

    while [[ "$DELUGE_UID" == "$MEDIA_GID" ]]; do
        candidate_id=$((DELUGE_UID + 1))
        DELUGE_UID=''
        DELUGE_UID="$(next_free_id "$candidate_id")"
    done

    if [[ -n "${TORRENTFLIX_PLEX_UID:-$saved_plex_uid}" ]]; then
        if id_in_use "$PLEX_UID"; then
            die "Saved Plex UID $PLEX_UID is now used by a host account"
        fi
    elif id_in_use "$PLEX_UID"; then
        candidate_id="$PLEX_UID"
        PLEX_UID=''
        PLEX_UID="$(next_free_id "$candidate_id")"
    elif [[ "$PLEX_UID" == "$MEDIA_GID" || "$PLEX_UID" == "$DELUGE_UID" ]]; then
        candidate_id="$PLEX_UID"
        PLEX_UID=''
        PLEX_UID="$(next_free_id "$candidate_id")"
    fi

    while [[ "$PLEX_UID" == "$MEDIA_GID" || "$PLEX_UID" == "$DELUGE_UID" ]]; do
        candidate_id=$((PLEX_UID + 1))
        PLEX_UID=''
        PLEX_UID="$(next_free_id "$candidate_id")"
    done

    if [[ "$MEDIA_GID" == "$DELUGE_UID" || "$MEDIA_GID" == "$PLEX_UID" || "$DELUGE_UID" == "$PLEX_UID" ]]; then
        die 'Server service IDs must be distinct'
    fi

    DELUGE_GID="$MEDIA_GID"
    PLEX_GID="$MEDIA_GID"
}

prepare_mode_context() {
    if [[ "$MODE" == local ]]; then
        resolve_local_identity
        configure_paths
    else
        configure_paths
        resolve_server_identity
    fi
}

prepare_deluge_directories() {
    local root_owner='root'
    local root_group='root'

    if [[ "$MODE" == local ]]; then
        root_owner="$DELUGE_UID"
        root_group="$DELUGE_GID"
    fi

    prepare_managed_directory "$DELUGE_ROOT" "$root_owner" "$root_group" 0755 runtime
    prepare_managed_directory "$DELUGE_CONFIG_DIR" "$DELUGE_UID" "$DELUGE_GID" 0700 config
    prepare_managed_directory "$SECRETS_DIR" "$DELUGE_UID" "$DELUGE_GID" 0700 secrets

    if [[ "$DOWNLOAD_MANAGED" == true ]]; then
        prepare_managed_directory "$DOWNLOAD_DIR" "$DELUGE_UID" "$MEDIA_GID" 2775 downloads
    else
        if [[ ! -d "$DOWNLOAD_DIR" || ! -w "$DOWNLOAD_DIR" ]]; then
            die "External download directory is not writable: $DOWNLOAD_DIR"
        fi
    fi

    chown -R "$DELUGE_UID:$DELUGE_GID" "$DELUGE_CONFIG_DIR" "$SECRETS_DIR"
}

prepare_plex_directories() {
    prepare_managed_directory "$PLEX_ROOT" root root 0755 runtime
    prepare_managed_directory "$PLEX_CONFIG_DIR" "$PLEX_UID" "$PLEX_GID" 0700 config
    prepare_managed_directory "$PLEX_TRANSCODE_DIR" "$PLEX_UID" "$PLEX_GID" 0700 transcode

    if [[ "$MEDIA_MANAGED" == true ]]; then
        prepare_managed_directory "$MEDIA_DIR" "$PLEX_UID" "$MEDIA_GID" 2775 media
    else
        if [[ ! -d "$MEDIA_DIR" || ! -r "$MEDIA_DIR" ]]; then
            die "External media directory is not readable: $MEDIA_DIR"
        fi
    fi

    chown -R "$PLEX_UID:$PLEX_GID" "$PLEX_CONFIG_DIR" "$PLEX_TRANSCODE_DIR"
}

select_download_directory() {
    local saved_download_dir

    saved_download_dir="$(read_env_value "$DELUGE_ENV" DOWNLOAD_DIR)"
    if [[ -n "$saved_download_dir" ]]; then
        DEFAULT_DOWNLOAD_DIR="$saved_download_dir"
    fi

    read -r -p "Download directory [$DEFAULT_DOWNLOAD_DIR]: " DOWNLOAD_INPUT
    DOWNLOAD_DIR="${DOWNLOAD_INPUT:-$DEFAULT_DOWNLOAD_DIR}"

    case "$DOWNLOAD_DIR" in
        /*)
            ;;
        *)
            die 'Download directory must be an absolute path'
            ;;
    esac

    if [[ "$DOWNLOAD_DIR" == '/' ]]; then
        die 'The filesystem root cannot be used as downloads'
    fi

    if [[ "$DOWNLOAD_DIR" == "$DELUGE_ROOT/downloads" || "$DOWNLOAD_DIR" == "$REAL_HOME/Downloads/torrentflix-downloads" ]]; then
        DOWNLOAD_MANAGED=true
    else
        DOWNLOAD_MANAGED=false

        if [[ ! -d "$DOWNLOAD_DIR" || ! -w "$DOWNLOAD_DIR" ]]; then
            die 'External download directory must exist and be writable'
        fi
    fi
}

select_media_directory() {
    local saved_media_dir
    local saved_media_managed
    local mount_path
    local choice
    local mount_index

    saved_media_dir="$(read_env_value "$PLEX_ENV" MEDIA_DIR)"
    saved_media_managed="$(read_env_value "$PLEX_ENV" MEDIA_MANAGED)"

    if [[ -n "$saved_media_dir" && "$saved_media_managed" == false && -d "$saved_media_dir" ]]; then
        MEDIA_DIR="$saved_media_dir"
        MEDIA_MANAGED=false
        return
    fi

    if [[ -n "$saved_media_dir" && "$saved_media_managed" == true ]]; then
        MEDIA_DIR="$saved_media_dir"
        MEDIA_MANAGED=true
        return
    fi

    MOUNTS=()
    if command -v findmnt >/dev/null 2>&1; then
        while IFS= read -r mount_path; do
            if [[ -d "$mount_path" ]]; then
                MOUNTS+=("$mount_path")
            fi
        done < <(findmnt -rn -o TARGET | awk '$0 ~ /^\/mnt\// || $0 ~ /^\/media\// || $0 ~ /^\/run\/media\//')
    fi

    printf '\nPlex media location:\n'
    mount_index=1
    for mount_path in "${MOUNTS[@]}"; do
        printf '%s%s.%s %s%s%s\n' "$LINE" "$mount_index" "$RESET" "$TEXT" "$mount_path" "$RESET"
        mount_index=$((mount_index + 1))
    done

    printf '%sC.%s Enter another path\n' "$LINE" "$RESET"
    printf '%sF.%s Use Torrentflix default (%s)\n' "$LINE" "$RESET" "$DEFAULT_MEDIA_DIR"
    read -r -p '?: ' choice

    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#MOUNTS[@]}" ]]; then
        MEDIA_DIR="${MOUNTS[$((choice - 1))]}"
        MEDIA_MANAGED=false
        return
    fi

    if [[ "$choice" == c || "$choice" == C ]]; then
        read -r -p 'Media directory: ' MEDIA_DIR

        case "$MEDIA_DIR" in
            /*)
                ;;
            *)
                die 'Media directory must be an absolute path'
                ;;
        esac

        if [[ "$MEDIA_DIR" == '/' || ! -d "$MEDIA_DIR" || ! -r "$MEDIA_DIR" ]]; then
            die 'Media directory must exist and be readable'
        fi

        MEDIA_MANAGED=false
        return
    fi

    MEDIA_DIR="$DEFAULT_MEDIA_DIR"
    MEDIA_MANAGED=true
}

write_deluge_environment() {
    write_env_file "$DELUGE_ENV" \
        MODE "$MODE" \
        MEDIA_GID "$MEDIA_GID" \
        DELUGE_UID "$DELUGE_UID" \
        DELUGE_GID "$DELUGE_GID" \
        DELUGE_CONFIG_DIR "$DELUGE_CONFIG_DIR" \
        DOWNLOAD_DIR "$DOWNLOAD_DIR" \
        DOWNLOAD_MANAGED "$DOWNLOAD_MANAGED" \
        DELUGE_IMAGE "$DELUGE_IMAGE" \
        WEB_DIR "$WEB_DIR" \
        WEB_PORT 8112 \
        WEB_BIND_IP "$WEB_BIND_IP" \
        PRIMARY_DOMAIN "${DOMAIN:-}" \
        HSTS_POLICY "$HSTS_POLICY" \
        TZ UTC
}

write_plex_environment() {
    write_env_file "$PLEX_ENV" \
        MODE "$MODE" \
        MEDIA_GID "$MEDIA_GID" \
        PLEX_UID "$PLEX_UID" \
        PLEX_GID "$PLEX_GID" \
        PLEX_CONFIG_DIR "$PLEX_CONFIG_DIR" \
        PLEX_TRANSCODE_DIR "$PLEX_TRANSCODE_DIR" \
        MEDIA_DIR "$MEDIA_DIR" \
        MEDIA_MANAGED "$MEDIA_MANAGED" \
        TZ UTC \
        PLEX_CLAIM "${PLEX_CLAIM:-}" \
        PLEX_IMAGE 'plexinc/pms-docker:1.43.3.10861-07dfddaeb@sha256:5bc1d13f48da6366f46aaf2a3ce1a6292897eadc1f8efcbbd7321d30e94f2ed4' \
        PLEX_MEM_LIMIT 4g \
        PLEX_MEM_RESERVATION 512m \
        PLEX_CPUS 2.0 \
        PLEX_PIDS_LIMIT 512
}

install_deluge_files() {
    cp "$SCRIPT_DIR/deluge/Dockerfile" "$DELUGE_ROOT/Dockerfile"
    cp "$SCRIPT_DIR/deluge/compose.yml" "$DELUGE_ROOT/compose.yml"
    cp "$SCRIPT_DIR/deluge/.dockerignore" "$DELUGE_ROOT/.dockerignore"
    rm -f -- "$VPS_COMPOSE_FILE"
    rm -rf -- "$THEME_DIR" "$NGINX_DIR"
    mkdir -p -- "$THEME_DIR"

    if [[ "$MODE" != vps ]]; then
        return
    fi

    cp "$SCRIPT_DIR/deluge/compose.vps.yml" "$VPS_COMPOSE_FILE"
    mkdir -p -- "$NGINX_RUNTIME_CONF" "$NGINX_DIR/www"
    cp "$SCRIPT_DIR/deluge/nginx/Dockerfile" "$NGINX_DIR/Dockerfile"
    sed "s|__HSTS_POLICY__|$HSTS_POLICY|g" "$SCRIPT_DIR/deluge/nginx/nginx.conf" > "$NGINX_DIR/nginx.conf"
    cp "$SCRIPT_DIR/deluge/nginx/conf.d/00-acme.conf" "$NGINX_RUNTIME_CONF/00-acme.conf"
    sed "s/domain\.com/$DOMAIN/g" "$SCRIPT_DIR/deluge/nginx/conf.d/domain.com.conf" > "$NGINX_RUNTIME_CONF/$DOMAIN.conf"
}

download_theme() {
    local theme_url
    local archive_file

    theme_url="https://raw.githubusercontent.com/joelacus/deluge-web-dark-theme/$THEME_COMMIT/deluge_web_dark_theme.tar.gz"
    archive_file="$(mktemp)"

    curl -fsSL "$theme_url" -o "$archive_file"

    if [[ "$(sha256_file "$archive_file")" != "$THEME_SHA256" ]]; then
        rm -f -- "$archive_file"
        die 'Theme checksum verification failed'
    fi

    tar -xzf "$archive_file" -C "$THEME_DIR"
    rm -f -- "$archive_file"

    if [[ ! -d "$THEME_DIR/icons" || ! -d "$THEME_DIR/images" || ! -f "$THEME_DIR/themes/css/xtheme-dark.css" ]]; then
        die 'Theme assets are incomplete'
    fi
}

build_deluge_compose_command() {
    local compose_file

    if [[ "$MODE" == vps ]]; then
        compose_file="$VPS_COMPOSE_FILE"
    else
        compose_file="$DELUGE_COMPOSE_FILE"
    fi

    COMPOSE_COMMAND=(
        docker
        compose
        --env-file "$DELUGE_ENV"
        -f "$compose_file"
    )
}

run_deluge_rpc() {
    local request="$1"

    if [[ "$MODE" == vps ]]; then
        printf '%s' "$request" | "${COMPOSE_COMMAND[@]}" exec -T nginx sh -c \
            'curl -fsS -c /tmp/torrentflix-rpc.cookies -b /tmp/torrentflix-rpc.cookies -H "Content-Type: application/json" --data-binary @- http://deluge:8112/json'
    else
        printf '%s' "$request" | curl -fsS -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
            -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8112/json
    fi
}

wait_for_deluge_webui() {
    local ready=0
    local attempt

    for attempt in $(seq 1 60); do
        if [[ "$MODE" == vps ]]; then
            if "${COMPOSE_COMMAND[@]}" exec -T nginx sh -c 'curl -fsS http://deluge:8112/ >/dev/null' >/dev/null 2>&1; then
                ready=1
            fi
        elif curl -fsS http://127.0.0.1:8112/ >/dev/null 2>&1; then
            ready=1
        fi

        if [[ "$ready" == 1 ]]; then
            return 0
        fi

        sleep 1
    done

    if ! "${COMPOSE_COMMAND[@]}" logs --tail=100 deluge; then
        printf '%s\n' '[!] Could not read Deluge logs' >&2
    fi
    die 'WebUI failed'
}

bootstrap_deluge() {
    local web_password
    local login_response
    local password_response
    local theme_response

    COOKIE_FILE="$(mktemp)"
    trap 'rm -f -- "$COOKIE_FILE"' EXIT
    web_password="$(cat "$PASSWORD_FILE")"

    login_response="$(run_deluge_rpc "{\"method\":\"auth.login\",\"params\":[\"$web_password\"],\"id\":1}")"

    if echo "$login_response" | grep -q '"result": true'; then
        printf '%s\n' '[+] Existing WebUI password accepted'
    else
        login_response="$(run_deluge_rpc '{"method":"auth.login","params":["deluge"],"id":1}')"

        if ! echo "$login_response" | grep -q '"result": true'; then
            die "WebUI login failed: $login_response"
        fi

        password_response="$(run_deluge_rpc "{\"method\":\"auth.change_password\",\"params\":[\"deluge\",\"$web_password\"],\"id\":2}")"

        if ! echo "$password_response" | grep -q '"result": true'; then
            die "Password change failed: $password_response"
        fi
    fi

    theme_response="$(run_deluge_rpc '{"method":"web.set_theme","params":["dark"],"id":3}')"
    if ! echo "$theme_response" | grep -Eq '"result": true|"error": null'; then
        die "Theme API failed: $theme_response"
    fi

    WEB_PASSWORD="$web_password"
}

print_deluge_result() {
    clear_terminal
    printf 'Runtime:        %s\n' "$DELUGE_ROOT"
    printf 'Credentials:    %s\n\n' "$PASSWORD_FILE"

    case "$MODE" in
        vps)
            printf 'WebUI URL:      https://%s/deluge/\n' "$DOMAIN"
            ;;
        home_server)
            printf '%s\n' 'WebUI URL:      http://SERVER_IP:8112'
            ;;
        local)
            printf '%s\n' 'WebUI URL:      http://localhost:8112'
            ;;
        *)
            die "Unsupported installation mode: $MODE"
            ;;
    esac

    printf 'WebUI pass:     %s\n\n' "$WEB_PASSWORD"
    printf 'Downloads:      %s\n' "$DOWNLOAD_DIR"
}

install_deluge() {
    require_command docker
    require_command curl
    require_command tar
    require_command openssl

    if ! command -v sha256sum >/dev/null 2>&1; then
        if ! command -v shasum >/dev/null 2>&1; then
            die 'sha256sum or shasum is required'
        fi
    fi

    prepare_mode_context
    assert_no_source_overlap "$DELUGE_ROOT" "$DEFAULT_DOWNLOAD_DIR"
    DOMAIN=''
    HSTS_POLICY='max-age=63072000'

    if [[ "$MODE" == vps ]]; then
        read -r -p 'Hostname for Deluge HTTPS [deluge.example.com]: ' DOMAIN
        DOMAIN="${DOMAIN:-deluge.example.com}"

        if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
            die 'Invalid hostname'
        fi

        read -r -p 'Enable HSTS subdomains/preload? [y/N]: ' HSTS_INPUT
        case "$HSTS_INPUT" in
            y|Y|yes|YES)
                HSTS_POLICY='max-age=63072000; includeSubDomains; preload'
                ;;
        esac
    fi

    select_download_directory
    assert_no_source_overlap "$DELUGE_ROOT" "$DOWNLOAD_DIR"
    prepare_deluge_directories
    install_deluge_files
    write_deluge_environment

    if [[ ! -s "$PASSWORD_FILE" ]]; then
        umask 077
        openssl rand -hex 16 > "$PASSWORD_FILE"
    fi
    chmod 600 "$PASSWORD_FILE"

    printf '%s\n' '[+] Downloading theme...'
    download_theme
    build_deluge_compose_command
    printf '%s\n' '[+] Building Deluge image...'
    "${COMPOSE_COMMAND[@]}" build --pull
    printf '%s\n' '[+] Starting Deluge...'
    "${COMPOSE_COMMAND[@]}" up -d
    printf '%s\n' '[+] Waiting for Deluge WebUI...'
    wait_for_deluge_webui
    bootstrap_deluge
    print_deluge_result
}

install_plex() {
    require_command docker
    prepare_mode_context
    assert_no_source_overlap "$PLEX_ROOT" "$DEFAULT_MEDIA_DIR"
    PLEX_CLAIM=''

    clear_terminal
    printf '%sTorrentflix Plex%s\n\n' "$LINE" "$RESET"
    printf '%sPlex claim token (optional): %s' "$LINE" "$RESET"
    read -r -s PLEX_CLAIM
    printf '\n'

    select_media_directory
    assert_no_source_overlap "$PLEX_ROOT" "$MEDIA_DIR"
    prepare_plex_directories
    cp "$SCRIPT_DIR/plex/compose.yml" "$PLEX_ROOT/compose.yml"
    write_plex_environment

    printf '%s\n' '[+] Starting Plex Media Server...'
    docker compose --env-file "$PLEX_ENV" -f "$PLEX_ROOT/compose.yml" up -d

    if [[ -n "$PLEX_CLAIM" ]]; then
        PLEX_CLAIM=''
        write_plex_environment
    fi

    printf '\nPlex is running.\n'
    printf '%s\n' 'WebUI:  http://SERVER_IP:32400/web'
    printf 'Media:  %s\n' "$MEDIA_DIR"
    printf 'Config: %s\n' "$PLEX_CONFIG_DIR"
    printf '\n%s\n' 'Headless setup without a claim token:'
    printf '%s\n' '  ssh -N -L 32400:127.0.0.1:32400 user@SERVER_IP'
    printf '%s\n' '  Then open http://localhost:32400/web'
}

safe_delete_root() {
    local target_path="$1"
    local target_type="$2"

    if [[ -z "$target_path" || "$target_path" == '/' || -L "$target_path" ]]; then
        die 'Unsafe delete target'
    fi

    if [[ "$target_path" == "$SCRIPT_DIR" ]]; then
        die 'Refusing to delete the Git checkout'
    fi

    case "$target_type" in
        service)
            if [[ "$target_path" != /opt/torrentflix/deluge && "$target_path" != /opt/torrentflix/plex ]]; then
                die "Path is not an approved service root: $target_path"
            fi
            ;;
        local)
            if [[ "$target_path" != "$DELUGE_ROOT" ]]; then
                die "Path is not the approved local runtime root: $target_path"
            fi
            ;;
        downloads)
            if [[ "$target_path" != "$DELUGE_ROOT/downloads" && "$target_path" != "$REAL_HOME/Downloads/torrentflix-downloads" ]]; then
                die "Path is not the managed downloads path: $target_path"
            fi
            ;;
        *)
            die "Unknown delete type: $target_type"
            ;;
    esac

    if [[ "$target_type" == downloads ]]; then
        if ! has_managed_marker "$target_path" downloads; then
            die 'Managed downloads marker is missing or invalid'
        fi
    elif ! has_managed_marker "$target_path" runtime; then
        die 'Managed runtime marker is missing or invalid'
    fi
}

stop_deluge_stack() {
    if [[ ! -f "$DELUGE_COMPOSE_FILE" && ! -f "$VPS_COMPOSE_FILE" ]]; then
        return 0
    fi

    build_deluge_compose_command
    if ! "${COMPOSE_COMMAND[@]}" down --remove-orphans; then
        printf '%s\n' '[!] Deluge stack was not running or could not be stopped' >&2
    fi
}

remove_top_level_except() {
    local root_path="$1"
    local preserved_name="$2"
    local child_path
    local had_nullglob=false
    local had_dotglob=false

    if shopt -q nullglob; then
        had_nullglob=true
    fi

    if shopt -q dotglob; then
        had_dotglob=true
    fi

    shopt -s nullglob dotglob
    for child_path in "$root_path"/*; do
        if [[ "$(basename -- "$child_path")" == "$preserved_name" || "$(basename -- "$child_path")" == '.torrentflix-managed' ]]; then
            continue
        fi

        rm -rf -- "$child_path"
    done

    if [[ "$had_nullglob" == false ]]; then
        shopt -u nullglob
    fi

    if [[ "$had_dotglob" == false ]]; then
        shopt -u dotglob
    fi
}

prompt_deluge_uninstall_choice() {
    local delete_choice

    while true; do
        clear_terminal
        printf '%sTorrentflix%s\n\n' "$LINE" "$RESET"
        printf '%s\n\n' 'How would you like to remove Deluge?'
        printf '%s1.%s Remove configuration only\n' "$LINE" "$RESET"
        printf '%s2.%s Full remove with downloaded torrent files\n' "$LINE" "$RESET"
        printf '%b%s%b\n' "$MUTED" '   The second option permanently deletes managed downloads.' "$RESET"
        printf '\n'
        read -r -p '?: ' delete_choice

        case "${delete_choice:-1}" in
            1|2)
                DELETE_CHOICE="${delete_choice:-1}"
                return
                ;;
            *)
                printf '%s\n' '[!] Choose 1 or 2'
                sleep 1
                ;;
        esac
    done
}

confirm_deluge_download_deletion() {
    local delete_confirmation

    while true; do
        clear_terminal
        printf '%sTorrentflix%s\n\n' "$LINE" "$RESET"
        printf '%s\n\n' 'Permanent download removal'
        printf '%b%s%b\n\n' "$MUTED" 'This permanently deletes managed downloaded files.' "$RESET"
        read -r -p 'Type DELETE to continue: ' delete_confirmation

        if [[ "$delete_confirmation" == DELETE ]]; then
            return
        fi

        printf '%s\n' '[!] Confirmation must be exactly DELETE'
        sleep 1
    done
}

remove_deluge_configuration() {
    if [[ "$DOWNLOAD_MANAGED" == true && "$DOWNLOAD_DIR" == "$DELUGE_ROOT/downloads" && -d "$DOWNLOAD_DIR" ]]; then
        remove_top_level_except "$DELUGE_ROOT" downloads
    else
        rm -rf -- "$DELUGE_ROOT"
    fi
}

remove_plex_configuration() {
    if [[ "$MEDIA_MANAGED" == true && "$MEDIA_DIR" == "$PLEX_ROOT/media" && -d "$MEDIA_DIR" ]]; then
        remove_top_level_except "$PLEX_ROOT" media
        printf '%s\n' '[+] Plex configuration removed; managed media preserved'
    else
        rm -rf -- "$PLEX_ROOT"
        printf '%s\n' '[+] Plex configuration removed; external media was not touched'
    fi
}

uninstall_deluge() {
    if [[ ! -d "$DELUGE_ROOT" ]]; then
        printf 'Nothing installed at %s\n' "$DELUGE_ROOT"
        return
    fi

    DOWNLOAD_DIR="$(read_env_value "$DELUGE_ENV" DOWNLOAD_DIR)"
    DOWNLOAD_MANAGED="$(read_env_value "$DELUGE_ENV" DOWNLOAD_MANAGED)"
    stop_deluge_stack

    prompt_deluge_uninstall_choice

    if [[ "$DELETE_CHOICE" == 2 && "$DOWNLOAD_MANAGED" == true ]]; then
        confirm_deluge_download_deletion
        safe_delete_root "$DOWNLOAD_DIR" downloads
        rm -rf -- "$DOWNLOAD_DIR"
    fi

    if [[ "$MODE" == local ]]; then
        safe_delete_root "$DELUGE_ROOT" local
    else
        safe_delete_root "$DELUGE_ROOT" service
    fi

    remove_deluge_configuration
    printf '%s\n' '[+] Deluge configuration removed; downloads preserved unless explicitly deleted'
}

uninstall_plex() {
    local media_dir
    local media_managed

    if [[ ! -d "$PLEX_ROOT" ]]; then
        printf 'Nothing installed at %s\n' "$PLEX_ROOT"
        return
    fi

    if [[ -f "$PLEX_ROOT/compose.yml" ]]; then
        if ! docker compose --env-file "$PLEX_ENV" -f "$PLEX_ROOT/compose.yml" down --remove-orphans; then
            printf '%s\n' '[!] Plex stack was not running or could not be stopped' >&2
        fi
    fi

    media_dir="$(read_env_value "$PLEX_ENV" MEDIA_DIR)"
    media_managed="$(read_env_value "$PLEX_ENV" MEDIA_MANAGED)"
    MEDIA_DIR="$media_dir"
    MEDIA_MANAGED="$media_managed"
    safe_delete_root "$PLEX_ROOT" service
    remove_plex_configuration

    if [[ "$MEDIA_MANAGED" == true ]]; then
        printf 'Managed Plex media preserved at: %s\n' "$MEDIA_DIR"
    fi
}

uninstall_service() {
    local selected_service

    prepare_mode_context

    if [[ "$MODE" == local ]]; then
        uninstall_deluge
        return
    fi

    clear_terminal
    printf '%sTorrentflix%s\n\n' "$LINE" "$RESET"
    printf '%s\n\n' 'Which service would you like to uninstall?'
    printf '%s1.%s Deluge\n' "$LINE" "$RESET"
    printf '%s2.%s Plex\n' "$LINE" "$RESET"
    printf '\n'
    read -r -p '?: ' selected_service

    case "$selected_service" in
        1)
            selected_service=deluge
            ;;
        2)
            selected_service=plex
            ;;
        *)
            die 'Choose 1 or 2'
            ;;
    esac

    case "$selected_service" in
        deluge)
            uninstall_deluge
            ;;
        plex)
            uninstall_plex
            ;;
    esac
}

select_installation_mode() {
    local default_choice
    local mode_choice

    clear_terminal
    printf '%sTorrentflix%s\n\n' "$LINE" "$RESET"
    printf '%s\n\n' 'Select installation mode.'
    printf '%s1.%s VPS (Public Server)\n' "$LINE" "$RESET"
    printf '%b%s%b\n' "$MUTED" '   Linux server, public HTTPS, bundled Nginx and Let’s Encrypt.' "$RESET"
    printf '%s2.%s Home Server (LAN Only)\n' "$LINE" "$RESET"
    printf '%b%s%b\n' "$MUTED" '   Always-on Linux server or NAS. No domain or public Nginx.' "$RESET"
    printf '%s3.%s Local (macOS/Linux)\n' "$LINE" "$RESET"
    printf '%b%s%b\n' "$MUTED" '   Personal computer. Deluge only; no Plex in Local mode.' "$RESET"

    if [[ "$HOST_OS" == Darwin ]]; then
        default_choice=3
    else
        default_choice=1
    fi

    printf '\n'
    read -r -p '?: ' mode_choice
    mode_choice="${mode_choice:-$default_choice}"

    case "$mode_choice" in
        1)
            MODE=vps
            ;;
        2)
            MODE=home_server
            ;;
        3)
            MODE=local
            ;;
        *)
            die 'Choose 1, 2 or 3'
            ;;
    esac

    if [[ "$MODE" != local ]]; then
        if [[ "$HOST_OS" != Linux ]]; then
            die 'Server modes require Linux'
        fi

        if [[ "$(id -u)" != 0 ]]; then
            die 'Run server mode as root: sudo ./run.sh'
        fi
    elif [[ "$HOST_OS" != Linux && "$HOST_OS" != Darwin ]]; then
        die 'Local mode supports Linux and macOS'
    fi
}

select_service_action() {
    local service_choice

    clear_terminal
    printf '%sTorrentflix%s\n\n' "$LINE" "$RESET"
    printf '%s\n\n' 'What would you like to do?'
    printf '%s1.%s Install Deluge\n' "$LINE" "$RESET"

    if [[ "$MODE" != local ]]; then
        printf '%s2.%s Install Plex\n' "$LINE" "$RESET"
        printf '%s3.%s Uninstall a service\n' "$LINE" "$RESET"
    else
        printf '%s2.%s Uninstall Deluge\n' "$LINE" "$RESET"
    fi

    printf '\n'
    read -r -p '?: ' service_choice
    service_choice="${service_choice:-1}"

    if [[ "$MODE" == local ]]; then
        case "$service_choice" in
            1)
                install_deluge
                ;;
            2)
                uninstall_service
                ;;
            *)
                die 'Choose 1 or 2'
                ;;
        esac
        return
    fi

    case "$service_choice" in
        1)
            install_deluge
            ;;
        2)
            install_plex
            ;;
        3)
            uninstall_service
            ;;
        *)
            die 'Choose 1, 2 or 3'
            ;;
    esac
}

select_installation_mode
select_service_action
