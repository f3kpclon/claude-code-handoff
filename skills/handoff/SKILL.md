---
name: handoff
description: Genera el snapshot de la sesión actual para retomar en la próxima sesión sin perder contexto. Invocar antes de cerrar o cuando el contexto se acerca al límite.
disable-model-invocation: true
model: claude-haiku-4-5-20251001
allowed-tools: Bash
---

Genera un handoff snapshot para esta sesión. Escríbelo a disco **sin mostrarlo en el chat**.

**Paso 1** — obtén contexto:
```bash
date "+%Y-%m-%d %H:%M" && git rev-parse --show-toplevel 2>/dev/null || pwd
```

**Paso 2** — redacta el snapshot internamente usando el formato de /handoff-protocol.

Reglas:
- Rutas absolutas reales, no nombres genéricos
- Comandos concretos que funcionaron en esta sesión
- Si no hay nada en progreso → igualmente generar el snapshot con "ninguno"

**Paso 3** — escríbelo a disco con un solo bloque Bash. Reemplaza el contenido del heredoc con el snapshot real redactado en el paso 2:

```bash
REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_NAME=$(basename "$REPO")
HDIR="$HOME/.claude/handoffs/$REPO_NAME"
mkdir -p "$HDIR"
TS=$(date '+%Y-%m-%d_%H%M')
cat > "$HDIR/$TS.md" << 'HANDOFF_END'
[CONTENIDO REAL DEL SNAPSHOT — reemplazar esta línea con el texto completo]
HANDOFF_END
cp "$HDIR/$TS.md" "$HDIR/latest.md"
ls -t "$HDIR"/*.md 2>/dev/null | grep -v 'latest.md' | tail -n +6 | xargs rm -f 2>/dev/null || true
cat "$HDIR/latest.md" | pbcopy 2>/dev/null || true
```

No muestres el contenido del snapshot en el chat. Cuando el Bash termine, responde únicamente con esta línea (nada más):

💾 listo mi shan!! guarda'o el handoff
`{path completo a latest.md}`
