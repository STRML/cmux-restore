#!/usr/bin/env bash
# Restore Claude sessions into cmux surfaces after a restart.
#
# Finds saved surface titles in the current cmux tree (titles persist across restarts).
# For each matched surface, sends `claude --continue` which resumes the most recent
# session for that project directory.
#
# Usage:
#   cmux-restore              # restore all (refuses if claude already running)
#   cmux-restore --dry-run    # preview what would be restored
#   cmux-restore --force      # restore even if some claude processes exist
set -euo pipefail

DRY_RUN=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true ;;
  esac
done

SNAPSHOT_FILE="$HOME/.claude/cmux-snapshot.json"

if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "No snapshot found at $SNAPSHOT_FILE"
  echo "Run cmux-save first."
  exit 1
fi

SNAPSHOT=$(cat "$SNAPSHOT_FILE")
SNAP_TS=$(echo "$SNAPSHOT" | jq -r '.timestamp')
NOW=$(date +%s)
AGE_MIN=$(( (NOW - SNAP_TS) / 60 ))
AGE_HR=$(( AGE_MIN / 60 ))
AGE_MIN_REM=$(( AGE_MIN % 60 ))
if [ "$AGE_HR" -gt 0 ]; then
  echo "Snapshot from ${AGE_HR}h ${AGE_MIN_REM}m ago"
else
  echo "Snapshot from ${AGE_MIN}m ago"
fi

# --- Check for running Claude processes ---
CLAUDE_COUNT=$(ps -eo comm | grep -c '^claude$' || true)
if [ "$CLAUDE_COUNT" -gt 0 ] && ! $FORCE && ! $DRY_RUN; then
  echo ""
  echo "$CLAUDE_COUNT Claude process(es) already running."
  echo ""
  echo "Options:"
  echo "  --force      restore anyway"
  echo "  --dry-run    preview without restoring"
  exit 1
fi

# --- Load current cmux tree ---
echo "Reading cmux tree..."
CURRENT=$(cmux tree --all --json 2>/dev/null | jq '[
  .windows[]?.workspaces[]? |
  .title as $ws |
  .panes[]? |
  .surfaces[]? |
  {ref: .ref, title: .title, workspace: $ws}
]') || { echo "cmux not available"; exit 1; }

# --- Load saved surfaces ---
SAVED_SURFACES=$(echo "$SNAPSHOT" | jq '.surfaces')

echo ""
echo "Surfaces to restore: $(echo "$SAVED_SURFACES" | jq 'length')"
echo ""

RESTORED=0
SKIPPED=0
FAILED=0
CLAIMED_REFS=""

for row in $(echo "$SAVED_SURFACES" | jq -r '.[] | @base64'); do
  S=$(echo "$row" | base64 -d)
  title=$(echo "$S" | jq -r '.title')
  old_ws=$(echo "$S" | jq -r '.workspace')

  # Find this title in the current tree (skip already-claimed refs)
  MATCH=""
  for mrow in $(echo "$CURRENT" | jq -r --arg t "$title" '[.[] | select(.title == $t)] | .[] | @base64'); do
    M=$(echo "$mrow" | base64 -d)
    mref=$(echo "$M" | jq -r '.ref')
    if ! echo "$CLAIMED_REFS" | grep -qF "$mref"; then
      MATCH="$M"
      break
    fi
  done

  if [ -z "$MATCH" ]; then
    echo "  MISS  [$old_ws] $title"
    FAILED=$((FAILED + 1))
    continue
  fi

  target_ref=$(echo "$MATCH" | jq -r '.ref')
  cur_ws=$(echo "$MATCH" | jq -r '.workspace')
  CLAIMED_REFS="$CLAIMED_REFS $target_ref"

  if $DRY_RUN; then
    echo "  DRY   [$cur_ws] $title → $target_ref — claude --continue"
  else
    if timeout 5 cmux send --surface "$target_ref" "claude --continue" 2>/dev/null; then
      timeout 5 cmux send-key --surface "$target_ref" Enter 2>/dev/null
      echo "  OK    [$cur_ws] $title → $target_ref"
      RESTORED=$((RESTORED + 1))
    else
      echo "  FAIL  [$cur_ws] $title → $target_ref — send failed"
      FAILED=$((FAILED + 1))
    fi
  fi
done

echo ""
if $DRY_RUN; then
  echo "Dry run complete. Run without --dry-run to restore."
else
  echo "Restored: $RESTORED  Skipped: $SKIPPED  Failed: $FAILED"
fi
