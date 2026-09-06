#!/usr/bin/env bash
# ── CUSTOMIZE ────────────────────────────────────────────────────────────────
# Dónde ofrecer el handoff. Bajados desde (70 80 90) con evidencia: la calidad
# empieza a caer mucho antes de que se llene la ventana, y el 90 era inalcanzable
# en 200k porque el auto-compact dispara antes (~83%) — nunca disparó.
# El último corte se recalcula solo contra el compact real: ver CRIT abajo.
THRESHOLDS=(60 75)
# Los mismos cortes, en tokens absolutos. La degradación del razonamiento no
# escala con el tamaño de ventana: en 1M el 60% son 600,000 tokens, cuatro veces
# pasado el punto donde ya conviene cortar. Calibrados sobre 200k (60%=120k,
# 75%=150k), así que ahí no cambia nada y en 1M mandan estos.
TOKEN_THRESHOLDS=(120000 150000)
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

# Per-user sentinel dir — NOT /tmp. A predictable /tmp/handoff_wNN_<sid> path is
# world-writable: another local user could pre-create it (suppress alerts) or
# point it at a symlink. ~/.claude/ is owned by us and already holds ctx state.
SENTINEL_DIR="$HOME/.claude/ctx"
mkdir -p "$SENTINEL_DIR"

# ── Context percentage — per-session file first, legacy global as fallback ──
PCT=$(cat "$HOME/.claude/ctx/${SESSION}.pct" 2>/dev/null)
[ -z "$PCT" ] && PCT=$(cat "$HOME/.claude/ctx_pct.txt" 2>/dev/null)
[ -z "$PCT" ] && exit 0
PCT_INT=$(( ${PCT%.*} ))

# ── Último aviso, anclado al compact real ────────────────────────────────────
# La statusline deja el % de compactación de ESTA ventana en .compact (200k y
# 1M compactan en puntos muy distintos). Un umbral por encima de ese punto no
# dispara nunca — es exactamente el bug que tenía el 90 fijo — así que se
# descartan los inalcanzables y se agrega uno 2 puntos antes del compact.
# Sin el archivo (statusline no instalada) se usa 83, el valor medido en 200k.
COMPACT_PCT=$(cat "$SENTINEL_DIR/${SESSION}.compact" 2>/dev/null)
case "$COMPACT_PCT" in ''|*[!0-9]*) COMPACT_PCT=83 ;; esac
CRIT=$(( COMPACT_PCT - 2 ))

USABLE=()
for LEVEL in "${THRESHOLDS[@]}"; do
  [ "$LEVEL" -lt "$CRIT" ] && USABLE+=("$LEVEL")
done
USABLE+=("$CRIT")

# Tokens en contexto, que la statusline deja en <sid>.tok. Sin el archivo se
# queda en 0 y los cortes por token simplemente no participan: en 200k el
# resultado es el mismo, y es mejor que inventar un conteo.
TOK=$(cat "$SENTINEL_DIR/${SESSION}.tok" 2>/dev/null)
case "$TOK" in ''|*[!0-9]*) TOK=0 ;; esac

# Cada nivel dispara por porcentaje O por tokens, lo que ocurra primero. El
# sentinel se nombra por el nivel de porcentaje en ambos casos, así que un
# mismo tramo no puede avisar dos veces por dos vías distintas.
THRESHOLD=0
IDX=0
for LEVEL in "${USABLE[@]}"; do
  TOK_LEVEL=0
  [ "$IDX" -lt "${#TOKEN_THRESHOLDS[@]}" ] && TOK_LEVEL="${TOKEN_THRESHOLDS[$IDX]}"
  IDX=$(( IDX + 1 ))
  [ -f "$SENTINEL_DIR/handoff_w${LEVEL}_${SESSION}" ] && continue
  if [ "$PCT_INT" -ge "$LEVEL" ] || { [ "$TOK_LEVEL" -gt 0 ] && [ "$TOK" -ge "$TOK_LEVEL" ]; }; then
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
  touch "$SENTINEL_DIR/handoff_w${THRESHOLD}_${SESSION}"
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
touch "$SENTINEL_DIR/handoff_w${THRESHOLD}_${SESSION}"
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
