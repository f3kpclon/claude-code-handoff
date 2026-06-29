---
name: handoff-protocol
description: Formato del Handoff Snapshot. Cargar al generar un snapshot de sesión — cuando el mensaje contiene handoff, snapshot o pausa.
disable-model-invocation: false
allowed-tools: []
---

Genera el snapshot con este formato exacto. Usa rutas absolutas reales. Incluye comandos concretos que funcionaron.

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
