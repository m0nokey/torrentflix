#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HOST_OS="$(uname -s 2>/dev/null || printf 'unknown')"

if [ -t 1 ]; then
    COLOR_RESET=$'\033[0m'
    COLOR_LINE=$'\033[38;5;117m'
    COLOR_TEXT=$'\033[97m'
    COLOR_MUTED_ITALIC=$'\033[3;38;5;245m'
else
    COLOR_RESET=''
    COLOR_LINE=''
    COLOR_TEXT=''
    COLOR_MUTED_ITALIC=''
fi

clear_terminal() {
    if command -v clear >/dev/null 2>&1 && [ -t 1 ]; then
        clear
    else
        printf '\033c'
    fi
}

readonly VPS_MEDIA_GID=10000
readonly VPS_DELUGE_UID=10001
readonly VPS_PLEX_UID=10002

die_global() {
    echo "[!] $*" >&2
    exit 1
}

env_value() {
    [ -f "$ENV_FILE" ] || return 0
    awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE"
}

id_in_use() {
    getent passwd "$1" >/dev/null 2>&1 || getent group "$1" >/dev/null 2>&1
}

next_free_id() {
    local candidate="$1"
    while id_in_use "$candidate"; do
        candidate=$((candidate + 1))
    done
    printf '%s\n' "$candidate"
}

configure_runtime_identity() {
    local saved_media_gid saved_deluge_uid saved_plex_uid
    case "$MODE" in
        vps|home_server)
            if ! command -v getent >/dev/null 2>&1; then
                die_global "getent is required for server identity checks"
            fi

            saved_media_gid="$(env_value MEDIA_GID)"
            saved_deluge_uid="$(env_value DELUGE_UID)"
            saved_plex_uid="$(env_value PLEX_UID)"

            if [ -n "${TORRENTFLIX_MEDIA_GID:-}" ]; then
                MEDIA_GID="$TORRENTFLIX_MEDIA_GID"
            elif [ -n "$saved_media_gid" ]; then
                MEDIA_GID="$saved_media_gid"
            else
                MEDIA_GID="$(next_free_id "$VPS_MEDIA_GID")"
            fi

            if [ -n "${TORRENTFLIX_DELUGE_UID:-}" ]; then
                DELUGE_UID="$TORRENTFLIX_DELUGE_UID"
            elif [ -n "$saved_deluge_uid" ]; then
                DELUGE_UID="$saved_deluge_uid"
            else
                DELUGE_UID="$(next_free_id "$VPS_DELUGE_UID")"
            fi

            if [ -n "${TORRENTFLIX_PLEX_UID:-}" ]; then
                PLEX_UID="$TORRENTFLIX_PLEX_UID"
            elif [ -n "$saved_plex_uid" ]; then
                PLEX_UID="$saved_plex_uid"
            else
                PLEX_UID="$(next_free_id "$VPS_PLEX_UID")"
            fi

            if [ "$DELUGE_UID" = "$MEDIA_GID" ]; then
                [ -n "${TORRENTFLIX_DELUGE_UID:-}" ] || [ -n "$saved_deluge_uid" ] || \
                    DELUGE_UID="$(next_free_id "$((DELUGE_UID + 1))")"
            fi
            if [ "$PLEX_UID" = "$MEDIA_GID" ] || [ "$PLEX_UID" = "$DELUGE_UID" ]; then
                [ -n "${TORRENTFLIX_PLEX_UID:-}" ] || [ -n "$saved_plex_uid" ] || \
                    PLEX_UID="$(next_free_id "$((PLEX_UID + 1))")"
            fi

            [[ "$MEDIA_GID" =~ ^[0-9]+$ && "$DELUGE_UID" =~ ^[0-9]+$ && "$PLEX_UID" =~ ^[0-9]+$ ]] || \
                die_global "Server service IDs must be numeric"
            [ "$MEDIA_GID" != 0 ] && [ "$DELUGE_UID" != 0 ] && [ "$PLEX_UID" != 0 ] || \
                die_global "Server service IDs cannot be 0"
            [ "$MEDIA_GID" != "$DELUGE_UID" ] && [ "$MEDIA_GID" != "$PLEX_UID" ] || \
                die_global "Media group ID must differ from service UIDs"
            [ "$DELUGE_UID" != "$PLEX_UID" ] || die_global "Deluge and Plex must use different UIDs"

            for service_id in "$MEDIA_GID" "$DELUGE_UID" "$PLEX_UID"; do
                if id_in_use "$service_id"; then
                    die_global "Configured service ID $service_id is already used by a host account; set a free advanced override"
                fi
            done

            DELUGE_GID="$MEDIA_GID"
            PLEX_GID="$MEDIA_GID"
            ;;
        local)
            if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
                RUNTIME_UID="$SUDO_UID"
                RUNTIME_GID="$SUDO_GID"
            else
                RUNTIME_UID="$(id -u)"
                RUNTIME_GID="$(id -g)"
            fi
            [[ "$RUNTIME_UID" =~ ^[0-9]+$ && "$RUNTIME_GID" =~ ^[0-9]+$ ]] || \
                die_global "Local runtime UID/GID could not be determined"
            DELUGE_UID="$RUNTIME_UID"
            DELUGE_GID="$RUNTIME_GID"
            PLEX_UID="$RUNTIME_UID"
            PLEX_GID="$RUNTIME_GID"
            MEDIA_GID="$RUNTIME_GID"
            ;;
        *)
            die_global "Unknown installation mode: $MODE"
            ;;
    esac
}

select_installation_mode() {
    clear_terminal
    printf '%s%s%s\n' "$COLOR_LINE" "Torrentflix" "$COLOR_RESET"
    echo
    printf '%s%s%s\n' "$COLOR_TEXT" "Select installation mode." "$COLOR_RESET"
    echo
    printf '%s1.%s %sVPS (Public Server)%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_TEXT" "$COLOR_RESET"
    printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Linux server, public HTTPS, bundled Nginx and Let's Encrypt." "$COLOR_RESET"
    printf '%s2.%s %sHome Server (LAN Only)%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_TEXT" "$COLOR_RESET"
    printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Always-on Linux server or NAS. No domain or public Nginx." "$COLOR_RESET"
    printf '%s3.%s %sLocal (macOS/Linux)%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_TEXT" "$COLOR_RESET"
    printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Personal workstation. Deluge only, with local-user file ownership." "$COLOR_RESET"
    echo
    if [ "$HOST_OS" = "Darwin" ]; then
        DEFAULT_MODE_CHOICE=3
    else
        DEFAULT_MODE_CHOICE=1
    fi
    read -r -p "?: " MODE_CHOICE
    MODE_CHOICE="${MODE_CHOICE:-$DEFAULT_MODE_CHOICE}"
    case "$MODE_CHOICE" in
        1) MODE=vps ;;
        2) MODE=home_server ;;
        3) MODE=local ;;
        *) die_global "Choose 1, 2 or 3" ;;
    esac

    if [ "$MODE" = vps ] || [ "$MODE" = home_server ]; then
        [ "$HOST_OS" = Linux ] || die_global "Server modes require Linux"
        [ "$(id -u)" -eq 0 ] || {
            echo "Torrentflix server installation must be run as root." >&2
            echo "Run: sudo ./run.sh" >&2
            exit 1
        }
    fi

    if [ "$MODE" = local ]; then
        [ "$HOST_OS" = Linux ] || [ "$HOST_OS" = Darwin ] || die_global "Local mode supports Linux and macOS"
    fi
}

configure_runtime_paths() {
    if [ "$MODE" = local ]; then
        [ -n "${HOME:-}" ] || die_global "HOME is not set"
        RUNTIME_ROOT="$HOME/torrentflix"
        DATA_ROOT="$RUNTIME_ROOT"
        DEFAULT_DOWNLOAD_DIR="$RUNTIME_ROOT/downloads"
        DEFAULT_MEDIA_DIR="$RUNTIME_ROOT/media"
        WEB_BIND_IP=127.0.0.1
    else
        RUNTIME_ROOT=/opt/torrentflix
        DATA_ROOT=/srv/torrentflix
        DEFAULT_DOWNLOAD_DIR="$DATA_ROOT/downloads"
        DEFAULT_MEDIA_DIR="$DATA_ROOT/media"
        WEB_BIND_IP=0.0.0.0
    fi

    COMPOSE_ROOT="$RUNTIME_ROOT/compose"
    DELUGE_DATA_ROOT="$RUNTIME_ROOT/deluge"
    DELUGE_CONFIG_DIR="$DELUGE_DATA_ROOT/config"
    SECRETS_DIR="$DELUGE_DATA_ROOT/secrets"
    PASSWORD_FILE="$SECRETS_DIR/webui.password"
    PLEX_DATA_ROOT="$RUNTIME_ROOT/plex"
    PLEX_CONFIG_DIR="$PLEX_DATA_ROOT/config"
    PLEX_TRANSCODE_DIR="$PLEX_DATA_ROOT/transcode"
    NGINX_DIR="$COMPOSE_ROOT/nginx"
    THEME_DIR="$COMPOSE_ROOT/theme"
    ENV_FILE="$COMPOSE_ROOT/.env"
    COMPOSE_FILE="$COMPOSE_ROOT/compose.yml"
    VPS_COMPOSE_FILE="$COMPOSE_ROOT/compose.vps.yml"
    PEER_COMPOSE_FILE="$COMPOSE_ROOT/compose.peer.yml"
    NGINX_RUNTIME_CONF="$NGINX_DIR/conf.d.runtime"
}

ensure_runtime_directories() {
    if [ "$MODE" = local ]; then
        install -d -o "$DELUGE_UID" -g "$DELUGE_GID" -m 0755 "$RUNTIME_ROOT" "$COMPOSE_ROOT"
        install -d -o "$DELUGE_UID" -g "$DELUGE_GID" -m 0700 "$DELUGE_CONFIG_DIR" "$SECRETS_DIR"
        install -d -o "$DELUGE_UID" -g "$DELUGE_GID" -m 0755 "$DOWNLOAD_DIR"
        return
    fi

    install -d -o root -g root -m 0755 "$RUNTIME_ROOT" "$COMPOSE_ROOT"
    install -d -o "$DELUGE_UID" -g "$DELUGE_GID" -m 0700 "$DELUGE_CONFIG_DIR" "$SECRETS_DIR"
    install -d -o "$PLEX_UID" -g "$PLEX_GID" -m 0700 "$PLEX_CONFIG_DIR" "$PLEX_TRANSCODE_DIR"
    install -d -o "$DELUGE_UID" -g "$MEDIA_GID" -m 2775 "$DOWNLOAD_DIR"
    install -d -o "$PLEX_UID" -g "$MEDIA_GID" -m 2775 "$MEDIA_DIR"
}

run_plex() {
    PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    PLEX_IMAGE="plexinc/pms-docker:1.43.3.10861-07dfddaeb@sha256:5bc1d13f48da6366f46aaf2a3ce1a6292897eadc1f8efcbbd7321d30e94f2ed4"

    command -v docker >/dev/null || { echo "[!] Docker is required" >&2; exit 1; }

    if [ -t 1 ]; then
        COLOR_RESET=$'\033[0m'
        COLOR_LINE=$'\033[38;5;117m'
    else
        COLOR_RESET=''
        COLOR_LINE=''
    fi

    [ "$MODE" != local ] || die_global "Plex is available only in VPS and Home Server modes"
    configure_runtime_paths
    configure_runtime_identity

    clear_terminal
    printf '%s%s%s\n' "$COLOR_LINE" "Torrentflix Plex" "$COLOR_RESET"
    echo

    PLEX_CLAIM=""
    printf '%sPlex claim token (optional): %s' "$COLOR_LINE" "$COLOR_RESET"
    read -r -s PLEX_CLAIM
    echo

    SAVED_MEDIA_DIR="$(env_value MEDIA_DIR)"
    [ -n "$SAVED_MEDIA_DIR" ] && DEFAULT_MEDIA_DIR="$SAVED_MEDIA_DIR"
    printf '%sMedia directory [%s]: %s' "$COLOR_LINE" "$DEFAULT_MEDIA_DIR" "$COLOR_RESET"
    read -r MEDIA_INPUT
    MEDIA_DIR="${MEDIA_INPUT:-$DEFAULT_MEDIA_DIR}"
    case "$MEDIA_DIR" in
        /*) ;;
        *) echo "[!] Media directory must be an absolute path" >&2; exit 1 ;;
    esac
    SAVED_DOWNLOAD_DIR="$(env_value DOWNLOAD_DIR)"
    DOWNLOAD_DIR="${SAVED_DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_DIR}"

    ensure_runtime_directories
    if [ "$MODE" != local ] && [ ! -e "$PLEX_CONFIG_DIR/.torrentflix-migrated" ]; then
        if [ -d /opt/plex/config/plex/db ] && [ ! -e "$PLEX_CONFIG_DIR/Preferences.xml" ]; then
            cp -a /opt/plex/config/plex/db/. "$PLEX_CONFIG_DIR/"
        fi
        touch "$PLEX_CONFIG_DIR/.torrentflix-migrated"
        chown -R "$PLEX_UID:$PLEX_GID" "$PLEX_CONFIG_DIR" "$PLEX_TRANSCODE_DIR"
    fi

    echo "[+] Installing the Compose project into $COMPOSE_ROOT..."
    cp "$PROJECT_DIR/plex/compose.yml" "$COMPOSE_ROOT/plex.compose.yml"
    cp "$PROJECT_DIR/plex/.env.example" "$COMPOSE_ROOT/plex.env.example"

    cat > "$ENV_FILE" <<EOF
MODE=$MODE
RUNTIME_ROOT=$RUNTIME_ROOT
MEDIA_GID=$MEDIA_GID
DELUGE_UID=$DELUGE_UID
DELUGE_GID=$DELUGE_GID
PLEX_UID=$PLEX_UID
PLEX_GID=$PLEX_GID
PLEX_CONFIG_DIR=$PLEX_CONFIG_DIR
PLEX_TRANSCODE_DIR=$PLEX_TRANSCODE_DIR
DOWNLOAD_DIR=$DOWNLOAD_DIR
TZ=UTC
MEDIA_DIR=$MEDIA_DIR
PLEX_CLAIM=$PLEX_CLAIM
PLEX_IMAGE=$PLEX_IMAGE
PLEX_MEM_LIMIT=4g
PLEX_MEM_RESERVATION=512m
PLEX_CPUS=2.0
PLEX_PIDS_LIMIT=512
EOF
    chmod 600 "$ENV_FILE"

    echo "[+] Starting Plex Media Server..."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_ROOT/plex.compose.yml" up -d

    if [ -n "$PLEX_CLAIM" ]; then
        # The claim token is passed to the newly created container, but should
        # not remain in the host-side Compose environment file.
        PLEX_ENV_TMP="$(mktemp)"
        sed '/^PLEX_CLAIM=/d' "$ENV_FILE" > "$PLEX_ENV_TMP"
        printf 'PLEX_CLAIM=\n' >> "$PLEX_ENV_TMP"
        chmod 600 "$PLEX_ENV_TMP"
        mv "$PLEX_ENV_TMP" "$ENV_FILE"
    fi

    echo
    echo "Plex is running."
    echo "WebUI:  http://SERVER_IP:32400/web"
    echo "Media:  $MEDIA_DIR"
    echo "Config: $PLEX_CONFIG_DIR"
    echo
    echo "Headless setup (if no claim token was provided):"
    echo "  ssh -N -L 32400:127.0.0.1:32400 user@SERVER_IP"
    echo "  Then open http://localhost:32400/web"
}

run_deluge() {
    PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    SOURCE_NGINX_DIR="$PROJECT_DIR/deluge/nginx"
    IMAGE="lscr.io/linuxserver/deluge:2.2.0@sha256:33a939576f7ecfc1227db1a0cb2afce030ce983e620ec9d93c956e3700e21fe9"
    WEB_DIR="/lsiopy/lib/python3.12/site-packages/deluge/ui/web"
    THEME_COMMIT="dbef18e3c9a2cb0f2448d16bb95dca868f94440e"
    THEME_SHA256="5c3e6a4453fb06c16bc89f3b3789f12ba56b01addc111477211cb63e93f291bb"
    THEME_URL="https://raw.githubusercontent.com/joelacus/deluge-web-dark-theme/${THEME_COMMIT}/deluge_web_dark_theme.tar.gz"

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
        local compose_file="$1" root="${2:-${1%/*}}" args=(-f "$1")
        if [ -f "$root/.env" ]; then
            args=(--env-file "$root/.env" "${args[@]}")
        fi
        if [ -f "$root/compose.peer.yml" ]; then
            args+=( -f "$root/compose.peer.yml" )
        fi
        [ -n "$(docker compose "${args[@]}" ps -q 2>/dev/null || true)" ]
    }
    stop_compose_stack() {
        local compose_file="$1" root="${1%/*}" args=(-f "$1")
        if [ -f "$root/.env" ]; then
            args=(--env-file "$root/.env" "${args[@]}")
        fi
        if [ -f "$root/compose.peer.yml" ]; then
            args+=( -f "$root/compose.peer.yml" )
        fi
        docker compose "${args[@]}" down --remove-orphans
    }
    delete_runtime_root() {
        local root="$1" delete_data="${2:-0}"
        [ -n "$root" ] || die "Refusing to delete an empty path"
        [ "$root" != "/" ] || die "Refusing to delete the filesystem root"
        [ ! -L "$root" ] || die "Refusing to delete a symbolic link: $root"
        case "$root" in
            /opt/torrentflix|/opt/deluge|/opt/plex) ;;
            "${HOME:-}"/torrentflix|"${HOME:-}"/Downloads/deluge) ;;
            *) die "Refusing to delete an unapproved runtime path: $root" ;;
        esac
        [ -f "$root/compose.yml" ] || [ -f "$root/compose/compose.yml" ] || \
            [ -f "$root/compose.vps.yml" ] || [ -f "$root/compose/compose.vps.yml" ] || \
            die "Refusing to delete a directory without a Torrentflix Compose file: $root"
        case "$root" in
            "${HOME:-}"/torrentflix)
                if [ "$delete_data" = 1 ]; then
                    rm -rf -- "$root"
                else
                    rm -rf -- "$root/compose" "$root/deluge" "$root/plex"
                    rmdir -- "$root" 2>/dev/null || true
                fi
                ;;
            *)
                rm -rf -- "$root"
                ;;
        esac
    }
    command -v docker >/dev/null || die "Docker is required"
    command -v curl >/dev/null || die "curl is required"
    command -v tar >/dev/null || die "tar is required"
    command -v openssl >/dev/null || die "openssl is required"
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        die "sha256sum or shasum is required"
    fi

    sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" | awk '{print $1}'
        else
            shasum -a 256 "$1" | awk '{print $1}'
        fi
    }

    configure_runtime_paths
    configure_runtime_identity

    declare -a EXISTING_STACKS=()
    declare -a EXISTING_ROOTS=()
    declare -a CANDIDATE_ROOTS=("$RUNTIME_ROOT")
    [ "$RUNTIME_ROOT" = /opt/torrentflix ] || CANDIDATE_ROOTS+=("/opt/torrentflix")
    [ "$RUNTIME_ROOT" = /opt/deluge ] || CANDIDATE_ROOTS+=("/opt/deluge")
    if [ -n "${HOME:-}" ]; then
        [ "$RUNTIME_ROOT" = "$HOME/torrentflix" ] || CANDIDATE_ROOTS+=("$HOME/torrentflix")
        [ "$RUNTIME_ROOT" = "$HOME/Downloads/deluge" ] || CANDIDATE_ROOTS+=("$HOME/Downloads/deluge")
    fi

    for candidate_root in "${CANDIDATE_ROOTS[@]}"; do
        for candidate_file in \
            "$candidate_root/compose/compose.vps.yml" \
            "$candidate_root/compose/compose.yml" \
            "$candidate_root/compose.vps.yml" \
            "$candidate_root/compose.yml" \
            "$candidate_root/nginx/compose.yml"
        do
            if [ -f "$candidate_file" ] && compose_is_running "$candidate_file" "${candidate_file%/*}"; then
                EXISTING_STACKS+=("$candidate_file")
                existing_root="$candidate_root"
                already_listed=0
                if [ "${#EXISTING_ROOTS[@]}" -gt 0 ]; then
                    for listed_root in "${EXISTING_ROOTS[@]}"; do
                        [ "$listed_root" = "$existing_root" ] && already_listed=1
                    done
                fi
                [ "$already_listed" = 1 ] || EXISTING_ROOTS+=("$existing_root")
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
        printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Install keeps config, password and downloads." "$COLOR_RESET"
        echo
        printf '%s%s.%s %s%s%s\n' "$COLOR_LINE" "1" "$COLOR_RESET" "$COLOR_TEXT" "Install" "$COLOR_RESET"
        printf '%s%s.%s %s%s%s\n' "$COLOR_LINE" "2" "$COLOR_RESET" "$COLOR_TEXT" "Delete" "$COLOR_RESET"
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
            2)
                echo
                printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "Delete removes the Torrentflix application and configuration directory." "$COLOR_RESET"
                printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "Server downloads and media under /srv/torrentflix are preserved." "$COLOR_RESET"
                read -r -p "Type DELETE to confirm: " DELETE_CONFIRM
                [ "$DELETE_CONFIRM" = "DELETE" ] || exit 0
                DELETE_DATA=0
                for existing_root in "${EXISTING_ROOTS[@]}"; do
                    if [ "$existing_root" = "${HOME:-}/torrentflix" ]; then
                        echo
                        printf '%s1.%s Keep local downloads and remove configuration only%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_RESET"
                        printf '%s2.%s Remove configuration and local downloads%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_RESET"
                        read -r -p "?: " DELETE_DATA_CHOICE
                        case "${DELETE_DATA_CHOICE:-1}" in
                            1) DELETE_DATA=0 ;;
                            2) DELETE_DATA=1 ;;
                            *) die "Choose 1 or 2" ;;
                        esac
                    fi
                done
                for existing_stack in "${EXISTING_STACKS[@]}"; do
                    stop_compose_stack "$existing_stack" || true
                done
                for existing_root in "${EXISTING_ROOTS[@]}"; do
                    delete_runtime_root "$existing_root" "$DELETE_DATA"
                    echo "[+] Deleted $existing_root"
                done
                exit 0
                ;;
            *) die "Choose 1 or 2" ;;
        esac
    fi

    DOMAIN=""
    HSTS_POLICY="max-age=63072000"
    PEER_PORT=""
    SAVED_DOWNLOAD_DIR="$(env_value DOWNLOAD_DIR)"
    [ -n "$SAVED_DOWNLOAD_DIR" ] && DEFAULT_DOWNLOAD_DIR="$SAVED_DOWNLOAD_DIR"
    SAVED_MEDIA_DIR="$(env_value MEDIA_DIR)"
    [ -n "$SAVED_MEDIA_DIR" ] && DEFAULT_MEDIA_DIR="$SAVED_MEDIA_DIR"
    if [ "$MODE" = vps ]; then
        read -r -p "Hostname for Deluge HTTPS [deluge.example.com]: " DOMAIN_INPUT
        DOMAIN="${DOMAIN_INPUT:-deluge.example.com}"
        case "$DOMAIN" in
            ''|*[!A-Za-z0-9.-]*) die "Domain contains unsupported characters" ;;
        esac
        read -r -p "Enable HSTS for subdomains/preload? [y/N]: " HSTS_INPUT
        case "$HSTS_INPUT" in
            y|Y|yes|YES) HSTS_POLICY="max-age=63072000; includeSubDomains; preload" ;;
        esac
    fi

    read -r -p "Incoming BitTorrent host port (optional, disabled by default): " PEER_PORT
    if [ -n "$PEER_PORT" ]; then
        [[ "$PEER_PORT" =~ ^[0-9]+$ ]] || die "Peer port must be numeric"
        [ "$PEER_PORT" -ge 1 ] && [ "$PEER_PORT" -le 65535 ] || die "Peer port must be between 1 and 65535"
        [ "$MODE" != vps ] || { [ "$PEER_PORT" != 80 ] && [ "$PEER_PORT" != 443 ]; } || \
            die "Peer port 80 and 443 are reserved by bundled Nginx"
        [ "$MODE" = vps ] || [ "$PEER_PORT" != 8112 ] || die "Peer port cannot be 8112 because that port is used by the WebUI"
    fi

    read -r -p "Download directory [$DEFAULT_DOWNLOAD_DIR]: " DOWNLOAD_DIR_INPUT
    DOWNLOAD_DIR="${DOWNLOAD_DIR_INPUT:-$DEFAULT_DOWNLOAD_DIR}"
    case "$DOWNLOAD_DIR" in
        /*) ;;
        *) die "Download directory must be absolute" ;;
    esac
    MEDIA_DIR="$DEFAULT_MEDIA_DIR"
    ensure_runtime_directories

    # Migrate data from the previous checkout-based layout when it exists.
    if [ ! -e "$DELUGE_CONFIG_DIR/.torrentflix-migrated" ]; then
        for legacy_root in /opt/deluge "${HOME:-}"/Downloads/deluge; do
            if [ -d "$legacy_root/config" ] && [ "$legacy_root/config" != "$DELUGE_CONFIG_DIR" ]; then
                cp -a "$legacy_root/config/." "$DELUGE_CONFIG_DIR/"
                if [ -f "$legacy_root/secrets/webui.password" ] && [ ! -s "$PASSWORD_FILE" ]; then
                    cp "$legacy_root/secrets/webui.password" "$PASSWORD_FILE"
                fi
                break
            fi
        done
        if [ "$MODE" != local ]; then
            for legacy_root in /opt/plex; do
                if [ -d "$legacy_root/config/plex/db" ] && [ ! -e "$PLEX_CONFIG_DIR/Preferences.xml" ]; then
                    cp -a "$legacy_root/config/plex/db/." "$PLEX_CONFIG_DIR/"
                    break
                fi
            done
        fi
        touch "$DELUGE_CONFIG_DIR/.torrentflix-migrated"
    fi
    chown -R "$DELUGE_UID:$DELUGE_GID" "$DELUGE_CONFIG_DIR" "$SECRETS_DIR"
    if [ "$MODE" != local ]; then
        chown -R "$PLEX_UID:$PLEX_GID" "$PLEX_CONFIG_DIR" "$PLEX_TRANSCODE_DIR"
    fi

    echo "[+] Installing the required project files into $COMPOSE_ROOT..."
    cp "$PROJECT_DIR/deluge/Dockerfile" "$COMPOSE_ROOT/Dockerfile"
    cp "$PROJECT_DIR/deluge/compose.yml" "$COMPOSE_ROOT/compose.yml"
    cp "$PROJECT_DIR/deluge/.dockerignore" "$COMPOSE_ROOT/.dockerignore"
    rm -f "$PEER_COMPOSE_FILE"

    rm -rf "$NGINX_DIR" "$VPS_COMPOSE_FILE"

    if [ "$MODE" = vps ]; then
        COMPOSE_FILE="$VPS_COMPOSE_FILE"
        cp "$PROJECT_DIR/deluge/compose.vps.yml" "$COMPOSE_FILE"
        mkdir -p "$NGINX_DIR/conf.d.runtime" "$NGINX_DIR/www"
        cp "$SOURCE_NGINX_DIR/Dockerfile" "$NGINX_DIR/Dockerfile"
        sed "s|__HSTS_POLICY__|$HSTS_POLICY|g" \
            "$SOURCE_NGINX_DIR/nginx.conf" > "$NGINX_DIR/nginx.conf"
    fi

    if [ -n "$PEER_PORT" ]; then
        cp "$PROJECT_DIR/deluge/compose.peer.yml" "$PEER_COMPOSE_FILE"
    fi

    cat > "$ENV_FILE" <<EOF
MODE=$MODE
RUNTIME_ROOT=$RUNTIME_ROOT
MEDIA_GID=$MEDIA_GID
DELUGE_UID=$DELUGE_UID
DELUGE_GID=$DELUGE_GID
PLEX_UID=$PLEX_UID
PLEX_GID=$PLEX_GID
PLEX_CONFIG_DIR=$PLEX_CONFIG_DIR
PLEX_TRANSCODE_DIR=$PLEX_TRANSCODE_DIR
DOWNLOAD_DIR=$DOWNLOAD_DIR
MEDIA_DIR=$MEDIA_DIR
DELUGE_IMAGE=$IMAGE
WEB_DIR=$WEB_DIR
DELUGE_CONFIG_DIR=$DELUGE_CONFIG_DIR
WEB_PORT=8112
WEB_BIND_IP=$WEB_BIND_IP
PRIMARY_DOMAIN=$DOMAIN
HSTS_POLICY=$HSTS_POLICY
PEER_PORT=$PEER_PORT
PEER_BIND_IP=0.0.0.0
PLEX_CLAIM=
PLEX_IMAGE=$(env_value PLEX_IMAGE)
PLEX_MEM_LIMIT=$(env_value PLEX_MEM_LIMIT)
PLEX_MEM_RESERVATION=$(env_value PLEX_MEM_RESERVATION)
PLEX_CPUS=$(env_value PLEX_CPUS)
PLEX_PIDS_LIMIT=$(env_value PLEX_PIDS_LIMIT)
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
    THEME_ARCHIVE="$(mktemp)"
    curl -fsSL "$THEME_URL" -o "$THEME_ARCHIVE"
    [ "$(sha256_file "$THEME_ARCHIVE")" = "$THEME_SHA256" ] || {
        rm -f "$THEME_ARCHIVE"
        die "Theme checksum verification failed"
    }
    tar -xzf "$THEME_ARCHIVE" -C "$THEME_DIR"
    rm -f "$THEME_ARCHIVE"
    [ -d "$THEME_DIR/icons" ] || die "Theme icons are missing"
    [ -d "$THEME_DIR/images" ] || die "Theme images are missing"
    [ -f "$THEME_DIR/themes/css/xtheme-dark.css" ] || die "Theme CSS is missing"

    if [ "$MODE" = vps ]; then
        echo "[+] Generating bundled Nginx configuration..."
        rm -rf "$NGINX_RUNTIME_CONF"
        mkdir -p "$NGINX_RUNTIME_CONF"
        cp "$SOURCE_NGINX_DIR/conf.d/00-acme.conf" "$NGINX_RUNTIME_CONF/00-acme.conf"
        sed "s/domain\.com/$DOMAIN/g" \
            "$SOURCE_NGINX_DIR/conf.d/domain.com.conf" > "$NGINX_RUNTIME_CONF/$DOMAIN.conf"
    fi

    echo "[+] Building Deluge image..."
    COMPOSE_ARGS=(--env-file "$ENV_FILE" -f "$COMPOSE_FILE")
    [ -f "$PEER_COMPOSE_FILE" ] && COMPOSE_ARGS+=( -f "$PEER_COMPOSE_FILE" )
    compose() { docker compose "${COMPOSE_ARGS[@]}" "$@"; }
    compose build --pull
    echo "[+] Starting Deluge..."
    compose up -d

    echo "[+] Waiting for Deluge WebUI..."
    READY=0
    for _ in $(seq 1 60); do
        if [ "$MODE" = vps ]; then
            if compose exec -T nginx \
                sh -c 'curl -fsS http://deluge:8112/ >/dev/null' >/dev/null 2>&1; then
                READY=1
                break
            fi
        else
            if curl -fsS "http://127.0.0.1:8112/" >/dev/null 2>&1; then
                READY=1
                break
            fi
        fi
        sleep 1
    done

    if [ "$READY" != 1 ]; then
        compose logs --tail=100 deluge
        die "WebUI failed"
    fi

    COOKIE="$(mktemp)"
    trap 'rm -f "$COOKIE"' EXIT
    WEB_URL="http://127.0.0.1:8112/json"
    WEB_PASSWORD="$(cat "$PASSWORD_FILE")"

    rpc() {
        if [ "$MODE" = vps ]; then
            printf '%s' "$1" | compose \
                exec -T nginx sh -c \
                'curl -fsS -c /tmp/torrentflix-rpc.cookies -b /tmp/torrentflix-rpc.cookies \
                    -H "Content-Type: application/json" --data-binary @- http://deluge:8112/json'
        else
            printf '%s' "$1" | curl -fsS -c "$COOKIE" -b "$COOKIE" \
                -H 'Content-Type: application/json' --data-binary @- "$WEB_URL"
        fi
    }

    LOGIN="$(rpc "{\"method\":\"auth.login\",\"params\":[\"$WEB_PASSWORD\"],\"id\":1}")"

    if echo "$LOGIN" | grep -q '"result": true'; then
        echo "[+] Existing WebUI password accepted"
    else
        LOGIN="$(rpc '{"method":"auth.login","params":["deluge"],"id":1}')"
        echo "$LOGIN" | grep -q '"result": true' || die "WebUI login failed: $LOGIN"

        echo "[+] Changing WebUI password..."
        PASSWORD_RESULT="$(
            rpc "{\"method\":\"auth.change_password\",\"params\":[\"deluge\",\"$WEB_PASSWORD\"],\"id\":2}"
        )"
        echo "$PASSWORD_RESULT" | grep -q '"result": true' || {
            echo "[!] Password change failed: $PASSWORD_RESULT"
            exit 1
        }
    fi

    if [ -n "$PEER_PORT" ]; then
        echo "[+] Configuring Deluge inbound peer port..."
        PEER_RESULT="$(rpc '{"method":"core.set_config","params":[{"random_port":false,"listen_ports":[6881,6881]}],"id":4}')"
        echo "$PEER_RESULT" | grep -q '"error": null' || {
            echo "[!] Peer port configuration failed: $PEER_RESULT"
            exit 1
        }

        PEER_CONFIG="$(rpc '{"method":"core.get_config_values","params":[["random_port","listen_ports"]],"id":5}')"
        echo "$PEER_CONFIG" | grep -q '"error": null' || {
            echo "[!] Peer port verification failed: $PEER_CONFIG"
            exit 1
        }
        echo "$PEER_CONFIG" | grep -Eq '"random_port"[[:space:]]*:[[:space:]]*false' || {
            echo "[!] Deluge random port setting was not disabled: $PEER_CONFIG"
            exit 1
        }
        echo "$PEER_CONFIG" | grep -Eq '"listen_ports"[[:space:]]*:[[:space:]]*\[[[:space:]]*6881[[:space:]]*,[[:space:]]*6881[[:space:]]*\]' || {
            echo "[!] Deluge listen ports were not set to 6881: $PEER_CONFIG"
            exit 1
        }
    fi

    THEME_RESULT="$(rpc '{"method":"web.set_theme","params":["dark"],"id":6}')"
    echo "$THEME_RESULT" | grep -Eq '"result": true|"error": null' || die "Theme API failed: $THEME_RESULT"

    if [ "$MODE" = home_server ]; then
        WEBUI_URL="http://SERVER_IP:8112"
        echo
        echo "Deluge is running in Home Server (LAN Only) mode."
        echo "WebUI: http://SERVER_IP:8112"
    elif [ "$MODE" = local ]; then
        WEBUI_URL="http://localhost:8112"
        echo
        echo "Deluge is running in Local mode."
        echo "WebUI: http://localhost:8112"
    else
        WEBUI_URL="https://$DOMAIN/deluge/"
        echo
        echo "Deluge and bundled Nginx are running."
        echo "URL: https://$DOMAIN/deluge/"
    fi

    clear_terminal
    echo "Runtime root:   $RUNTIME_ROOT"
    echo "WebUI URL:     $WEBUI_URL"
    echo "Password file: $PASSWORD_FILE"
    echo "WebUI password: $WEB_PASSWORD"
    echo "Downloads:     $DOWNLOAD_DIR"
    if [ -z "$PEER_PORT" ]; then
        echo "Peer port:     internal only"
    else
        echo "Peer port:     $PEER_PORT -> container 6881 (TCP/UDP)"
    fi
}

select_installation_mode

clear_terminal
printf '%s%s%s\n' "$COLOR_LINE" "Torrentflix" "$COLOR_RESET"
echo
printf '%s%s%s\n' "$COLOR_TEXT" "What would you like to install?" "$COLOR_RESET"
echo
printf '%s1.%s %sDeluge%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_TEXT" "$COLOR_RESET"
printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Download files with magnet links or torrent files." "$COLOR_RESET"
if [ "$MODE" != local ]; then
    printf '%s2.%s %sPlex%s\n' "$COLOR_LINE" "$COLOR_RESET" "$COLOR_TEXT" "$COLOR_RESET"
    printf '%b%s%b\n' "$COLOR_MUTED_ITALIC" "   Stream your media library on your server." "$COLOR_RESET"
fi
echo
read -r -p "?: " SERVICE
SERVICE="${SERVICE:-1}"

case "$SERVICE" in
    1) run_deluge ;;
    2)
        [ "$MODE" != local ] || { echo "[!] Plex is available only in server modes" >&2; exit 1; }
        run_plex
        ;;
    *) echo "[!] Choose 1 or 2" >&2; exit 1 ;;
esac
