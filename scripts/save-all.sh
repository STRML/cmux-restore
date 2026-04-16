#!/usr/bin/env bash
# Save all current Claude sessions from cmux for later restoration.
#
# Saves two lists:
# 1. Claude processes: {cwd, session_id} — from ps + lsof + hook state
# 2. Claude surfaces: {title, ref, workspace} — from cmux tree
#
# These are paired at restore time by matching surface titles to surfaces
# in the (possibly restarted) cmux tree.
#
# Output: ~/.claude/cmux-snapshot.json
set -euo pipefail

SNAPSHOT_FILE="$HOME/.claude/cmux-snapshot.json"
STATE_FILE="$HOME/.claude/saved-sessions.json"
NOW=$(date +%s)

# --- Load hook-saved state ---
HOOK_DATA='{}'
if [ -f "$STATE_FILE" ]; then
  HOOK_DATA=$(jq '.by_surface // {}' "$STATE_FILE")
fi

# --- Get cmux tree (with UUIDs for matching to ps env) ---
echo "Reading cmux tree..."
TREE=$(cmux --id-format both tree --all --json 2>/dev/null) || { echo "cmux not available"; exit 1; }

echo "Scanning Claude processes..."

# --- Collect per-surface session info from running Claude procs + hook state ---
# Keyed by UUID from CMUX_SURFACE_ID env var on each claude process,
# which we then map to cmux ref via the tree (UUID stable within a cmux session).
SESSIONS='[]'
SEEN_UUIDS=""

for pid in $(ps -eo pid,comm | awk '$2 == "claude" {print $1}'); do
  cwd=$(lsof -p "$pid" -Fn 2>/dev/null | grep -A1 "^fcwd" | grep "^n" | sed 's/^n//') || true
  [ -z "$cwd" ] && continue

  uuid=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep "^CMUX_SURFACE_ID=" | cut -d= -f2) || true
  [ -z "$uuid" ] && continue
  echo "$SEEN_UUIDS" | grep -qF "$uuid" && continue
  SEEN_UUIDS="$SEEN_UUIDS $uuid"

  sid=$(echo "$HOOK_DATA" | jq -r --arg u "$uuid" '.[$u].session_id // empty')
  # Fallback: newest session file in project dir
  if [ -z "$sid" ]; then
    proj=$(echo "$cwd" | sed 's|/|-|g')
    sid=$(ls -t "$HOME/.claude/projects/$proj"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl 2>/dev/null) || true
  fi
  [ -z "$sid" ] && continue

  SESSIONS=$(echo "$SESSIONS" | jq \
    --arg cwd "$cwd" --arg sid "$sid" --arg uuid "$uuid" \
    '. + [{cwd: $cwd, session_id: $sid, surface_uuid: $uuid}]')
done

# --- Build surfaces: map each session's surface_uuid → tree surface (ref/title) ---
SURFACES=$(jq -n \
  --argjson tree "$TREE" \
  --argjson sessions "$SESSIONS" \
  '
  [$tree.windows[]?.workspaces[]? |
   {ws_title: .title, ws_ref: .ref} as $ws |
   .panes[]?.surfaces[]? |
   {id: .id, ref: .ref, title: .title, workspace: $ws.ws_title, workspace_ref: $ws.ws_ref}
  ] as $tree_surfaces |
  [$sessions[] |
   . as $s |
   ($tree_surfaces[] | select(.id == $s.surface_uuid)) as $ts |
   select($ts != null) |
   {ref: $ts.ref, title: $ts.title, workspace: $ts.workspace,
    workspace_ref: $ts.workspace_ref, session_id: $s.session_id, cwd: $s.cwd}
  ]')

COUNT=$(echo "$SESSIONS" | jq 'length')
SURF_COUNT=$(echo "$SURFACES" | jq 'length')
echo "Found $COUNT running Claude session(s) across $SURF_COUNT surface(s)"

jq -n \
  --argjson ts "$NOW" \
  --argjson sessions "$SESSIONS" \
  --argjson surfaces "$SURFACES" \
  '{timestamp: $ts, sessions: $sessions, surfaces: $surfaces}' > "$SNAPSHOT_FILE"

echo ""
echo "Snapshot saved to $SNAPSHOT_FILE"

# Rotate tiered backups (5 hourly + 5 daily + 2 weekly).
bash "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/rotate-snapshot-backups.sh" >/dev/null 2>&1 || true

echo ""
echo "Surfaces:"
echo "$SURFACES" | jq -r '.[] | "  [\(.workspace)] \(.title)  →  \(.session_id | .[0:8])..."'
