## Handoff Protocol

### Triggers
Si el mensaje o contexto adicional contiene `handoff`, `snapshot`, `pausa` o `HANDOFF REQUESTED` → invoca `/handoff` ANTES de responder cualquier otra cosa.

### Resume behavior
Al iniciar sesión con un snapshot pegado (bloque con `## Objetivo`) → confirma en una oración: "Retomando: [objetivo]. ¿Continuamos con [próximo paso]?"
