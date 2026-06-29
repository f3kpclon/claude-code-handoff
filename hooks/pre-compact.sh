#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook: intercept auto-compaction, trigger handoff instead.
#
# Emits decision:block to prevent compaction (if supported by Claude Code).
# Also sets /tmp/handoff_pending as fallback: if block is not supported and
# compaction proceeds, handoff-inject.sh fires on the next user message.

INPUT=$(cat)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)

GIT_LOG=$(git -C "$CWD" log --oneline -5 2>/dev/null | head -5)
GIT_STATUS=$(git -C "$CWD" status --short 2>/dev/null | head -10)

# Sentinel for handoff-inject.sh fallback (fires on next UserPromptSubmit)
touch /tmp/handoff_pending

REASON="HANDOFF REQUESTED

El contexto está lleno — se interceptó la compactación automática.
Genera el snapshot de handoff para continuar en una sesión nueva.

Contexto técnico:
- Directorio: $CWD
- Git log:
$GIT_LOG
- Archivos modificados:
$GIT_STATUS"

echo "{\"decision\": \"block\", \"reason\": $(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$REASON")}"
