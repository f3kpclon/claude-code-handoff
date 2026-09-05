#!/usr/bin/env bash
# shellcheck disable=SC2001  # sed adds a prefix to multi-line vars inside the heredoc
# pre-compact.sh — PreCompact hook: save mini-snapshot to disk, then allow compaction.
#
# Does NOT block — blocking when context is full leaves Claude unable to act.
# Instead: writes a bash-only mini-snapshot with available context, then lets
# compaction proceed. The compacted session continues with a snapshot on disk.

INPUT=$(cat)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)

REPO_NAME=$(basename "$CWD")
HDIR="$HOME/.claude/handoffs/$REPO_NAME"
mkdir -p "$HDIR"

# ── Medir el umbral de compactación real ─────────────────────────────────────
# Los cortes de contexto se calibran contra un punto de compact (~83% en 200k)
# que Anthropic NO documenta: sale de código deobfuscado por terceros, y hay
# reportes que se contradicen (95% en dic-2025 vs 83,5% en mar-2026). Calibrar
# contra un número que nadie puede verificar es exactamente el proxy que hay
# que evitar cuando el juez real está disponible.
#
# Y acá lo está: este hook corre JUSTO cuando la compactación va a ocurrir, así
# que el último used_percentage que alcanzó a escribir la statusline ES el
# umbral, observado y no inferido. Una línea por evento, para poder ajustar
# CTX_RESERVE con dato propio en vez de con un despeje.
#
# Nunca puede tumbar el hook: todo va a /dev/null y el snapshot sigue igual.
{
    SID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
    if [ -n "$SID" ] && [ -f "$HOME/.claude/ctx/$SID.pct" ]; then
        OBS_PCT=$(cat "$HOME/.claude/ctx/$SID.pct" 2>/dev/null)
        OBS_COMPACT=$(cat "$HOME/.claude/ctx/$SID.compact" 2>/dev/null)
        printf '%s\tobserved=%s\tpredicted=%s\n' \
            "$(date '+%Y-%m-%d %H:%M')" "${OBS_PCT:-?}" "${OBS_COMPACT:-?}" \
            >> "$HOME/.claude/ctx/compact-observed.tsv"
    fi
} 2>/dev/null || true

TS=$(date '+%Y-%m-%d_%H%M')
DATE=$(date '+%Y-%m-%d %H:%M')

GIT_LOG=$(git -C "$CWD" log --oneline -5 2>/dev/null | head -5)
GIT_STATUS=$(git -C "$CWD" status --short 2>/dev/null | head -10)
BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)

# Pull objective from previous snapshot if available
PREV_OBJECTIVE=""
if [ -f "$HDIR/latest.md" ]; then
    PREV_OBJECTIVE=$(grep -A1 "^## Objetivo" "$HDIR/latest.md" 2>/dev/null | tail -1)
fi

# Degraded mini-snapshot: bash can't compose session content — only the fields
# derivable from git/fs. Section layout mirrors skills/handoff-protocol/SKILL.md;
# update both together when changing the format.
cat > "$HDIR/$TS.md" << HANDOFF_END
# Handoff Snapshot
**Fecha:** $DATE
**Repo / Proyecto:** $REPO_NAME — $CWD

## Objetivo
${PREV_OBJECTIVE:-[generado automáticamente por PreCompact — completar en próxima sesión]}

## Completado
- [contexto compactado automáticamente — revisar git log para detalles]

## En Progreso
- Sesión interrumpida por límite de contexto — compactación automática ejecutada

## Próximos Pasos
1. Revisar git status y continuar desde el último commit

## Decisiones Técnicas
- [ver historial de commits]

## Blockers
- Ninguno conocido

## Contexto Técnico
- Stack: bash, Claude Code CLI
- Branch: ${BRANCH:-desconocido}
- Archivos modificados:
$(echo "$GIT_STATUS" | sed 's/^/  /')
- Git log reciente:
$(echo "$GIT_LOG" | sed 's/^/  /')
- Comandos útiles:
  - cat $HDIR/latest.md
  - git log --oneline -10
HANDOFF_END

cp "$HDIR/$TS.md" "$HDIR/latest.md"

# Notify the user that a snapshot was auto-saved.
# PreCompact does NOT support additionalContext — systemMessage is the only
# supported channel (shown to the user; compaction proceeds).
python3 -c "
import json
msg = '💾 Auto-handoff guardado en $HDIR/latest.md — retoma con: cat $HDIR/latest.md'
print(json.dumps({'systemMessage': msg}))
"
