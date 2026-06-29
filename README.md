# Claude Code Handoff

Preserves context between Claude Code sessions. Detects when context is running low, shows a native OS dialog, generates a structured snapshot silently to disk, and copies it to your clipboard so you can paste it into the next session.

## Requirements

- Claude Code
- Python 3
- jq (`brew install jq` / `sudo apt install jq`)
- macOS, Linux (GNOME/KDE), or Windows (Git Bash / WSL)

## Install

```bash
git clone https://github.com/f3kpclon/claude-code-handoff
cd claude-code-handoff
bash install.sh
```

Copies hooks and command to `~/.claude/`, registers them in `settings.json`, and appends the handoff protocol to `CLAUDE.md`. Restart Claude Code after installing.

## How it works

```
Every response      → status bar shows live context usage
At 70 / 80 / 90%   → native OS dialog: "Generate snapshot?"
User clicks Yes     → Claude composes snapshot internally (not shown in chat)
Bash writes to disk → ~/.claude/handoffs/{repo-name}/YYYY-MM-DD_HHmm.md + latest.md
                      directory created automatically if it doesn't exist
                      stored outside the repo — never committable by design
                      snapshot copied to clipboard
Claude confirms     → "💾 listo mi shan!! guarda'o el handoff" printed in chat
New session         → paste snapshot → Claude confirms and resumes
```

### Status bar

The status bar renders up to 4 lines depending on your plan:

```
[claude-sonnet-4-6] | Branch: 🌿 main +1 ~2 | 💰 $0.03
🧠 Contexto       😈 [████████░░░░░░░░░░░░] 45% — listo mi guasho!
⏱ Cupo horario   🔪 [███████████████░░░░░] 75% — se acaba el turno weón
📅 Cupo semanal  😎 [████░░░░░░░░░░░░░░░░] 23% — tranqui, semana larga
```

**Line 1** — always shown: active model ID, git branch + staged/modified count, session cost.  
**Line 2** — always shown: session context window usage bar.  
**Lines 3–4** — Pro/Max only: 5-hour rolling quota and 7-day weekly quota bars.

**Context window levels:**

| Level | Emoji | Message |
|-------|-------|---------|
| < 30% | 😈 | listo mi guasho! estamo' entero activa'os |
| 30–50% | 😎 | tranqui |
| 50–60% | 🔥 | se calienta la cosa |
| 60–70% | 👻 | en cualquier momento me voy en la vola' |
| 70–80% | 🔪 | me pase po |
| 80–90% | 💀 | ¿qué hacíamos? |
| ≥ 90% | 🆘 | handoff altiro weón |

**Cupo horario (5h rolling) levels:**

| Level | Emoji | Message |
|-------|-------|---------|
| < 30% | 😈 | hay turno, estamo' entero |
| 30–50% | 😎 | tranqui, hay cupo |
| 50–70% | 🔥 | vamos consumiendo el turno |
| 70–80% | 🔪 | se acaba el turno weón |
| 80–90% | 💀 | casi sin cupo horario |
| ≥ 90% | 🆘 | quedando pato weón! al 100 no money no honey |

**Cupo semanal (7d) levels:**

| Level | Emoji | Message |
|-------|-------|---------|
| < 30% | 😈 | semana entera por delante |
| 30–50% | 😎 | tranqui, semana larga |
| 50–70% | 🔥 | mitad de semana consumida |
| 70–80% | 👻 | ojo con el cupo semanal |
| 80–90% | 💀 | casi sin cupo esta semana |
| ≥ 90% | 🆘 | llama a soporte weón |

> Colors require ANSI support. If you see escape codes, check your terminal settings.

## Manual triggers

Type any of these at any time:

```
/handoff        — slash command (explicit)
pausa sesión    — phrase trigger
```

## Platform support

| OS | Dialog tool |
|----|-------------|
| macOS | `osascript` (built-in) |
| Linux GNOME | `zenity` → `sudo apt install zenity` |
| Linux KDE | `kdialog` → `sudo apt install kdialog` |
| Windows (Git Bash / WSL) | PowerShell `MessageBox` (built-in) |
| No dialog tool | Falls back to in-chat message |

## Resuming a session

Two ways to resume:

**Option A — paste** (recommended): the snapshot is copied to your clipboard automatically. Paste it at the start of a new session. Claude detects the `## Objetivo` block and confirms before continuing.

**Option B — ask**: if you forgot to paste or want to resume days later, just say "lee el último handoff" (or "retoma", "último snapshot"). Claude reads `~/.claude/handoffs/{repo-name}/latest.md` automatically and picks up from there.

## Snapshots

Saved to `~/.claude/handoffs/{repo-name}/YYYY-MM-DD_HHmm.md` after each generation. A `latest.md` is always overwritten for quick access.

Snapshots are stored **outside the repo** — they can never be committed regardless of `.gitignore` configuration. Works with any project, with or without a `.claude/` directory.

Snapshots are **on-demand**: zero token cost unless you paste one into a new session. There is no auto-injection at startup by design.

## Customization

Edit the `# ── CUSTOMIZE` block in `install.sh` before installing — values are injected into all files automatically:

```bash
# ── CUSTOMIZE ────────────────────────────────────────────────────────────────
THRESHOLDS="70 80 90"
DIALOG_TITLE="Claude Code — Handoff"
DIALOG_MSG='Context at ${PCT_INT}% — generate handoff snapshot to continue in a new session?'
CONFIRM_MSG="💾 listo mi shan!! guarda'o el handoff"
```

To change after installing, edit the `# ── CUSTOMIZE` block in each file under `~/.claude/`:

| What | File | Variable |
|------|------|----------|
| Context thresholds | `hooks/handoff-monitor.sh` | `THRESHOLDS` |
| Dialog title | `hooks/handoff-monitor.sh` | `DIALOG_TITLE` |
| Dialog message | `hooks/handoff-monitor.sh` | `DIALOG_MSG` |
| Confirmation message | `commands/handoff.md` | line starting with `💾` |
| Contexto bar emoji + text | `hooks/statusline-context.sh` | `L90_DOT`, `L90_MSG`, etc. |
| Hourly quota emoji + text | `hooks/statusline-context.sh` | `RH90_DOT`, `RH90_MSG`, etc. |
| Weekly quota emoji + text | `hooks/statusline-context.sh` | `RS90_DOT`, `RS90_MSG`, etc. |

## Test

```bash
bash test.sh
```

Verifies snapshot save logic, install idempotency, and sentinel behavior. 16 assertions.

## Security

Every pull request runs three automated checks via GitHub Actions:

| Check | What it does |
|-------|-------------|
| ShellCheck | Lints all `.sh` files for errors and unsafe patterns |
| Tests | Runs the full test suite (`bash test.sh`) |
| Security scan | Detects dangerous patterns in `hooks/`, `install.sh`, and `commands/` — outbound network calls, base64 decode, raw TCP, netcat, dynamic `exec` |

**Branch protection** is active on this repo: all three checks must pass before any PR can merge, and direct pushes to `main` are restricted to the codeowner. For forks, enable it manually in GitHub → Settings → Branches.

## Uninstall

```bash
bash uninstall.sh
```

Removes all hooks, the `/handoff` command, and cleans `settings.json`. Restores `settings.json.bak` if available. Snapshots in `~/.claude/handoffs/` are preserved.

## Files

| File | Role |
|------|------|
| `CLAUDE.md` | Handoff protocol — triggers and resume behavior for Claude |
| `commands/handoff.md` | `/handoff` slash command — composes snapshot silently, writes to disk via Bash, prints one-line confirmation |
| `hooks/statusline-context.sh` | Renders the context progress bar in the status line |
| `hooks/handoff-monitor.sh` | Fires after each response — shows dialog at thresholds |
| `hooks/handoff-inject.sh` | Injects handoff context on the next user message after dialog |
| `test.sh` | 16 assertions — snapshot logic, install idempotency, sentinel behavior |
| `install.sh` | Installs everything into `~/.claude/` |
| `uninstall.sh` | Removes everything installed |
