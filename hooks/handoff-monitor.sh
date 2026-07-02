#!/usr/bin/env bash
# ── CUSTOMIZE ────────────────────────────────────────────────────────────────
THRESHOLDS=(70 80 90)
DIALOG_TITLE="Claude Code — Handoff"
# shellcheck disable=SC2016  # ${PCT_INT} is a template token, substituted below
DIALOG_MSG='Context at ${PCT_INT}% — generate handoff snapshot to continue in a new session?'
# ─────────────────────────────────────────────────────────────────────────────
INPUT=$(cat)

SESSION=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sid = d.get('session_id') or d.get('transcript_path', '').split('/')[-1].replace('.jsonl', '')
print(sid)
" 2>/dev/null)
[ -z "$SESSION" ] && exit 0

# ── Context percentage — per-session file first, legacy global as fallback ──
PCT=$(cat "$HOME/.claude/ctx/${SESSION}.pct" 2>/dev/null)
[ -z "$PCT" ] && PCT=$(cat "$HOME/.claude/ctx_pct.txt" 2>/dev/null)
[ -z "$PCT" ] && exit 0
PCT_INT=$(( ${PCT%.*} ))

THRESHOLD=0
for LEVEL in "${THRESHOLDS[@]}"; do
  if [ "$PCT_INT" -ge "$LEVEL" ] && [ ! -f "/tmp/handoff_w${LEVEL}_${SESSION}" ]; then
    THRESHOLD=$LEVEL
    break
  fi
done
[ "$THRESHOLD" -eq 0 ] && exit 0

TITLE="$DIALOG_TITLE"
MSG="${DIALOG_MSG//\$\{PCT_INT\}/$PCT_INT}"

# Headless fallback: no dialog available — suggest /handoff via systemMessage
# instead of forcing a handoff the user never approved.
suggest_handoff() {
  touch "/tmp/handoff_w${THRESHOLD}_${SESSION}"
  python3 -c "
import json
print(json.dumps({'systemMessage': '🧠 Contexto al ${PCT_INT}% — escribe /handoff para guardar un snapshot y retomar en una sesión nueva.'}))
"
  exit 0
}

case "$OSTYPE" in
  darwin*)
    # Escape backslashes and double quotes for AppleScript string literals
    MSG_AS=${MSG//\\/\\\\}; MSG_AS=${MSG_AS//\"/\\\"}
    TITLE_AS=${TITLE//\\/\\\\}; TITLE_AS=${TITLE_AS//\"/\\\"}
    ANSWER=$(osascript 2>/dev/null <<EOF
button returned of (display dialog "$MSG_AS" buttons {"No", "Yes"} default button "Yes" with title "$TITLE_AS")
EOF
    )
    ;;
  linux*)
    if command -v zenity &>/dev/null; then
      zenity --question --text="$MSG" --title="$TITLE" 2>/dev/null && ANSWER="Yes" || ANSWER="No"
    elif command -v kdialog &>/dev/null; then
      kdialog --yesno "$MSG" --title "$TITLE" 2>/dev/null && ANSWER="Yes" || ANSWER="No"
    else
      suggest_handoff
    fi
    ;;
  msys*|cygwin*|win32*)
    # Escape single quotes for PowerShell string literals
    MSG_PS=${MSG//\'/\'\'}
    TITLE_PS=${TITLE//\'/\'\'}
    ANSWER=$(powershell.exe -Command "
      Add-Type -AssemblyName PresentationFramework
      \$r = [System.Windows.MessageBox]::Show('$MSG_PS', '$TITLE_PS', 'YesNo', 'Question')
      if (\$r -eq 'Yes') { 'Yes' } else { 'No' }
    " 2>/dev/null | tr -d '\r')
    ;;
  *)
    suggest_handoff
    ;;
esac

# Consume the alert only once the user actually answered — if the hook was
# killed (timeout, closed terminal), the alert fires again on the next Stop.
[ -z "$ANSWER" ] && exit 0
touch "/tmp/handoff_w${THRESHOLD}_${SESSION}"
[ "$ANSWER" != "Yes" ] && exit 0

CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
GIT_LOG=$(git -C "$CWD" log --oneline -5 2>/dev/null | head -5)
GIT_STATUS=$(git -C "$CWD" status --short 2>/dev/null | head -10)

REASON="HANDOFF REQUESTED

Contexto técnico actual:
- Directorio: $CWD
- Git log:
$GIT_LOG
- Archivos modificados:
$GIT_STATUS"

echo "{\"decision\": \"block\", \"reason\": $(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$REASON")}"
