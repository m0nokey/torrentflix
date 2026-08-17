#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
THEME_REPOSITORY='https://github.com/joelacus/deluge-web-dark-theme.git'
THEME_RAW_BASE='https://raw.githubusercontent.com/joelacus/deluge-web-dark-theme'
RUN_FILE="$REPOSITORY_ROOT/run.sh"
CI_FILE="$REPOSITORY_ROOT/.github/workflows/ci.yml"

die() {
    printf '[!] %s\n' "$*" >&2
    exit 1
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "Required command is missing: $command_name"
    fi
}

require_command curl
require_command git
require_command python3

if command -v sha256sum >/dev/null 2>&1; then
    HASH_COMMAND=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    HASH_COMMAND=(shasum -a 256)
else
    die 'sha256sum or shasum is required'
fi

TEMP_DIR="$(mktemp -d)"

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT

theme_commit="$(git ls-remote "$THEME_REPOSITORY" refs/heads/main | awk 'NR == 1 { print $1 }')"
if [[ ! "$theme_commit" =~ ^[0-9a-f]{40}$ ]]; then
    die 'Could not resolve the Deluge theme main commit'
fi

archive_file="$TEMP_DIR/deluge_web_dark_theme.tar.gz"
theme_url="$THEME_RAW_BASE/$theme_commit/deluge_web_dark_theme.tar.gz"
curl -fsSL "$theme_url" -o "$archive_file"
theme_sha256="$("${HASH_COMMAND[@]}" "$archive_file" | awk '{ print $1 }')"

python3 - "$RUN_FILE" "$CI_FILE" "$theme_commit" "$theme_sha256" <<'PY'
import re
import sys
from pathlib import Path

run_path = Path(sys.argv[1])
ci_path = Path(sys.argv[2])
commit = sys.argv[3]
sha256 = sys.argv[4]

run_text = run_path.read_text()
ci_text = ci_path.read_text()

run_text, commit_count = re.subn(
    r"(?m)^readonly THEME_COMMIT='[0-9a-f]{40}'$",
    f"readonly THEME_COMMIT='{commit}'",
    run_text,
)
run_text, sha_count = re.subn(
    r"(?m)^readonly THEME_SHA256='[0-9a-f]{64}'$",
    f"readonly THEME_SHA256='{sha256}'",
    run_text,
)
ci_text, ci_commit_count = re.subn(
    r"(deluge-web-dark-theme/)[0-9a-f]{40}(/deluge_web_dark_theme\.tar\.gz)",
    rf"\g<1>{commit}\g<2>",
    ci_text,
)
ci_text, ci_sha_count = re.subn(
    r"(?m)^            '[0-9a-f]{64}'$",
    f"            '{sha256}'",
    ci_text,
)

if (commit_count, sha_count, ci_commit_count, ci_sha_count) != (1, 1, 1, 1):
    raise SystemExit('Expected exactly one theme pin in run.sh and CI workflow')

run_path.write_text(run_text)
ci_path.write_text(ci_text)
PY

printf 'Updated Deluge theme to %s (%s)\n' "$theme_commit" "$theme_sha256"
