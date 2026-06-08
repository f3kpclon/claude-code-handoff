#!/usr/bin/env bash
# ── CUSTOMIZE ────────────────────────────────────────────────────────────────
THRESHOLDS=(70 80 90)
DIALOG_TITLE="Claude Code — Handoff"
DIALOG_MSG="Context at \${PCT_INT}% — generate handoff snapshot to continue in a new session?"
# ─────────────────────────────────────────────────────────────────────────────
INPUT=$(cat)

# ── Context threshold warnings ──────────────────────────────────────────────
PCT=$(cat ~/.claude/ctx_pct.txt 2>/dev/null)

SESSION=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sid = d.get('session_id') or d.get('transcript_path', '').split('/')[-1].replace('.jsonl', '')
print(sid)
" 2>/dev/null)
[ -z "$SESSION" ] && exit 0
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

touch "/tmp/handoff_w${THRESHOLD}_${SESSION}"

TITLE="$DIALOG_TITLE"
MSG=$(eval echo "$DIALOG_MSG")

case "$OSTYPE" in
  darwin*)
    ANSWER=$(osascript 2>/dev/null <<EOF
button returned of (display dialog "$MSG" buttons {"No", "Yes"} default button "Yes" with title "$TITLE")
EOF
    )
    ;;
  linux*)
    if command -v zenity &>/dev/null; then
      zenity --question --text="$MSG" --title="$TITLE" 2>/dev/null && ANSWER="Yes" || ANSWER="No"
    elif command -v kdialog &>/dev/null; then
      kdialog --yesno "$MSG" --title "$TITLE" 2>/dev/null && ANSWER="Yes" || ANSWER="No"
    else
      echo '{"decision": "block", "reason": "HANDOFF REQUESTED"}'
      exit 0
    fi
    ;;
  msys*|cygwin*|win32*)
    ANSWER=$(powershell.exe -Command "
      Add-Type -AssemblyName PresentationFramework
      \$r = [System.Windows.MessageBox]::Show('$MSG', '$TITLE', 'YesNo', 'Question')
      if (\$r -eq 'Yes') { 'Yes' } else { 'No' }
    " 2>/dev/null | tr -d '\r')
    ;;
  *)
    echo '{"decision": "block", "reason": "HANDOFF REQUESTED"}'
    exit 0
    ;;
esac

[ "$ANSWER" != "Yes" ] && exit 0

CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
GIT_LOG=$(git -C "$CWD" log --oneline -5 2>/dev/null | head -5)
GIT_STATUS=$(git -C "$CWD" status --short 2>/dev/null | head -10)

REASON="HANDOFF REQUESTED

Contexto técnico actual:
- Directorio: $CWD
- Git log:\n$GIT_LOG
- Archivos modificados:\n$GIT_STATUS"

echo "{\"decision\": \"block\", \"reason\": $(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$REASON")}"
