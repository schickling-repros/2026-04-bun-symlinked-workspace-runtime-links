#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd bun
require_cmd node
require_cmd corepack
require_cmd readlink
require_cmd mktemp

PNPM_VERSION="11.0.0-beta.2"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bun-symlinked-workspace-runtime.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

say() {
  printf '\n== %s ==\n' "$1"
}

write_app_files() {
  local base="$1"
  local shared_dir="$2"

  mkdir -p "$base/root/app" "$shared_dir"

  cat >"$shared_dir/package.json" <<'EOF'
{
  "name": "shared-lib",
  "private": true,
  "type": "module",
  "exports": {
    ".": "./index.js"
  },
  "dependencies": {
    "is-number": "7.0.0"
  }
}
EOF

  cat >"$shared_dir/index.js" <<'EOF'
import isNumber from 'is-number'

export const check = (value) => isNumber(value)
EOF

  cat >"$base/root/package.json" <<'EOF'
{
  "name": "root",
  "private": true,
  "workspaces": [
    "app",
    "repos/ext/shared-lib"
  ]
}
EOF

  cat >"$base/root/app/package.json" <<'EOF'
{
  "name": "app",
  "private": true,
  "type": "module",
  "dependencies": {
    "shared-lib": "workspace:*"
  }
}
EOF

  cat >"$base/root/app/index.js" <<'EOF'
import { check } from 'shared-lib'

console.log(check(1))
EOF
}

setup_symlinked_workspace() {
  local base="$1"
  mkdir -p "$base/root/repos" "$base/external"
  ln -s ../../external "$base/root/repos/ext"
  write_app_files "$base" "$base/external/shared-lib"
}

setup_direct_workspace() {
  local base="$1"
  mkdir -p "$base/root/repos/ext"
  write_app_files "$base" "$base/root/repos/ext/shared-lib"
}

run_bun_symlinked_case() {
  local base="$TMP_ROOT/bun-symlinked"
  local runtime_status=0

  setup_symlinked_workspace "$base"

  pushd "$base/root" >/dev/null
  bun install >"$base/install.log" 2>&1
  bun app/index.js >"$base/run.log" 2>&1 || runtime_status=$?
  popd >/dev/null

  say "Bun symlinked workspace member"
  cat "$base/install.log"
  cat "$base/run.log"
  ls -l "$base/external/shared-lib/node_modules/is-number"
  printf 'readlink -f: '
  readlink -f "$base/external/shared-lib/node_modules/is-number" || true

  if [[ $runtime_status -eq 0 ]]; then
    echo "BUG LOOKS FIXED: bun runtime unexpectedly succeeded in symlinked case" >&2
    exit 1
  fi

  if ! grep -q 'ENOENT reading ".*/external/shared-lib/node_modules/is-number"' "$base/run.log"; then
    echo "unexpected Bun runtime error in symlinked case" >&2
    exit 1
  fi

  if readlink -f "$base/external/shared-lib/node_modules/is-number" >/dev/null 2>&1; then
    echo "BUG LOOKS FIXED: broken Bun package-local symlink now resolves in symlinked case" >&2
    exit 1
  fi
}

run_bun_direct_control() {
  local base="$TMP_ROOT/bun-direct"

  setup_direct_workspace "$base"

  pushd "$base/root" >/dev/null
  bun install >"$base/install.log" 2>&1
  bun app/index.js >"$base/run.log" 2>&1
  popd >/dev/null

  say "Bun direct-directory control"
  cat "$base/install.log"
  cat "$base/run.log"
  ls -l "$base/root/repos/ext/shared-lib/node_modules/is-number"
  printf 'readlink -f: '
  readlink -f "$base/root/repos/ext/shared-lib/node_modules/is-number"

  if ! grep -qx 'true' "$base/run.log"; then
    echo "Bun direct control did not succeed" >&2
    exit 1
  fi
}

run_pnpm_symlinked_comparison() {
  local base="$TMP_ROOT/pnpm-symlinked"
  local runtime_status=0

  setup_symlinked_workspace "$base"

  cat >"$base/root/pnpm-workspace.yaml" <<'EOF'
packages:
  - app
  - repos/ext/shared-lib
EOF

  pushd "$base/root" >/dev/null
  corepack pnpm@"$PNPM_VERSION" install >"$base/install.log" 2>&1
  node app/index.js >"$base/run.log" 2>&1 || runtime_status=$?
  popd >/dev/null

  say "pnpm symlinked workspace comparison"
  cat "$base/install.log"
  cat "$base/run.log"
  printf 'external/shared-lib/node_modules exists: '
  if [[ -e "$base/external/shared-lib/node_modules" ]]; then
    echo "yes"
    find "$base/external/shared-lib/node_modules" -maxdepth 2 -type l | sed -n '1,20p'
  else
    echo "no"
  fi

  if [[ $runtime_status -eq 0 ]]; then
    echo "pnpm symlinked comparison unexpectedly succeeded; update README/issue text" >&2
    exit 1
  fi
}

run_pnpm_realpath_standalone() {
  local base="$TMP_ROOT/pnpm-standalone"

  mkdir -p "$base/pkg"

  cat >"$base/pkg/package.json" <<'EOF'
{
  "name": "standalone-lib",
  "private": true,
  "type": "module",
  "dependencies": {
    "is-number": "7.0.0"
  }
}
EOF

  cat >"$base/pkg/index.js" <<'EOF'
import isNumber from 'is-number'

console.log(isNumber(1))
EOF

  pushd "$base/pkg" >/dev/null
  corepack pnpm@"$PNPM_VERSION" install >"$base/install.log" 2>&1
  node index.js >"$base/run.log" 2>&1
  popd >/dev/null

  say "pnpm standalone real-path control"
  cat "$base/install.log"
  cat "$base/run.log"
  ls -l "$base/pkg/node_modules/is-number"
  printf 'readlink -f: '
  readlink -f "$base/pkg/node_modules/is-number"

  if ! grep -qx 'true' "$base/run.log"; then
    echo "pnpm standalone control did not succeed" >&2
    exit 1
  fi
}

say "Versions"
printf 'bun version: %s\n' "$(bun --version)"
printf 'bun revision: %s\n' "$(bun --revision)"
printf 'pnpm version: %s\n' "$(corepack pnpm@"$PNPM_VERSION" --version)"
printf 'node version: %s\n' "$(node --version)"
printf 'uname: %s\n' "$(uname -a)"

run_bun_symlinked_case
run_bun_direct_control
run_pnpm_symlinked_comparison
run_pnpm_realpath_standalone

say "Summary"
cat <<'EOF'
Verified:

1. Bun reproduces a symlinked-workspace-specific bug:
   install succeeds, then runtime fails because a package-local dependency symlink
   inside the real workspace package path is broken.
2. The same Bun workspace shape works when the workspace member is under a real
   directory instead of a symlink.
3. pnpm comparison output is included for the same aggregate symlinked shape and
   for a standalone real-path control.
EOF
