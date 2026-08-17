# Contributing to Torrentflix

## Dependency maintenance

Dependency updates are maintained automatically by Renovate. Docker images
remain pinned to immutable version-and-digest references, and GitHub Actions
remain pinned to full commit SHAs. Digest, patch and minor updates may be
merged automatically after the required CI checks pass and the release-age
cooldown expires. Major updates stay open for manual review.

The installer never resolves `latest`, searches upstream releases or calculates
dependency versions at runtime. A Git commit must install the exact pins stored
in that commit.

The scheduled theme-maintenance workflow handles the one custom dependency
Renovate cannot safely update by itself: the Deluge theme commit and its
SHA-256. It opens a normal pull request, so the same CI gate applies.

## Bash style

Shell scripts use Bash with `set -euo pipefail`, four-space indentation and
`name() {` function declarations. The code should be explicit, readable and
boring to review.

- Use `[[ ... ]]` for Bash conditionals and quote path/user-input expansions.
- Expand core control flow into readable `if`, `elif`, `else`, `case` and loop
  blocks. Do not use semicolon-compressed or one-line control flow.
- Do not replace validation or security logic with `condition && action` or
  `condition || return`; use named helpers and explicit branches.
- Use `local` for function-local variables and arrays for dynamic command
  arguments. Do not use `eval` or build commands as strings.
- Use `printf` for predictable output, `mktemp` plus cleanup for temporary
  files, and `--` before path arguments where supported.
- Treat `rm -rf`, `chown`, `chmod`, secret handling and external mount paths as
  security-sensitive code that deserves visible validation steps.

Run the local checks before opening a pull request:

```bash
shellcheck --severity=error run.sh scripts/*.sh
bash -n run.sh scripts/*.sh
git diff --check
```

Keep behavior changes and broad formatting-only changes in separate commits
where practical.
