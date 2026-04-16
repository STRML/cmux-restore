#!/usr/bin/env bash
# Claude Code SessionEnd hook: remove the surface entry from saved state.
#
# Runs when a Claude session exits (user quits or session ends for any reason).
# Removes the matching by_surface entry so the next snapshot doesn't include a
# dead session — otherwise cmux-restore would re-launch `claude` in a surface
# the user had intentionally closed.
#
# State file: ~/.claude/saved-sessions.json
set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$SESSION_ID" ] && exit 0

STATE_FILE="$HOME/.claude/saved-sessions.json"
SURFACE_ID="${CMUX_SURFACE_ID:-${ITERM_SESSION_ID:-unknown}}"

[ -f "$STATE_FILE" ] || exit 0
STATE=$(cat "$STATE_FILE")

# Delete by surface_id first (most specific), then by matching session_id as fallback.
STATE=$(echo "$STATE" | jq \
  --arg surface "$SURFACE_ID" \
  --arg sid "$SESSION_ID" \
  --arg cwd "$CWD" \
  '
  .by_surface = (.by_surface // {} | with_entries(select(
    .key != $surface and .value.session_id != $sid
  ))) |
  .by_cwd = (.by_cwd // {} | with_entries(select(
    .value.session_id != $sid
  )))')

echo "$STATE" > "$STATE_FILE"

# --- Refresh snapshot (backgrounded) ---
(
  NOW=$(date +%s)
  SNAPSHOT_FILE="$HOME/.claude/cmux-snapshot.json"
  TREE=$(cmux tree --all --json 2>/dev/null) || exit 0
  STATE_NOW=$(cat "$STATE_FILE")
  SURFACES=$(jq -n \
    --argjson tree "$TREE" \
    --argjson state "$STATE_NOW" \
    '
    [$tree.windows[]?.workspaces[]? |
     {ws_title: .title, ws_ref: .ref} as $ws |
     .panes[]?.surfaces[]? |
     {ref: .ref, title: .title, workspace: $ws.ws_title, workspace_ref: $ws.ws_ref}
    ] as $tree_surfaces |
    [$state.by_surface | to_entries[] |
     .value as $s |
     ($tree_surfaces[] | select(.ref == $s.surface_ref)) as $ts |
     {ref: $ts.ref, title: $ts.title, workspace: $ts.workspace,
      workspace_ref: $ts.workspace_ref, session_id: $s.session_id, cwd: $s.cwd}
    ]')
  SESSIONS=$(echo "$STATE_NOW" | jq '[.by_surface | to_entries[] | .value | {cwd, session_id}]')
  jq -n \
    --argjson ts "$NOW" \
    --argjson sessions "$SESSIONS" \
    --argjson surfaces "$SURFACES" \
    '{timestamp: $ts, sessions: $sessions, surfaces: $surfaces}' > "$SNAPSHOT_FILE"
) &

exit 0
