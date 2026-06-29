## Handoff Protocol

### Triggers
Si el contexto adicional contiene `HANDOFF REQUESTED` (inyectado por el hook automático), o el usuario escribe explícitamente `/handoff` o la frase exacta `pausa sesión` → invoca `/handoff` ANTES de responder cualquier otra cosa.

### Resume behavior
Al iniciar sesión con un snapshot pegado (bloque con `## Objetivo`) → confirma en una oración: "Retomando: [objetivo]. ¿Continuamos con [próximo paso]?"
