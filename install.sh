#!/usr/bin/env bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')

# ── CUSTOMIZE ────────────────────────────────────────────────────────────────
# Dónde ofrecer el handoff. El último aviso NO va acá: se calcula solo contra el
# punto de auto-compact real de la ventana (ver hooks/handoff-monitor.sh).
THRESHOLDS="60 75"
# Los mismos cortes en tokens absolutos — degradación no escala con la ventana.
TOKEN_THRESHOLDS="120000 150000"
# Opus aguanta más (Anthropic: 93% a 256K vs 18,5% de Sonnet 4.5 a 1M).
TOKEN_THRESHOLDS_OPUS="192000 256000"
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
# Skills ARE slash commands — skills/handoff creates /handoff. The separate
# commands/handoff.md was removed in v0.3; drop it from old installs so it
# doesn't shadow the skill.
rm -f "$COMMANDS_DIR/handoff.md"

cp "$SCRIPT_DIR/skills/handoff/SKILL.md"          "$SKILLS_DIR/handoff/SKILL.md"
cp "$SCRIPT_DIR/skills/handoff-protocol/SKILL.md" "$SKILLS_DIR/handoff-protocol/SKILL.md"
echo "✓ skills installed (/handoff + handoff-protocol)"

cp "$SCRIPT_DIR/hooks/statusline-context.sh"  "$HOOKS_DIR/statusline-context.sh"
cp "$SCRIPT_DIR/hooks/handoff-monitor.sh"     "$HOOKS_DIR/handoff-monitor.sh"
cp "$SCRIPT_DIR/hooks/pre-compact.sh"         "$HOOKS_DIR/pre-compact.sh"
rm -f "$HOOKS_DIR/handoff-inject.sh"  # removed in v0.3 — dead code from old architecture
# Inject CUSTOMIZE values into installed files — literal replacement via python3,
# NOT sed. A value containing | & or \ silently corrupts sed's s///; python does
# byte-literal replacement and shlex.quote emits valid bash for any content
# (embedded quotes, $, spaces), while preserving the literal ${PCT_INT} token.
HANDOFF_THRESHOLDS="$THRESHOLDS" \
HANDOFF_TOKEN_THRESHOLDS="$TOKEN_THRESHOLDS" \
HANDOFF_TOKEN_THRESHOLDS_OPUS="$TOKEN_THRESHOLDS_OPUS" \
HANDOFF_DIALOG_TITLE="$DIALOG_TITLE" \
HANDOFF_DIALOG_MSG="$DIALOG_MSG" \
HANDOFF_CONFIRM_MSG="$CONFIRM_MSG" \
python3 - "$HOOKS_DIR/handoff-monitor.sh" "$SKILLS_DIR/handoff/SKILL.md" <<'PYEOF'
import os, shlex, sys
from pathlib import Path

monitor, skill = Path(sys.argv[1]), Path(sys.argv[2])

def replace_line(path, prefix, new_line):
    lines = path.read_text().splitlines()
    for i, l in enumerate(lines):
        if l.startswith(prefix):
            lines[i] = new_line
            break
    else:
        sys.stderr.write(f"⚠ no line starting with {prefix!r} in {path}\n")
    path.write_text('\n'.join(lines) + '\n')

thresholds = os.environ['HANDOFF_THRESHOLDS']
replace_line(monitor, 'THRESHOLDS=',   f'THRESHOLDS=({thresholds})')
# Antes que TOKEN_THRESHOLDS no: replace_line matchea por prefijo y 'THRESHOLDS='
# no es prefijo de 'TOKEN_THRESHOLDS=', así que el orden acá da igual — pero el
# de arriba sí debe correr sobre la línea propia, no sobre la de tokens.
replace_line(monitor, 'TOKEN_THRESHOLDS=', f'TOKEN_THRESHOLDS=({os.environ["HANDOFF_TOKEN_THRESHOLDS"]})')
replace_line(monitor, 'TOKEN_THRESHOLDS_OPUS=', f'TOKEN_THRESHOLDS_OPUS=({os.environ["HANDOFF_TOKEN_THRESHOLDS_OPUS"]})')
replace_line(monitor, 'DIALOG_TITLE=', f'DIALOG_TITLE={shlex.quote(os.environ["HANDOFF_DIALOG_TITLE"])}')
replace_line(monitor, 'DIALOG_MSG=',   f'DIALOG_MSG={shlex.quote(os.environ["HANDOFF_DIALOG_MSG"])}')
replace_line(skill,   '💾 ',           os.environ['HANDOFF_CONFIRM_MSG'])
PYEOF
chmod +x "$HOOKS_DIR/statusline-context.sh" "$HOOKS_DIR/handoff-monitor.sh" "$HOOKS_DIR/pre-compact.sh"
echo "✓ hooks installed (thresholds: ${THRESHOLDS} · tokens: ${TOKEN_THRESHOLDS} · opus: ${TOKEN_THRESHOLDS_OPUS})"

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

python3 - "$SETTINGS" <<'PYEOF'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text()) if path.exists() else {}

# statusLine: handoff-monitor depends on ctx_pct written by OUR statusline.
# A foreign statusline means threshold alerts silently never fire — refuse to
# pretend the install worked in that case (verification below reports it).
OURS = 'statusline-context.sh'
# refreshInterval is what makes the 5h countdown tick. Without it Claude Code
# only re-renders the statusline after each assistant message, so the countdown
# freezes between messages and reads as a broken clock. 10s is deliberate: the
# countdown has minute resolution, so 1s would pay 10x the process cost every
# second for a digit that cannot change.
SL_CFG = {"type": "command",
          "command": "bash ~/.claude/hooks/statusline-context.sh",
          "refreshInterval": 10}
sl = settings.get('statusLine')
if sl is None:
    settings['statusLine'] = dict(SL_CFG)
    print("✓ statusLine configured (refreshInterval=10)")
elif OURS in sl.get('command', ''):
    # Upgrade path for installs predating the countdown. An interval the user
    # already chose is theirs — never overwrite it.
    if 'refreshInterval' not in sl:
        sl['refreshInterval'] = 10
        print("✓ statusLine — ours; added refreshInterval=10 for the live countdown")
    else:
        print("✓ statusLine — already ours, skipped (refreshInterval=%s kept)" % sl['refreshInterval'])
elif __import__('os').environ.get('HANDOFF_FORCE_STATUSLINE') == '1':
    settings['statusLine'] = dict(SL_CFG)
    print("✓ statusLine replaced (HANDOFF_FORCE_STATUSLINE=1)")
else:
    print("⚠ statusLine — a different statusline is configured; NOT replaced")

hooks = settings.setdefault('hooks', {})

# Drop stale registrations from pre-v0.3 installs (handoff-inject.sh removed)
STALE = 'bash ~/.claude/hooks/handoff-inject.sh'
for event in list(hooks):
    pruned = [e for e in hooks[event]
              if not any(h.get('command') == STALE for h in e.get('hooks', []))]
    if len(pruned) != len(hooks[event]):
        print(f"✓ {event} — stale handoff-inject.sh registration removed")
    if pruned:
        hooks[event] = pruned
    else:
        del hooks[event]

for event, cmd in [
    ('Stop',       'bash ~/.claude/hooks/handoff-monitor.sh'),
    ('PreCompact', 'bash ~/.claude/hooks/pre-compact.sh'),
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

# ── Hook verification ────────────────────────────────────────────────────────
echo ""
echo "Verifying hook registration..."
python3 - "$SETTINGS" <<'PYEOF'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text()) if path.exists() else {}
hooks = settings.get('hooks', {})

checks = [
    ('Stop',       'bash ~/.claude/hooks/handoff-monitor.sh'),
    ('PreCompact', 'bash ~/.claude/hooks/pre-compact.sh'),
]

all_ok = True
for event, cmd in checks:
    entries = hooks.get(event, [])
    found = any(h.get('command') == cmd for e in entries for h in e.get('hooks', []))
    status = '✓' if found else '✗ MISSING'
    print(f"  {status}  {event} → {cmd.split('/')[-1]}")
    if not found:
        all_ok = False

# statusLine is load-bearing: without our script, ctx_pct is never written and
# the Stop hook exits silently on every response — the alert system is dead.
sl_cmd = settings.get('statusLine', {}).get('command', '')
if 'statusline-context.sh' in sl_cmd:
    print("  ✓  statusLine        → statusline-context.sh")
else:
    all_ok = False
    print("  ✗  statusLine        → NOT ours — threshold alerts will NEVER fire")
    print("")
    print("  handoff-monitor.sh reads the context %% that only our statusline writes.")
    print("  Fix one of two ways:")
    print("    1. Replace your statusline:  HANDOFF_FORCE_STATUSLINE=1 bash install.sh")
    print("    2. Keep yours, but add this line to your statusline script:")
    print("       echo \"$used\" > ~/.claude/ctx_pct.txt   # $used = context used_percentage")

if not all_ok:
    print("")
    print("  Run 'bash install.sh' again after fixing the above.")
    sys.exit(1)
PYEOF

echo ""
echo "Done. Restart Claude Code to activate."
echo ""
echo "What to expect:"
echo "  • Status bar shows context usage on every response"
# Derivado de $THRESHOLDS, NO escrito a mano: este texto ya quedó mintiendo una
# vez (decía 70/80/90 después de que los cortes bajaran a 60/75) y nadie se
# entera, porque el installer imprime igual de convencido con el número viejo.
echo "  • At ${THRESHOLDS// //}% — and again just before auto-compaction — a dialog asks to generate a snapshot"
echo "  • At context limit PreCompact saves a snapshot and allows compaction to continue"
echo "  • Snapshots saved to ~/.claude/handoffs/{repo-name}/ — outside the repo, never committable"
echo "  • latest.md always available for quick access"
echo "  • Snapshot content stays out of chat — one-line confirmation only"
echo "  • Paste any snapshot at the start of a new session to resume"
echo ""
echo "Re-install is safe to run at any time — use it to repair hooks after other tools modify settings.json."
echo "Manual trigger anytime: type '/handoff' or 'pausa sesión'"
echo "Uninstall: bash uninstall.sh"
