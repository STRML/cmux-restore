#!/usr/bin/env bash
# Restore Claude sessions into cmux surfaces after a restart.
#
# Reads the saved snapshot which maps surface UUIDs → session IDs.
# UUIDs persist across cmux restarts, so we send `claude --resume <id>`
# directly to each surface by UUID — no position matching or screen
# parsing needed.
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
  echo "After a full restart, this should be 0."
  echo ""
  echo "Options:"
  echo "  --force      restore anyway (skips surfaces with live Claude)"
  echo "  --dry-run    preview without restoring"
  exit 1
fi

# Build set of surface UUIDs that currently have Claude running
BUSY_UUIDS=""
if [ "$CLAUDE_COUNT" -gt 0 ]; then
  for pid in $(ps -eo pid,comm | awk '$2 == "claude" {print $1}'); do
    uuid=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep "^CMUX_SURFACE_ID=" | cut -d= -f2) || true
    [ -n "$uuid" ] && BUSY_UUIDS="$BUSY_UUIDS $uuid"
  done
fi

# --- Restore each session ---
SESSIONS=$(echo "$SNAPSHOT" | jq -r '.sessions')
TOTAL=$(echo "$SESSIONS" | jq 'length')
echo ""
echo "Sessions to restore: $TOTAL"
echo ""

RESTORED=0
SKIPPED=0

for row in $(echo "$SESSIONS" | jq -r '.[] | @base64'); do
  S=$(echo "$row" | base64 -d)
  uuid=$(echo "$S" | jq -r '.surface_uuid')
  cwd=$(echo "$S" | jq -r '.cwd')
  sid=$(echo "$S" | jq -r '.session_id')
  dir=$(basename "$cwd")

  # Skip if Claude is already running in this surface
  if echo "$BUSY_UUIDS" | grep -qF "$uuid"; then
    echo "  LIVE  $dir — Claude already running, skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if $DRY_RUN; then
    echo "  DRY   $dir — cd \"$cwd\" && claude --resume ${sid:0:8}..."
  else
    # Send cd + claude --resume to the surface by UUID
    cmux send --surface "$uuid" "cd \"$cwd\" && claude --resume $sid" 2>/dev/null
    if [ $? -eq 0 ]; then
      cmux send-key --surface "$uuid" Enter 2>/dev/null
      echo "  OK    $dir — resumed ${sid:0:8}..."
      RESTORED=$((RESTORED + 1))
    else
      echo "  FAIL  $dir — surface $uuid not found"
      SKIPPED=$((SKIPPED + 1))
    fi
  fi
done

echo ""
if $DRY_RUN; then
  echo "Dry run complete. Run without --dry-run to restore."
else
  echo "Restored: $RESTORED  Skipped: $SKIPPED"
fi
