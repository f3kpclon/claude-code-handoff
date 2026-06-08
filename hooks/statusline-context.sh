#!/usr/bin/env bash
# ── CONFIG ───────────────────────────────────────────────────────────────────
L90_DOT="🆘"; L90_MSG="handoff altiro weón"
L80_DOT="💀"; L80_MSG="¿qué hacíamos?"
L70_DOT="🔪"; L70_MSG="me pase po"
L60_DOT="👻"; L60_MSG="en cualquier momento me voy en la vola'"
L50_DOT="🔥"; L50_MSG="se calienta la cosa"
L30_DOT="😎"; L30_MSG="tranqui"
L00_DOT="🥬"; L00_MSG="fresco como lechuga"
# ─────────────────────────────────────────────────────────────────────────────

input=$(cat)
used=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
pct = d.get('context_window', {}).get('used_percentage', '')
print(pct if pct != '' else '')
" 2>/dev/null)
[ -z "$used" ] && exit 0

echo "$used" > ~/.claude/ctx_pct.txt
pct_int=$(( ${used%.*} ))

filled=$(( pct_int / 10 ))
empty=$(( 10 - filled ))
bar=""
for ((i=0; i<filled; i++)); do bar="${bar}█"; done
for ((i=0; i<empty; i++)); do bar="${bar}░"; done

if   [ "$pct_int" -ge 90 ]; then color="\033[31m"; dot="$L90_DOT"; msg="$L90_MSG"
elif [ "$pct_int" -ge 80 ]; then color="\033[31m"; dot="$L80_DOT"; msg="$L80_MSG"
elif [ "$pct_int" -ge 70 ]; then color="\033[31m"; dot="$L70_DOT"; msg="$L70_MSG"
elif [ "$pct_int" -ge 60 ]; then color="\033[33m"; dot="$L60_DOT"; msg="$L60_MSG"
elif [ "$pct_int" -ge 50 ]; then color="\033[33m"; dot="$L50_DOT"; msg="$L50_MSG"
elif [ "$pct_int" -ge 30 ]; then color="\033[32m"; dot="$L30_DOT"; msg="$L30_MSG"
else                              color="\033[32m"; dot="$L00_DOT"; msg="$L00_MSG"
fi

printf "${dot} ${color}[${bar}] ${pct_int}%% — ${msg}\033[0m"
