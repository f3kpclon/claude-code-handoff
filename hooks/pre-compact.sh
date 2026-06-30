#!/usr/bin/env bash
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

# Notify Claude post-compaction that a snapshot was auto-saved
python3 -c "
import json, sys
msg = 'Auto-handoff guardado en $HDIR/latest.md — la sesión fue compactada por límite de contexto. Informa al usuario que puede retomar con: cat $HDIR/latest.md'
print(json.dumps({'additionalContext': msg}))
"
