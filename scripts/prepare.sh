#!/usr/bin/env bash
# Resolves the folders, the package manager and the cache paths used by the next steps.
set -euo pipefail
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

fail() { echo "::error title=Visual Update Guard::$*"; exit 1; }

wd="${INPUT_WORKING_DIRECTORY:-.}"
case "$wd" in
  /*) fail "working-directory must be relative to the repository, got '$wd'." ;;
esac
head_root="${GITHUB_WORKSPACE:?}/$wd"
[ -d "$head_root" ] || fail "working-directory '$wd' does not exist. Run actions/checkout before this action."
head_root=$(cd "$head_root" && pwd -P)

case "${INPUT_PLAYWRIGHT_CONFIG:-}" in
  ''|/*) fail "playwright-config must be a path relative to working-directory." ;;
esac

repo_root=$(git -C "$head_root" rev-parse --show-toplevel 2>/dev/null) \
  || fail "'$wd' is not inside a git repository. Run actions/checkout before this action."
prefix=$(git -C "$head_root" rev-parse --show-prefix)

tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/visual-update-guard.XXXXXX")
git -C "$head_root" rev-parse HEAD > "$tmp/head.sha" 2>/dev/null || true

pm=$(detect_pm "$head_root" "$repo_root")
ensure_pm "$pm" || warn "Could not set up $pm. The install step will probably fail."

cache_dir=""
case "$pm" in
  npm) cache_dir=$(npm config get cache 2>/dev/null || true) ;;
  pnpm) cache_dir=$(cd "$head_root" && pnpm store path --silent 2>/dev/null || true) ;;
  yarn)
    if [ "$(yarn_major "$head_root")" -ge 2 ] 2>/dev/null; then
      cache_dir=$(cd "$head_root" && yarn config get cacheFolder 2>/dev/null || true)
    else
      cache_dir=$(yarn cache dir 2>/dev/null || true)
    fi ;;
esac

# Playwright version from the lockfile, so the browser cache is keyed on what it really holds
pw_version=$(node -e '
const fs = require("fs"), path = require("path");
let dir = process.argv[1];
const stop = process.argv[2];
const patterns = [
  /"node_modules\/playwright-core"\s*:\s*\{\s*"version"\s*:\s*"([^"]+)"/,
  /playwright-core@(?:npm:)?(\d+\.\d+\.\d+[^\s:"(]*)/,
];
for (;;) {
  for (const name of ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock"]) {
    const file = path.join(dir, name);
    if (!fs.existsSync(file)) continue;
    const text = fs.readFileSync(file, "utf8");
    for (const p of patterns) { const m = text.match(p); if (m) { console.log(m[1]); process.exit(0); } }
  }
  if (dir === stop || dir === path.dirname(dir)) break;
  dir = path.dirname(dir);
}' "$head_root" "$repo_root" 2>/dev/null || true)

{
  echo "tmp=$tmp"
  echo "head-root=$head_root"
  echo "repo-root=$repo_root"
  echo "prefix=$prefix"
  echo "pm=$pm"
  echo "cache-dir=$cache_dir"
  echo "playwright-version=$pw_version"
} >> "$GITHUB_OUTPUT"

log "Project: $head_root (package manager: $pm, Playwright: ${pw_version:-unknown})"
