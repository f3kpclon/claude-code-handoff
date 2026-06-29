#!/usr/bin/env bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')

# ── CUSTOMIZE ────────────────────────────────────────────────────────────────
THRESHOLDS="70 80 90"
DIALOG_TITLE="Claude Code — Handoff"
# shellcheck disable=SC2016
DIALOG_MSG='Context at ${PCT_INT}% — generate handoff snapshot to continue in a new session?'
CONFIRM_MSG="💾 listo mi shan!! guarda'o el handoff"
# ─────────────────────────────────────────────────────────────────────────────

echo "Installing Claude Code Handoff v${VERSION}..."
echo ""

# ── Dependency check ────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  echo "✗ python3 not found — required. Install it and retry."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "✗ jq not found — required for the status line."
  echo "  → brew install jq   or   sudo apt install jq"
  exit 1
fi

case "$OSTYPE" in
  darwin*)
    command -v osascript &>/dev/null || echo "⚠ osascript not found — dialog won't show on macOS (unexpected)"
    ;;
  linux*)
    if ! command -v zenity &>/dev/null && ! command -v kdialog &>/dev/null; then
      echo "⚠ No dialog tool found. Install zenity (GNOME) or kdialog (KDE) for native dialogs."
      echo "  → sudo apt install zenity   or   sudo apt install kdialog"
      echo "  (The system will fall back to in-chat messages without it.)"
    fi
    ;;
esac

# ── Directories ──────────────────────────────────────────────────────────────
SKILLS_DIR="$CLAUDE_DIR/skills"
mkdir -p "$COMMANDS_DIR" "$HOOKS_DIR" "$SKILLS_DIR/handoff" "$SKILLS_DIR/handoff-protocol"

# ── Files ────────────────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/commands/handoff.md"                        "$COMMANDS_DIR/handoff.md"
echo "✓ /handoff command installed"

cp "$SCRIPT_DIR/skills/handoff/SKILL.md"          "$SKILLS_DIR/handoff/SKILL.md"
cp "$SCRIPT_DIR/skills/handoff-protocol/SKILL.md" "$SKILLS_DIR/handoff-protocol/SKILL.md"
echo "✓ skills installed"

cp "$SCRIPT_DIR/hooks/statusline-context.sh"  "$HOOKS_DIR/statusline-context.sh"
cp "$SCRIPT_DIR/hooks/handoff-monitor.sh"     "$HOOKS_DIR/handoff-monitor.sh"
cp "$SCRIPT_DIR/hooks/handoff-inject.sh"      "$HOOKS_DIR/handoff-inject.sh"
cp "$SCRIPT_DIR/hooks/pre-compact.sh"         "$HOOKS_DIR/pre-compact.sh"
# Inject CUSTOMIZE values into installed files
sed -i.bak "s/^THRESHOLDS=.*/THRESHOLDS=(${THRESHOLDS})/" "$HOOKS_DIR/handoff-monitor.sh" && rm -f "$HOOKS_DIR/handoff-monitor.sh.bak"
sed -i.bak "s|^DIALOG_TITLE=.*|DIALOG_TITLE=\"${DIALOG_TITLE}\"|" "$HOOKS_DIR/handoff-monitor.sh" && rm -f "$HOOKS_DIR/handoff-monitor.sh.bak"
sed -i.bak "s|^DIALOG_MSG=.*|DIALOG_MSG='${DIALOG_MSG}'|" "$HOOKS_DIR/handoff-monitor.sh" && rm -f "$HOOKS_DIR/handoff-monitor.sh.bak"
sed -i.bak "s|^💾 .*|${CONFIRM_MSG}|" "$COMMANDS_DIR/handoff.md" && rm -f "$COMMANDS_DIR/handoff.md.bak"
chmod +x "$HOOKS_DIR/statusline-context.sh" "$HOOKS_DIR/handoff-monitor.sh" "$HOOKS_DIR/handoff-inject.sh" "$HOOKS_DIR/pre-compact.sh"
echo "✓ hooks installed (thresholds: ${THRESHOLDS})"

# ── CLAUDE.md — append or upgrade protocol ───────────────────────────────────
OLD_TRIGGER="Si el mensaje o contexto adicional contiene \`handoff\`"
NEW_TRIGGER=$(grep "Si el contexto adicional contiene" "$SCRIPT_DIR/CLAUDE.md")

if grep -q "$OLD_TRIGGER" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
  # Upgrade: replace broad keyword trigger with specific one
  sed -i.bak "s|.*${OLD_TRIGGER}.*|${NEW_TRIGGER}|" "$CLAUDE_DIR/CLAUDE.md" && rm -f "$CLAUDE_DIR/CLAUDE.md.bak"
  echo "✓ CLAUDE.md — trigger upgraded (broad → specific)"
elif grep -q "## Handoff Protocol" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
  # Upgrade: add resume trigger if missing
  if ! grep -q "Resume trigger" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
    grep -n "Resume behavior" "$CLAUDE_DIR/CLAUDE.md" | head -1  # just to locate it
    python3 - "$CLAUDE_DIR/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md" <<'PYEOF'
import sys
from pathlib import Path

dest = Path(sys.argv[1])
src  = Path(sys.argv[2])

# Extract resume trigger block from source
src_text = src.read_text()
start = src_text.find('### Resume trigger')
block = '\n' + src_text[start:].strip() + '\n'

dest_text = dest.read_text()
dest.write_text(dest_text.rstrip() + block + '\n')
PYEOF
    echo "✓ CLAUDE.md — resume trigger added"
  else
    echo "✓ CLAUDE.md — already up to date, skipped"
  fi
else
  echo "" >> "$CLAUDE_DIR/CLAUDE.md"
  cat "$SCRIPT_DIR/CLAUDE.md" >> "$CLAUDE_DIR/CLAUDE.md"
  echo "✓ CLAUDE.md updated"
fi

# ── settings.json ────────────────────────────────────────────────────────────
SETTINGS="$CLAUDE_DIR/settings.json"

# Backup before modifying
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "${SETTINGS}.bak"
fi

python3 - "$SETTINGS" <<'PYEOF'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text()) if path.exists() else {}

if 'statusLine' not in settings:
    settings['statusLine'] = {"type": "command", "command": "bash ~/.claude/hooks/statusline-context.sh"}
    print("✓ statusLine configured")
else:
    print("✓ statusLine — already present, skipped")

hooks = settings.setdefault('hooks', {})

for event, cmd in [
    ('UserPromptSubmit', 'bash ~/.claude/hooks/handoff-inject.sh'),
    ('Stop',             'bash ~/.claude/hooks/handoff-monitor.sh'),
    ('PreCompact',       'bash ~/.claude/hooks/pre-compact.sh'),
]:
    entries = hooks.setdefault(event, [])
    exists = any(h.get('command') == cmd for e in entries for h in e.get('hooks', []))
    if not exists:
        entries.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
        print(f"✓ {event} hook registered")
    else:
        print(f"✓ {event} hook — already present, skipped")

path.write_text(json.dumps(settings, indent=2) + '\n')
PYEOF

echo ""
echo "Done. Restart Claude Code to activate."
echo ""
echo "What to expect:"
echo "  • Status bar shows context usage on every response"
echo "  • At 70/80/90% a dialog asks to generate a snapshot"
echo "  • At context limit a PreCompact hook intercepts auto-compaction and triggers handoff"
echo "  • Snapshots saved to ~/.claude/handoffs/{repo-name}/ — outside the repo, never committable"
echo "  • latest.md always available for quick access"
echo "  • Snapshot content stays out of chat — one-line confirmation only"
echo "  • Paste any snapshot at the start of a new session to resume"
echo ""
echo "Manual trigger anytime: type '/handoff' or 'pausa sesión'"
echo "Uninstall: bash uninstall.sh"
