---
description: Genera snapshot de sesión y lo guarda en disco silenciosamente
allowed-tools: Bash
---

Genera un handoff snapshot para esta sesión. Escríbelo a disco **sin mostrarlo en el chat**.

**Paso 1** — obtén contexto:
```bash
date "+%Y-%m-%d %H:%M" && git rev-parse --show-toplevel 2>/dev/null || pwd
```

**Paso 2** — redacta el snapshot internamente con este esquema:

```
# Handoff Snapshot
**Fecha:** [fecha del paso 1]
**Repo / Proyecto:** [nombre] — [path del paso 1]

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

**Paso 3** — escríbelo a disco con un solo bloque Bash. Reemplaza el contenido del heredoc con el snapshot real redactado en el paso 2:

```bash
REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HDIR="$REPO/.claude/handoffs"
mkdir -p "$HDIR"
TS=$(date '+%Y-%m-%d_%H%M')
cat > "$HDIR/$TS.md" << 'HANDOFF_END'
[CONTENIDO REAL DEL SNAPSHOT — reemplazar esta línea con el texto completo]
HANDOFF_END
cp "$HDIR/$TS.md" "$HDIR/latest.md"
grep -qF '.claude/handoffs/' "$REPO/.gitignore" 2>/dev/null || echo '.claude/handoffs/' >> "$REPO/.gitignore"
cat "$HDIR/latest.md" | pbcopy 2>/dev/null || true
```

No muestres el contenido del snapshot en el chat. Cuando el Bash termine, responde únicamente con esta línea (nada más):

💾 listo mi shan!! guarda'o el handoff

`{path completo a latest.md}`
