#!/usr/bin/env bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Uninstalling Claude Code Handoff..."
echo ""

# ── Remove hooks ─────────────────────────────────────────────────────────────
for f in handoff-monitor.sh handoff-inject.sh statusline-context.sh pre-compact.sh; do
  if [ -f "$CLAUDE_DIR/hooks/$f" ]; then
    rm "$CLAUDE_DIR/hooks/$f"
    echo "✓ removed hooks/$f"
  fi
done

# ── Remove command ────────────────────────────────────────────────────────────
if [ -f "$CLAUDE_DIR/commands/handoff.md" ]; then
  rm "$CLAUDE_DIR/commands/handoff.md"
  echo "✓ removed commands/handoff.md"
fi

# ── Remove skills ─────────────────────────────────────────────────────────────
for skill in handoff handoff-protocol; do
  if [ -d "$CLAUDE_DIR/skills/$skill" ]; then
    rm -rf "$CLAUDE_DIR/skills/$skill"
    echo "✓ removed skills/$skill"
  fi
done

# ── Restore settings.json ─────────────────────────────────────────────────────
if [ -f "${SETTINGS}.bak" ]; then
  mv "${SETTINGS}.bak" "$SETTINGS"
  echo "✓ settings.json restored from backup"
elif [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PYEOF'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text())

settings.pop('statusLine', None)

hooks = settings.get('hooks', {})
for event, cmd in [
    ('UserPromptSubmit', 'bash ~/.claude/hooks/handoff-inject.sh'),
    ('Stop',             'bash ~/.claude/hooks/handoff-monitor.sh'),
    ('PreCompact',       'bash ~/.claude/hooks/pre-compact.sh'),
]:
    entries = hooks.get(event, [])
    filtered = [e for e in entries if not any(h.get('command') == cmd for h in e.get('hooks', []))]
    if filtered:
        hooks[event] = filtered
    elif event in hooks:
        del hooks[event]

path.write_text(json.dumps(settings, indent=2) + '\n')
print("✓ settings.json cleaned")
PYEOF
fi

# ── Remove Handoff Protocol block from CLAUDE.md ─────────────────────────────
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
if [ -f "$CLAUDE_MD" ] && grep -q "## Handoff Protocol" "$CLAUDE_MD"; then
  python3 - "$CLAUDE_MD" <<'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()

out = []
skip = False
for line in lines:
    if line.strip() == '## Handoff Protocol':
        skip = True
        # Remove trailing blank line before the block
        while out and out[-1].strip() == '':
            out.pop()
        continue
    if skip and line.startswith('## ') and line.strip() != '## Handoff Protocol':
        skip = False
    if not skip:
        out.append(line)

path.write_text('\n'.join(out).rstrip() + '\n')
print("✓ CLAUDE.md — Handoff Protocol block removed")
PYEOF
fi

echo ""
echo "Done. Restart Claude Code to deactivate."
echo ""
echo "Note: snapshots in ~/.claude/handoffs/ were not deleted."
