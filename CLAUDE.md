## Handoff Protocol

### Triggers
Si el contexto adicional contiene `HANDOFF REQUESTED` (inyectado por el hook automático), o el usuario escribe explícitamente `/handoff` o la frase exacta `pausa sesión` → invoca `/handoff` ANTES de responder cualquier otra cosa.

### Resume behavior
Al iniciar sesión con un snapshot pegado (bloque con `## Objetivo`) → confirma en una oración: "Retomando: [objetivo]. ¿Continuamos con [próximo paso]?"

### Resume trigger
Si el usuario dice "lee el último handoff", "retoma", "último snapshot" o similar → ejecuta este comando y usa el resultado como contexto de sesión:
```bash
cat ~/.claude/handoffs/$(basename $(git rev-parse --show-toplevel 2>/dev/null || pwd))/latest.md
```
Luego confirma en una oración: "Retomando: [objetivo]. ¿Continuamos con [próximo paso]?"
