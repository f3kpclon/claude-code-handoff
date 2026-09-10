# Claude Code Handoff

Preserves context between Claude Code sessions. Detects when context is running low, shows a native OS dialog, generates a structured snapshot silently to disk, and copies it to your clipboard so you can paste it into the next session.

Along the way it replaces the status bar with one that tells you how much room you have left — context, plan quotas, session spend, and optionally your account's monthly spend from your own endpoint.

## Requirements

- Claude Code
- Python 3
- jq (`brew install jq` / `sudo apt install jq`)
- curl — **only** if you configure the optional usage endpoint. Without it every other line works normally, and the usage line says `⚠️ sin datos — sin respuesta (curl:127)` rather than vanishing
- macOS, Linux (GNOME/KDE), or Windows (Git Bash / WSL)

## Install

```bash
git clone https://github.com/f3kpclon/claude-code-handoff
cd claude-code-handoff
bash install.sh
```

Copies hooks and skills to `~/.claude/`, registers them in `settings.json`, and appends the handoff protocol to `CLAUDE.md`. The `handoff` skill doubles as the `/handoff` slash command. Restart Claude Code after installing.

The installer asks one optional question — the usage endpoint (see
[Monthly spend](#monthly-spend-your-own-usage-endpoint)). Press Enter to skip it
and nothing about that feature is installed. The question only appears when both
stdin and stdout are a terminal, so a piped or captured install never blocks
waiting on an answer nobody can see; pass the values as environment variables
there instead:

```bash
HANDOFF_USAGE_URL="https://your-gateway.example/usage" \
HANDOFF_USAGE_TOKEN_CMD="~/.claude/bin/your-token" bash install.sh
```

## How it works

```
Every response      → status bar shows live context usage
At 60 / 75%         → native OS dialog: "Generate snapshot?"
User clicks Yes     → Claude composes snapshot internally (not shown in chat)
Bash writes to disk → ~/.claude/handoffs/{repo-name}/YYYY-MM-DD_HHmm.md + latest.md
                      directory created automatically if it doesn't exist
                      stored outside the repo — never committable by design
                      snapshot copied to clipboard
Claude confirms     → "💾 listo mi shan!! guarda'o el handoff" printed in chat
At context limit    → PreCompact hook saves a mini-snapshot automatically (bash-only, no Claude needed)
                      compaction proceeds — session continues unblocked
                      a system message tells you where the snapshot was saved
New session         → paste snapshot → Claude confirms and resumes
```

### Status bar

The status bar renders up to 6 lines depending on your plan and configuration:

```
[claude-sonnet-4-6] | Branch: 🌿 main +1 ~2 | 💰 $0.03
🧠 Contexto       😈 [████████░░░░░░░░░░░░] 45% — listo mi guasho!
⏱ Cupo horario   🔪 [███████████████░░░░░] 75% — 1h12m — se acaba el turno weón
📅 Cupo semanal  😎 [████░░░░░░░░░░░░░░░░] 23% — tranqui, semana larga
💳 Cupo mensual  😎 [███████░░░░░░░░░░░░░] 34% — $34.10 / $100 — queda $65.90 — tranqui, queda mes
```

**Line 1** — always shown: active model ID, git branch + staged/modified count, session cost.  
**Line 2** — always shown: session context window usage bar.  
**Lines 3–4** — Pro/Max only: 5-hour rolling quota and 7-day weekly quota bars.  
**Line 5** — API key only: session spend against a budget you set (see below).  
**Line 6** — only if you configure a usage endpoint: your account's month-to-date spend (see below).

#### Spend budget (API key)

With an API key the payload arrives without `rate_limits`, so lines 3–4 disappear
— and the limit stops being a window and starts being money. Set `COST_BUDGET` to
your budget in dollars and line 5 shows what the session has spent against it:

```
💵 Presupuesto    🔥 [█████░░░░░] 55% — $55.50 / $100 — media sesión de presupuesto
```

The figure is `cost.total_cost_usd` from the status line payload — Claude Code's
own number, not an estimate from a price table that would drift out of date.

`COST_BUDGET=0` (the default) hides the line entirely: a percentage against an
invented ceiling is worse than no percentage. The line also stays hidden when the
payload *does* carry `rate_limits`, because on a subscription the cost is notional
— what limits you there is the window, not the dollar.

Going over budget is its own state, not one more band on the scale: the bar
saturates but the percentage keeps climbing, so 118% never reads like 90%.

**Presupuesto (API key) levels:**

| Level | Emoji | Message |
|-------|-------|---------|
| < 30% | 😈 | recién parti'o, cero gasto |
| 30–50% | 😎 | tranqui, hay billete |
| 50–70% | 🔥 | media sesión de presupuesto |
| 70–80% | 🔪 | ojo que se va la plata |
| 80–90% | 💀 | casi sin presupuesto |
| 90–100% | 🆘 | quedando pato, corta el chorro |
| ≥ 100% | 🩸 | te pasaste del presupuesto weón |

#### Monthly spend (your own usage endpoint)

Every other line on the bar reads a number Claude Code already handed the
statusline. This one is different: neither a subscription nor an API key exposes
the account's **accumulated** spend in that payload — `cost.total_cost_usd` is
this session and nothing more. If you go through a proxy or gateway that tracks
a monthly quota, that number lives on its own endpoint, and this line is how the
bar gets to see it.

Point it at a URL that returns JSON and it renders line 6:

```
💳 Cupo mensual   🔥 [█████░░░░░] 52% — $52.10 / $100 — queda $47.90 — medio mes consumido
```

`install.sh` asks for the URL when you install (Enter skips it). To set it
without the prompt, or to change it later without reinstalling:

```bash
HANDOFF_USAGE_URL="https://your-gateway.example/usage" \
HANDOFF_USAGE_TOKEN_CMD="~/.claude/bin/your-token" bash install.sh
```

**No URL configured is the default, and it means the feature does not exist** —
no request, no cache file, no line. Installing this version without answering
the prompt leaves the status bar exactly as it was.

##### What the endpoint has to return

A JSON object with any of `percentUsed`, `spentUsd`, `limitUsd`. Everything else
is optional and used when present:

| Field | Used for |
|-------|----------|
| `percentUsed` | The bar. Missing → computed from `spentUsd / limitUsd` |
| `spentUsd`, `limitUsd` | The `$52.10 / $100` figures |
| `remainingUsd` | The `queda $47.90` tail. Missing → computed from limit − spent |
| `blocked` | `true` paints 🚫 regardless of the percentage — a blocked account at 12% must not read "tranqui, queda mes" |

##### Authentication

Pass a **command that prints the token**, not the token itself
(`USAGE_TOKEN_CMD`). Rotating credentials are the normal case — a JWT pasted
into a config file stops working in thirty minutes and never says so. For a
fixed credential, `USAGE_HEADER` takes a literal header instead.

The token never appears in the command line. `curl -H "Authorization: Bearer …"`
would expose it to any `ps` on the machine, so the header goes through a curl
config file written inside a 0700 lock directory and deleted right after.

##### It never blocks, and it never dies quietly

Two properties this line is built around, both of which cost more code than the
naive version and are the entire reason it is safe to run:

**The render never waits on the network.** `refreshInterval` re-runs the
statusline every few seconds; a hung DNS lookup with an 8-second timeout would
freeze the bar for 8 seconds, every minute, forever. The refresh runs detached
in the background and the render always paints from cache — a fresh install
shows `⏳ consultando el cupo…` for one interval and then the number. Requests
are throttled by `USAGE_TTL` (60s) and serialized across concurrent sessions by
an atomic lock that is reaped by age, so a fetch killed mid-flight cannot wedge
the line permanently.

**A failure is louder than a success, not quieter.** A line that disappears when
the token expires is indistinguishable from one that was never configured, and
that is the failure nobody notices. So: configured means visible, always. The
last good number survives the error and the error is appended to it, not
substituted for it:

```
💳 Cupo mensual   🔥 [█████░░░░░] 52% — $52.10 / $100 — medio mes consumido · dato de hace 22m · ⚠️ HTTP 401 — token rechazado
```

A response that parses but carries none of the expected fields is treated as a
failure too. `{"message":"Unauthorized"}` is valid JSON; accepting it would
paint an invented `0%` wearing the face of real data, which is worse than either
an error or no line at all.

**Cupo mensual levels:**

| Level | Emoji | Message |
|-------|-------|---------|
| < 30% | 😈 | mes entero por delante |
| 30–50% | 😎 | tranqui, queda mes |
| 50–70% | 🔥 | medio mes consumido |
| 70–80% | 🔪 | ojo que se acaba el mes |
| 80–90% | 💀 | casi sin cupo mensual |
| ≥ 90% | 🆘 | quedando pato con el mes weón |
| `blocked` | 🚫 | cuenta bloqueada — no pasa ni una más |
| no data yet | ⏳ | consultando el cupo… |
| fetch failed | ⚠️ | the reason, appended to the last known figure |

#### 5-hour countdown

Line 3 shows the time left in the current 5-hour window (`1h12m` / `43m` / `<1m`),
read from `rate_limits.five_hour.resets_at` in the payload Claude Code hands the
statusline. Nothing is polled and no timer runs: the value is already in the
JSON, and the countdown moves because the clock moves.

Once the window is over, the line stops drawing the bar:

```
⏱ Cupo horario   🆕 ventana vencida — el próximo mensaje abre turno nuevo
```

That is not cosmetic. After a reset the payload still reports the *dead*
window's `used_percentage` until the next API response, so painting the bar
there would show stale usage as if it were current.

The countdown needs `refreshInterval` in your `statusLine` settings, or Claude
Code only re-renders after each assistant message and the number freezes.
`install.sh` sets `10` on a fresh install and adds it to an existing one — an
interval you set yourself is left alone.

#### Cost per render

`refreshInterval` re-runs this script on a timer, so everything it does is paid
once per interval, all day. Two things are cached to keep that cheap:

| | Behaviour |
|---|---|
| Git branch and counters | Recomputed at most every 3s, cached per directory under `~/.claude/ctx/gitpart_*`. The branch indicator can lag a few seconds after a checkout. |
| Stale-state sweep | The `find` that reaps day-old session files runs hourly, not every render |

Measured on the same payload, 25 renders: **108 ms → 53 ms** per render. The
sweep alone was 37 ms of that — at `refreshInterval: 1` it was scanning the
directory 86,400 times a day to delete files that are 24 hours old.

Nothing is lost when a cache is missing or corrupt: an unreadable entry is
treated as a miss and recomputed, never rendered.

#### Rate-limit state on disk

When the payload carries rate limits, two files are maintained:

| File | What it holds |
|---|---|
| `~/.claude/ratelimit.json` | Current 5h/7d usage and `resets_at`, plus `observed_at` so a reader can tell how fresh it is |
| `~/.claude/ratelimit-history.jsonl` | One line per window turnover — the record of where the 5h boundaries fall |

Written at most once every 30s and appended only when `resets_at` actually
changes, so a 1-second `refreshInterval` does not turn into 86,400 daily writes.
Writes are atomic, and the files are account-wide rather than per-session
(unlike `ctx_pct`) because the quota is.

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
| window over | 🆕 | ventana vencida — el próximo mensaje abre turno nuevo |

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
/handoff         — slash command (explicit)
pausa sesión     — pause mid-session
cierra sesión    — save and close
termina sesión   — save and close
```

## Platform support

| OS | Dialog tool |
|----|-------------|
| macOS | `osascript` (built-in) |
| Linux GNOME | `zenity` → `sudo apt install zenity` |
| Linux KDE | `kdialog` → `sudo apt install kdialog` |
| Windows (Git Bash / WSL) | PowerShell `MessageBox` (built-in) |
| No dialog tool | System message suggests typing `/handoff` — never forces a handoff |

Clipboard copy uses the first tool available: `pbcopy` (macOS), `wl-copy` (Wayland), `xclip` (X11), `clip.exe` (Windows). Without any, the snapshot is still saved to disk.

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
THRESHOLDS="60 75"   # el último aviso se calcula solo (ver abajo)
USAGE_URL=""         # endpoint de consumo — vacío = apagado (el installer lo pregunta)
USAGE_TOKEN_CMD=""   # comando que imprime el token, no el token
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
| Confirmation message | `skills/handoff/SKILL.md` | line starting with `💾` |
| Contexto bar emoji + text | `hooks/statusline-context.sh` | `CTX_CRIT_DOT`, `CTX_CRIT_MSG`, etc. |
| Contexto band cut points | `hooks/statusline-context.sh` | `CTX_LOST_AT`, `CTX_FADE_AT`, etc. |
| Compaction reserve (tokens) | `hooks/statusline-context.sh` | `CTX_RESERVE` |
| Hourly quota emoji + text | `hooks/statusline-context.sh` | `RH90_DOT`, `RH90_MSG`, etc. |
| Weekly quota emoji + text | `hooks/statusline-context.sh` | `RS90_DOT`, `RS90_MSG`, etc. |
| Usage endpoint URL | `hooks/statusline-context.sh` | `USAGE_URL` |
| Usage endpoint token command | `hooks/statusline-context.sh` | `USAGE_TOKEN_CMD` |
| Usage endpoint literal header | `hooks/statusline-context.sh` | `USAGE_HEADER` |
| Usage refresh interval / timeout | `hooks/statusline-context.sh` | `USAGE_TTL`, `USAGE_TIMEOUT` |
| Usage staleness warning | `hooks/statusline-context.sh` | `USAGE_STALE_AFTER` |
| Monthly quota emoji + text | `hooks/statusline-context.sh` | `UM90_DOT`, `UM90_MSG`, etc. |

### Why these cut points

The bands are not a decorative 10-by-10 scale. They sit where the evidence says
quality has already dropped, which is well before the window fills up.

| Finding | Source | Confidence |
|---|---|---|
| 11 of 12 models fall below 50% of their short-context baseline **at 32k tokens** once the task needs inference instead of literal matching | [NoLiMa](https://arxiv.org/pdf/2502.05167) (Adobe Research, ICML 2025) | verified — peer reviewed |
| Degradation is continuous from the first length increment across 18 models (Opus 4, Sonnet 4, Haiku 3.5 included). There is no cliff to wait for | [Context Rot](https://www.trychroma.com/research/context-rot) (Chroma) | verified — published study |
| Finite "attention budget", n² pairwise relations, training skewed to short sequences → *"a performance gradient rather than a sharp cliff"* | [Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) | verified — first-party |
| `used_percentage` is a share of the **advertised** window (`context_window_size`: 200000, or 1000000 extended) | [statusline docs](https://code.claude.com/docs/en/statusline) | verified — first-party |
| Long-horizon agents lose the original goal from ~10-15 steps | [arXiv 2606.29718](https://arxiv.org/pdf/2606.29718) | plausible — preprint |
| Auto-compaction fires around 83.5% on a 200k window (`effectiveWindow − 13000`) | deobfuscated code in [issue #31806](https://github.com/anthropics/claude-code/issues/31806) | **plausible — not first-party** |

**The model matters more than the window.** On Anthropic's own MRCR v2 8-needle
benchmark, with the *same* 1M window, Opus 4.6 scores 76% and Sonnet 4.5 scores
18.5% — a 4x gap. Opus holds 93% at 256K. That is the largest single effect in
any of the evidence gathered here, larger than window size or band placement, so
the token anchors are split by model family (`*opus*` vs everything else) using
`model.id`. An unrecognized model gets the conservative scale: over-warning beats
a new model id silently switching the warnings off.

| Anchor | Opus | Others | Basis |
|---|---|---|---|
| 😎 | 64k | 32k | others: NoLiMa's 50%-of-baseline point (hard citation) |
| 🔥 | 128k | 80k | ramp |
| 👻 | 192k | 110k | ramp |
| 🔪 | **256k** | 130k | **Opus: Anthropic's measured 93% point** |
| 💀 | 384k | 150k | ramp |

Only two cells there are measurements — Opus 256k and others 32k. The rest is a
ramp between them, and is labelled as such in the source rather than dressed up
as a finding. **Known gap:** there is no public Sonnet number at 256K, only at
1M, so the "others" column above 32k is the weakest part of this table.

**What is deliberately *not* built:** a bar normalised against a degradation
saturation point. That design needs a 100% anchor, and no published evidence
establishes one — MRCR is a retrieval benchmark and NoLiMa showed retrieval
benchmarks overstate, so the honest range is too wide to draw. Instead
`pre-compact.sh` logs `tokens`, `tier` and `model` at every compaction, so the
curve can be measured locally and the anchors tuned from real sessions.

**Two different physics, so two thresholds per band.** The evidence above is
measured in **absolute tokens** — NoLiMa says 32k, not "16% of the window".
Painting that as a percentage happens to work on a 200k window and breaks on
1M, where 20% is 200,000 tokens: six times past the point where quality already
dropped, with the bar still reading "tranqui".

What *is* proportional to the window is proximity to auto-compaction — a bigger
window means compaction arrives later, in tokens and in percent alike. So:

| Band | Fires on | Why |
|---|---|---|
| 🆘 critical | percentage only | measures compaction proximity, which scales with the window |
| everything below | percentage **or** tokens, whichever comes first | measures reasoning degradation, which is absolute |

The token anchors are calibrated on a 200k window, where the evidence was
mapped — there they behave almost exactly like the percentages, so a 200k
session sees no change. On 1M the token anchors take over, which is the point.
Only `CTX_OK_TOK=32000` has a hard citation (NoLiMa); the ones above it are the
same 200k scale, i.e. a ramp, not a measurement.

That last row is the weak one, and it carries `CTX_RESERVE`. Anthropic documents
no compaction threshold anywhere, and the community reports disagree: [issue
#15719](https://github.com/anthropics/claude-code/issues/15719) (Dec 2025) claims a
hardcoded 95%, [#31806](https://github.com/anthropics/claude-code/issues/31806)
(Mar 2026) claims ~83.5%. Both were closed as duplicates with no maintainer
reply. Probably a change between those dates — but that is a guess, not a fact.

`CTX_RESERVE=33000` is derived from the 83.5% figure, not quoted from a source.
Two things keep that honest:

- **It fails loudly, not silently.** If the real threshold is higher, the 🆘 band
  fires early — annoying but visible. The previous fixed `90` did the opposite:
  on a 200k window auto-compaction hit first, so that band *never rendered once*.
- **It measures itself.** `pre-compact.sh` runs exactly when compaction happens,
  so the last `used_percentage` on disk **is** the threshold. Every event appends
  a line to `~/.claude/ctx/compact-observed.tsv`:

  ```
  2026-09-05 19:16	observed=84.2	predicted=83
  ```

  After a few compactions, tune `CTX_RESERVE` from your own `observed` column
  instead of from anyone's blog post.

Note: `THRESHOLDS` controls when the **dialog** fires; the statusline emoji bands (20/40/55/65/75 + a computed critical band) are display-only and independent — changing one does not change the other.

## Test

```bash
bash test.sh
```

Verifies snapshot save logic, install idempotency, PreCompact behavior, statusline safety, monitor threshold/sentinel logic (with mocked dialogs), the dynamic compaction ceiling, spend-budget rendering, monthly-usage fetch/cache/failure states, and CUSTOMIZE injection robustness. 144 assertions.

## Security

Every pull request runs three automated checks via GitHub Actions:

| Check | What it does |
|-------|-------------|
| ShellCheck | Lints all `.sh` files for errors and unsafe patterns |
| Tests | Runs the full test suite (`bash test.sh`) |
| Security scan | Detects dangerous patterns in `hooks/`, `skills/`, `install.sh`, `uninstall.sh` and `test.sh` — outbound network calls, base64 decode, raw TCP, netcat, dynamic `exec`/`eval`, and any request that *uploads* |

The monthly-usage line is the one outbound call in the project, so it is the one
exemption: a line marked `# net-allow:` is skipped by the scan. The exemption is
deliberately narrow — it clears that single line and nothing else, it shows up in
the diff of any PR that adds one, and it does **not** apply to the upload
patterns (`--data`, `--form`, `-X POST`, `--upload-file`), which fail the scan
marked or not. Querying and exfiltrating are different things and the gate still
tells them apart.

Note that the URL is yours to choose, and the token is sent to whatever you
configure. Point it at your own gateway.

**Branch protection** is active on this repo: all three checks must pass before any PR can merge, and direct pushes to `main` are restricted to the codeowner. For forks, enable it manually in GitHub → Settings → Branches.

The rules also require one approving review from a code owner. On a
single-maintainer repo that condition can never be met — GitHub does not let you
approve your own pull request — so merges here go through the admin bypass
(`enforce_admins` is off for exactly that reason):

```bash
gh pr merge <n> --squash --delete-branch --admin
```

The status checks are the gate that actually does work; the review requirement
is there for the day this repo has a second maintainer.

## Repair

If another tool modifies `~/.claude/settings.json` after installation (e.g. `codebase-indexer install`), it may overwrite the hooks registered by handoff. Re-running install is safe and re-registers any missing hooks without duplicating existing ones:

```bash
bash install.sh
```

The installer prints a verification table at the end showing which hooks are registered:

```
Verifying hook registration...
  ✓  Stop             → handoff-monitor.sh
  ✓  PreCompact       → pre-compact.sh
  ✓  statusLine       → statusline-context.sh
```

If any show `✗ MISSING`, run `bash install.sh` again to fix them.

**Already have a statusline?** The threshold dialogs depend on the context percentage that only `statusline-context.sh` writes. If a different statusline is configured, the installer fails loudly instead of leaving a dead alert system. Either replace yours (`HANDOFF_FORCE_STATUSLINE=1 bash install.sh`) or add one line to your own statusline script:

```bash
echo "$used" > ~/.claude/ctx_pct.txt   # $used = .context_window.used_percentage from stdin JSON
```

## Uninstall

```bash
bash uninstall.sh
```

Removes all hooks, the `/handoff` command, skills, and surgically cleans `settings.json` (only the entries handoff added — your other settings and any foreign statusline are untouched).

Runtime state goes with it (`ctx/`, `ctx_pct.txt`, `ratelimit.json`,
`usage.json`) because all of it rebuilds itself on the next render. Two things
are deliberately kept: snapshots in `~/.claude/handoffs/`, and
`ratelimit-history.jsonl`, which is the only record of where your quota windows
fell and cannot be reconstructed.

## Files

| File | Role |
|------|------|
| `CLAUDE.md` | Handoff protocol — triggers and resume behavior for Claude |
| `skills/handoff/SKILL.md` | The `/handoff` command and auto-invoked skill — composes snapshot silently, writes to disk via Bash, prints one-line confirmation |
| `skills/handoff-protocol/SKILL.md` | Snapshot format template — single source of truth, loaded by the handoff skill when composing |
| `hooks/statusline-context.sh` | Renders the whole status bar — context, plan quotas, session budget, monthly usage — and writes the state the monitor reads |
| `hooks/handoff-monitor.sh` | Fires after each response — shows dialog at thresholds |
| `hooks/pre-compact.sh` | Saves a bash-only mini-snapshot before auto-compaction |
| `test.sh` | 144 assertions — snapshot logic, install idempotency, PreCompact, statusline safety, monitor thresholds, monthly-usage endpoint, CUSTOMIZE injection |
| `install.sh` | Installs everything into `~/.claude/` |
| `uninstall.sh` | Removes everything installed |

### State written to `~/.claude/`

Nothing here is configuration — it is all rebuilt automatically, and all of it
except the last two rows is deleted by `uninstall.sh`.

| Path | What it holds |
|------|---------------|
| `ctx/<session>.pct` `.tok` `.compact` `.tier` | Per-session context state. The monitor only sees files, so the statusline has to write down what it knows: percentage, tokens, the computed compaction ceiling and the model family |
| `ctx/gitpart_*` | Cached git branch + counters, 3s TTL |
| `ctx/.housekeeping` | Timestamp throttling the hourly sweep of stale session files |
| `ctx/.usage.lock` | Held while a usage fetch is in flight; reaped by age |
| `ctx_pct.txt` | Legacy global percentage, kept for hand-rolled statuslines |
| `ratelimit.json` | Last observed quota windows, written at most every 30s |
| `usage.json` | Last usage-endpoint response, plus when it was last checked and the last error |
| `ratelimit-history.jsonl` | **Kept on uninstall** — append-only log of quota window boundaries |
| `handoffs/<repo>/` | **Kept on uninstall** — your snapshots |
