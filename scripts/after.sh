#!/usr/bin/env bash
# Step "after": the same tests on the current code (the workspace as it is, uncommitted changes
# included), compared with the reference screenshots from base-ref. updateSnapshots "none" never
# rewrites the reference, so a difference always fails the test and leaves a -diff image.
set -uo pipefail
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

if [ "$(cat "$VUG_TMP/before.status" 2>/dev/null)" != READY ]; then
  log "Skipping: there are no reference screenshots to compare with."
  exit 0
fi

broken() {
  echo BROKEN > "$VUG_TMP/after.status"
  printf '%s\n' "$1" > "$VUG_TMP/after.reason"
  warn "$1"
  exit 0
}

[ -f "$VUG_HEAD_ROOT/$INPUT_PLAYWRIGHT_CONFIG" ] || broken "$INPUT_PLAYWRIGHT_CONFIG does not exist in the current code."

# Reports outside the workspace: HTML for people, JSON for the summary step
export PLAYWRIGHT_HTML_OUTPUT_DIR="$VUG_TMP/report" PLAYWRIGHT_HTML_REPORT="$VUG_TMP/report"
export PLAYWRIGHT_HTML_OPEN=never PW_TEST_HTML_REPORT_OPEN=never
export PLAYWRIGHT_JSON_OUTPUT_FILE="$VUG_TMP/results.json" PLAYWRIGHT_JSON_OUTPUT_NAME="$VUG_TMP/results.json"

if ! run_side after "$VUG_HEAD_ROOT" "$VUG_REPO_ROOT" none "list,html,json"; then
  broken "The $(cat "$VUG_TMP/after.phase" 2>/dev/null || echo setup) step failed with the current code (see the log)."
fi
echo RAN > "$VUG_TMP/after.status"
log "Playwright finished with exit code $(cat "$VUG_TMP/after.test-rc" 2>/dev/null || echo unknown)"
