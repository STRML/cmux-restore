#!/usr/bin/env bash
# Install cmux-restore: symlink scripts into ~/bin and configure the Claude Code hook.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing cmux-restore..."

# --- Symlink CLI commands ---
mkdir -p "$HOME/bin"

ln -sf "$SCRIPT_DIR/scripts/save-all.sh" "$HOME/bin/cmux-save"
ln -sf "$SCRIPT_DIR/scripts/restore-all.sh" "$HOME/bin/cmux-restore"
chmod +x "$SCRIPT_DIR/scripts/"*.sh

echo "  Linked cmux-save    → ~/bin/cmux-save"
echo "  Linked cmux-restore → ~/bin/cmux-restore"

# --- Install SessionStart hook ---
HOOK_DIR="$HOME/.claude/hooks/session-restore"
mkdir -p "$HOOK_DIR"
ln -sf "$SCRIPT_DIR/scripts/on-session-start.sh" "$HOOK_DIR/on-session-start.sh"
echo "  Linked hook → ~/.claude/hooks/session-restore/on-session-start.sh"

echo ""
echo "Done! Now add this to your ~/.claude/settings.json hooks section:"
echo ""
cat <<'EOF'
  "SessionStart": [
    {
      "matcher": "*",
      "hooks": [
        {
          "type": "command",
          "command": "bash $HOME/.claude/hooks/session-restore/on-session-start.sh",
          "timeout": 5
        }
      ]
    }
  ]
EOF
echo ""
echo "Then restart Claude Code or run /hooks to apply."
echo ""
echo "Usage:"
echo "  cmux-save       # snapshot all Claude sessions before quitting cmux"
echo "  cmux-restore    # resume sessions after cmux restarts"
