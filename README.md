# Claude Code Handoff

Preserves context between Claude Code sessions. Detects when context is running low, shows a native OS dialog, generates a structured snapshot silently to disk, and copies it to your clipboard so you can paste it into the next session.

## Requirements

- Claude Code
- Python 3
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
Bash writes to disk → {repo}/.claude/handoffs/YYYY-MM-DD_HHmm.md + latest.md
                      .gitignore updated automatically
                      snapshot copied to clipboard
Claude confirms     → "💾 listo mi shan!! guarda'o el handoff" printed in chat
New session         → paste snapshot → Claude confirms and resumes
```

### Status bar

| Level | Emoji | Message |
|-------|-------|---------|
| < 30% | 🥬 | fresco como lechuga |
| 30–50% | 😎 | tranqui |
| 50–60% | 🔥 | se calienta la cosa |
| 60–70% | 👻 | en cualquier momento me voy en la vola' |
| 70–80% | 🔪 | me pase po |
| 80–90% | 💀 | ¿qué hacíamos? |
| ≥ 90% | 🆘 | handoff altiro weón |

> Colors require ANSI support. If you see escape codes, remove the color lines in `hooks/statusline-context.sh`.

## Manual triggers

Type any of these at any time:

```
handoff   snapshot   pausa   /handoff
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

Paste the snapshot at the start of a new session. Claude confirms the objective and continues from where you left off.

## Snapshots

Saved per-repo to `{repo}/.claude/handoffs/YYYY-MM-DD_HHmm.md` after each generation. A `latest.md` is always overwritten for quick access. The `.claude/handoffs/` entry is automatically added to the repo's `.gitignore` — snapshots are never committed.

Snapshots are **on-demand**: zero token cost unless you paste one into a new session. There is no auto-injection at startup by design.

## Customization

Edit the `# ── CUSTOMIZE` block in `install.sh` before installing, or edit the installed files directly in `~/.claude/` after:

| What | File | Variable |
|------|------|----------|
| Context thresholds | `hooks/handoff-monitor.sh` | `THRESHOLDS` |
| Dialog title | `hooks/handoff-monitor.sh` | `DIALOG_TITLE` |
| Dialog message | `hooks/handoff-monitor.sh` | `DIALOG_MSG` |
| Confirmation message | `commands/handoff.md` | line starting with `💾` |
| Status bar emoji + text | `hooks/statusline-context.sh` | `L90_DOT`, `L90_MSG`, etc. |

## Test

```bash
bash test.sh
```

Verifies snapshot save logic, install idempotency, and sentinel behavior. 16 assertions.

## Uninstall

```bash
bash uninstall.sh
```

Removes all hooks, the `/handoff` command, and cleans `settings.json`. Restores `settings.json.bak` if available. Snapshots in `{repo}/.claude/handoffs/` are preserved.

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
