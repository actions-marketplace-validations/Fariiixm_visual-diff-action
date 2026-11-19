#!/usr/bin/env bash
# Leaves the workspace as it was: removes the generated config files and the base worktree.
# The reports stay in RUNNER_TEMP, which the runner empties at the end of the job.
set -uo pipefail

[ -n "${VUG_TMP:-}" ] && [ -d "$VUG_TMP" ] || exit 0

if [ -f "$VUG_TMP/wrappers.txt" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] && rm -f -- "$file"
  done < "$VUG_TMP/wrappers.txt"
fi

if [ -d "$VUG_TMP/base" ] && [ -n "${VUG_REPO_ROOT:-}" ]; then
  git -C "$VUG_REPO_ROOT" worktree remove --force "$VUG_TMP/base" >/dev/null 2>&1 || rm -rf "$VUG_TMP/base"
  git -C "$VUG_REPO_ROOT" worktree prune >/dev/null 2>&1 || true
fi
