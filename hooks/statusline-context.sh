#!/usr/bin/env bash
# ── CUSTOMIZE ────────────────────────────────────────────────────────────────
# Contexto de sesión
L90_DOT="🆘"; L90_MSG="handoff altiro weón"
L80_DOT="💀"; L80_MSG="¿qué hacíamos?"
L70_DOT="🔪"; L70_MSG="me pase po"
L60_DOT="👻"; L60_MSG="en cualquier momento me voy en la vola'"
L50_DOT="🔥"; L50_MSG="se calienta la cosa"
L30_DOT="😎"; L30_MSG="tranqui"
L00_DOT="😈"; L00_MSG="listo mi guasho! estamo' entero activa'os"

# Cupo horario (ventana 5h rolling)
RH90_DOT="🆘"; RH90_MSG="quedando pato weón! al 100 no money no honey"
RH80_DOT="💀"; RH80_MSG="casi sin cupo horario"
RH70_DOT="🔪"; RH70_MSG="se acaba el turno weón"
RH50_DOT="🔥"; RH50_MSG="vamos consumiendo el turno"
RH30_DOT="😎"; RH30_MSG="tranqui, hay cupo"
RH00_DOT="😈"; RH00_MSG="hay turno, estamo' entero"

# Cupo semanal (ventana 7d)
RS90_DOT="🆘"; RS90_MSG="llama a soporte weón"
RS80_DOT="💀"; RS80_MSG="casi sin cupo esta semana"
RS70_DOT="👻"; RS70_MSG="ojo con el cupo semanal"
RS50_DOT="🔥"; RS50_MSG="mitad de semana consumida"
RS30_DOT="😎"; RS30_MSG="tranqui, semana larga"
RS00_DOT="😈"; RS00_MSG="semana entera por delante"
# ─────────────────────────────────────────────────────────────────────────────

input=$(cat)

# ── Parse JSON ────────────────────────────────────────────────────────────────
MODEL=$(echo "$input"   | jq -r '.model.id // .model.display_name // "?"')
DIR=$(echo "$input"     | jq -r '.workspace.current_dir // .cwd // ""')
COST=$(echo "$input"    | jq -r '.cost.total_cost_usd // 0')
used=$(echo "$input"    | jq -r '.context_window.used_percentage // empty')
FIVE_H=$(echo "$input"  | jq -r '.rate_limits.five_hour.used_percentage // empty')
SEVEN_D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

[ -z "$used" ] && exit 0
echo "$used" > ~/.claude/ctx_pct.txt
pct_int=$(( ${used%.*} ))

# ── Colors ────────────────────────────────────────────────────────────────────
RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

# ── Bar builder ───────────────────────────────────────────────────────────────
COLS="${COLUMNS:-80}"
BAR_WIDTH=$(( COLS / 10 ))
[ "$BAR_WIDTH" -lt 10 ] && BAR_WIDTH=10
[ "$BAR_WIDTH" -gt 20 ] && BAR_WIDTH=20

make_bar() {
    local pct=$1 filled empty bar=""
    filled=$(( pct * BAR_WIDTH / 100 ))
    empty=$(( BAR_WIDTH - filled ))
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=0; i<empty;  i++)); do bar="${bar}░"; done
    echo "$bar"
}

# ── Line 1: Sesión ────────────────────────────────────────────────────────────
COST_FMT=$(printf '$%.2f' "$COST")

GIT_PART=""
if git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
    STAGED=$(git   -C "$DIR" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    MODIFIED=$(git -C "$DIR" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    GIT_PART="Branch: 🌿 ${BRANCH}"
    [ "$STAGED"   -gt 0 ] && GIT_PART="${GIT_PART} +${STAGED}"
    [ "$MODIFIED" -gt 0 ] && GIT_PART="${GIT_PART} ~${MODIFIED}"
    GIT_PART=" | ${GIT_PART}"
fi

printf "[%s]%s | 💰 %s\n" "$MODEL" "$GIT_PART" "$COST_FMT"

# ── Line 2: Contexto de sesión ────────────────────────────────────────────────
if   [ "$pct_int" -ge 90 ]; then color="$RED";    dot="$L90_DOT"; msg="$L90_MSG"
elif [ "$pct_int" -ge 80 ]; then color="$RED";    dot="$L80_DOT"; msg="$L80_MSG"
elif [ "$pct_int" -ge 70 ]; then color="$RED";    dot="$L70_DOT"; msg="$L70_MSG"
elif [ "$pct_int" -ge 60 ]; then color="$YELLOW"; dot="$L60_DOT"; msg="$L60_MSG"
elif [ "$pct_int" -ge 50 ]; then color="$YELLOW"; dot="$L50_DOT"; msg="$L50_MSG"
elif [ "$pct_int" -ge 30 ]; then color="$GREEN";  dot="$L30_DOT"; msg="$L30_MSG"
else                              color="$GREEN";  dot="$L00_DOT"; msg="$L00_MSG"
fi
echo "${dot} ${color}[$(make_bar "$pct_int")] ${pct_int}% — ${msg}${RESET}"

# ── Line 3: Cupo horario (5h) — solo Pro/Max ─────────────────────────────────
if [ -n "$FIVE_H" ]; then
    fh_int=$(( ${FIVE_H%.*} ))
    if   [ "$fh_int" -ge 90 ]; then color="$RED";    dot="$RH90_DOT"; msg="$RH90_MSG"
    elif [ "$fh_int" -ge 80 ]; then color="$RED";    dot="$RH80_DOT"; msg="$RH80_MSG"
    elif [ "$fh_int" -ge 70 ]; then color="$RED";    dot="$RH70_DOT"; msg="$RH70_MSG"
    elif [ "$fh_int" -ge 50 ]; then color="$YELLOW"; dot="$RH50_DOT"; msg="$RH50_MSG"
    elif [ "$fh_int" -ge 30 ]; then color="$GREEN";  dot="$RH30_DOT"; msg="$RH30_MSG"
    else                              color="$GREEN";  dot="$RH00_DOT"; msg="$RH00_MSG"
    fi
    echo "⏱ Cupo horario    ${dot} ${color}[$(make_bar "$fh_int")] ${fh_int}% — ${msg}${RESET}"
fi

# ── Line 4: Cupo semanal (7d) — solo Pro/Max ─────────────────────────────────
if [ -n "$SEVEN_D" ]; then
    sd_int=$(( ${SEVEN_D%.*} ))
    if   [ "$sd_int" -ge 90 ]; then color="$RED";    dot="$RS90_DOT"; msg="$RS90_MSG"
    elif [ "$sd_int" -ge 80 ]; then color="$RED";    dot="$RS80_DOT"; msg="$RS80_MSG"
    elif [ "$sd_int" -ge 70 ]; then color="$YELLOW"; dot="$RS70_DOT"; msg="$RS70_MSG"
    elif [ "$sd_int" -ge 50 ]; then color="$YELLOW"; dot="$RS50_DOT"; msg="$RS50_MSG"
    elif [ "$sd_int" -ge 30 ]; then color="$GREEN";  dot="$RS30_DOT"; msg="$RS30_MSG"
    else                              color="$GREEN";  dot="$RS00_DOT"; msg="$RS00_MSG"
    fi
    echo "📅 Cupo semanal   ${dot} ${color}[$(make_bar "$sd_int")] ${sd_int}% — ${msg}${RESET}"
fi
