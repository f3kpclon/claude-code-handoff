## Handoff Protocol

### Triggers
Si el mensaje o contexto adicional contiene `handoff`, `snapshot`, `pausa` o `HANDOFF REQUESTED` → genera este snapshot ANTES de responder cualquier otra cosa.

Usa rutas absolutas reales, no nombres genéricos. Incluye comandos concretos que funcionaron.

```
# Handoff Snapshot
**Fecha:** [YYYY-MM-DD HH:MM]
**Repo / Proyecto:** [nombre + path absoluto]

## Objetivo
[una oración: qué se estaba construyendo o resolviendo]

## Completado
- [tarea terminada con detalle: qué archivo, qué cambio, qué resultado]

## En Progreso
- [tarea actual + estado exacto + qué falta para terminarla]

## Próximos Pasos
1. [paso inmediato concreto — suficiente para arrancar sin preguntar]

## Decisiones Técnicas
- [decisión]: [razón — qué alternativa se descartó y por qué]

## Blockers
- [ninguno / descripción + causa raíz si se conoce]

## Contexto Técnico
- Stack: [lenguajes/frameworks/herramientas activas]
- Archivos clave: [paths absolutos de los archivos que se estaban tocando]
- Comandos útiles: [comandos para retomar — tests, build, run, etc.]
```

### Resume behavior
Al iniciar sesión con un snapshot pegado (bloque con `## Objetivo`) → confirma en una oración: "Retomando: [objetivo]. ¿Continuamos con [próximo paso]?"
