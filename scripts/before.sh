#!/usr/bin/env bash
# Step "before": screenshots of base-ref. They are taken in a separate git worktree, so the workspace
# (the "after" side) is never switched to another branch, and they are written to a folder outside git.
# Any problem here ends as UNAVAILABLE without failing the job.
set -uo pipefail
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

unavailable() {
  echo UNAVAILABLE > "$VUG_TMP/before.status"
  printf '%s\n' "$1" > "$VUG_TMP/before.reason"
  warn "No reference screenshots: $1"
  exit 0
}

base_ref="${INPUT_BASE_REF:-}"
[ -n "$base_ref" ] || unavailable "base-ref is empty."
cd "$VUG_REPO_ROOT" || unavailable "the repository folder is missing."

# 1. Find the base commit. HEAD-relative refs and commit SHAs are read locally; branch and tag names
#    are fetched first so they are never stale
base_sha=""
case "$base_ref" in
  HEAD|HEAD~*|HEAD^*) base_sha=$(git rev-parse --verify --quiet "$base_ref^{commit}" || true) ;;
esac
if [ -z "$base_sha" ] && [[ "$base_ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  base_sha=$(git rev-parse --verify --quiet "$base_ref^{commit}" || true)
fi
if [ -z "$base_sha" ]; then
  depth=""
  # Only a shallow clone gets a shallow fetch: a full clone must stay full for the steps after this one
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ] && depth="--depth=1"
  # shellcheck disable=SC2086
  if git fetch --no-tags $depth origin "$base_ref" >/dev/null 2>&1; then
    base_sha=$(git rev-parse FETCH_HEAD)
  else
    base_sha=$(git rev-parse --verify --quiet "$base_ref^{commit}" \
      || git rev-parse --verify --quiet "origin/$base_ref^{commit}" || true)
  fi
fi
[ -n "$base_sha" ] || unavailable "could not find '$base_ref' (not on the remote, and not in the local clone)."
echo "$base_sha" > "$VUG_TMP/base.sha"
log "Base: $base_ref ($base_sha)"

# 2. Check it out next to the workspace, not in it
git worktree add --detach "$VUG_TMP/base" "$base_sha" >/dev/null 2>&1 \
  || unavailable "could not check out '$base_ref' into a separate worktree."
if [ -f "$VUG_TMP/base/.gitmodules" ]; then
  git -C "$VUG_TMP/base" submodule update --init --recursive --depth=1 >/dev/null 2>&1 \
    || warn "Could not check out the submodules of '$base_ref'."
fi

base_root="$VUG_TMP/base/${VUG_PREFIX:-}"
[ -d "$base_root" ] || unavailable "working-directory does not exist on '$base_ref'."
[ -f "$base_root/$INPUT_PLAYWRIGHT_CONFIG" ] || unavailable "$INPUT_PLAYWRIGHT_CONFIG does not exist on '$base_ref'."

# 3. Install, set up, build and screenshot. updateSnapshots "all" writes every screenshot, because the
#    reference folder starts empty
mkdir -p "$VUG_TMP/reference"
if ! run_side before "${base_root%/}" "$VUG_TMP/base" all list; then
  unavailable "the $(cat "$VUG_TMP/before.phase" 2>/dev/null || echo setup) step failed on '$base_ref' (see the log)."
fi
rc=$(cat "$VUG_TMP/before.test-rc" 2>/dev/null || echo 1)
[ "$rc" = 0 ] || unavailable "the Playwright tests failed on '$base_ref', so its screenshots cannot be a reference."

count=$(find "$VUG_TMP/reference" -type f | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || unavailable "the tests on '$base_ref' took no screenshots (no toHaveScreenshot or toMatchSnapshot)."

echo "$count" > "$VUG_TMP/reference.count"
echo READY > "$VUG_TMP/before.status"
log "Reference ready: $count snapshots from $base_ref"
