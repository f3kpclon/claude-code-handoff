#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass/fail always return 0; && ... || is safe throughout
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); return 0; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); return 0; }

# ── Test 1: snapshot save logic ───────────────────────────────────────────────
echo "1. Snapshot save logic"

FAKE_REPO=$(mktemp -d)
FAKE_HOME=$(mktemp -d)
REPO_NAME=$(basename "$FAKE_REPO")
HDIR="$FAKE_HOME/.claude/handoffs/$REPO_NAME"
mkdir -p "$HDIR"
TS=$(date '+%Y-%m-%d_%H%M')
SNAPSHOT="# Handoff Snapshot\n**Fecha:** 2026-01-01\n## Objetivo\nTest"

printf "%b" "$SNAPSHOT" > "$HDIR/$TS.md"
cp "$HDIR/$TS.md" "$HDIR/latest.md"

[ -f "$HDIR/$TS.md" ]                          && pass "snapshot file created"             || fail "snapshot file missing"
[ -f "$HDIR/latest.md" ]                       && pass "latest.md created"                 || fail "latest.md missing"
[[ "$HDIR" == "$FAKE_HOME/.claude/handoffs/"* ]] && pass "snapshot outside repo"           || fail "snapshot inside repo"
[ ! -f "$FAKE_REPO/.gitignore" ]               && pass "repo .gitignore not modified"      || fail ".gitignore was modified"

# idempotent: .git/info/exclude entry not duplicated
mkdir -p "$FAKE_REPO/.git/info"
grep -qF '.claude/handoffs/' "$FAKE_REPO/.git/info/exclude" 2>/dev/null \
  || echo '.claude/handoffs/' >> "$FAKE_REPO/.git/info/exclude"
grep -qF '.claude/handoffs/' "$FAKE_REPO/.git/info/exclude" 2>/dev/null \
  || echo '.claude/handoffs/' >> "$FAKE_REPO/.git/info/exclude"
COUNT=$(grep -c '.claude/handoffs/' "$FAKE_REPO/.git/info/exclude")
[ "$COUNT" -eq 1 ]                             && pass "git exclude entry not duplicated"   || fail "git exclude has duplicate entry ($COUNT)"

rm -rf "$FAKE_REPO" "$FAKE_HOME"

# ── Test 2: install.sh copies all required files ─────────────────────────────
echo "2. install.sh file copies"

FAKE_HOME=$(mktemp -d)
# Simulate a pre-v0.3 install with the legacy command present
mkdir -p "$FAKE_HOME/.claude/commands"
touch "$FAKE_HOME/.claude/commands/handoff.md"
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1 || true

[ -f "$FAKE_HOME/.claude/skills/handoff/SKILL.md" ]      && pass "handoff skill installed"       || fail "handoff skill missing"
[ -f "$FAKE_HOME/.claude/skills/handoff-protocol/SKILL.md" ] && pass "handoff-protocol skill installed" || fail "handoff-protocol skill missing"
[ ! -f "$FAKE_HOME/.claude/commands/handoff.md" ]        && pass "legacy command removed (skill is /handoff)" || fail "legacy commands/handoff.md still present"
[ -f "$FAKE_HOME/.claude/hooks/handoff-monitor.sh" ]     && pass "handoff-monitor.sh installed"  || fail "handoff-monitor.sh missing"
[ -f "$FAKE_HOME/.claude/hooks/statusline-context.sh" ]  && pass "statusline-context.sh installed" || fail "statusline-context.sh missing"
[ -f "$FAKE_HOME/.claude/hooks/pre-compact.sh" ]         && pass "pre-compact.sh installed"       || fail "pre-compact.sh missing"
[ -x "$FAKE_HOME/.claude/hooks/handoff-monitor.sh" ]     && pass "hooks are executable"          || fail "hooks not executable"
[ -f "$FAKE_HOME/.claude/settings.json" ]                && pass "settings.json created"         || fail "settings.json missing"

# hooks must be registered in settings.json
grep -q "handoff-monitor.sh" "$FAKE_HOME/.claude/settings.json" \
                                                          && pass "Stop hook registered"          || fail "Stop hook not in settings.json"
grep -q "pre-compact.sh"     "$FAKE_HOME/.claude/settings.json" \
                                                          && pass "PreCompact hook registered"      || fail "PreCompact hook not in settings.json"

# install must be idempotent — run twice, no duplicates
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1 || true
STOP_COUNT=$(grep -c "handoff-monitor.sh" "$FAKE_HOME/.claude/settings.json")
[ "$STOP_COUNT" -eq 1 ] && pass "install is idempotent (no duplicate hooks)" || fail "duplicate hooks after re-install ($STOP_COUNT)"

rm -rf "$FAKE_HOME"

# ── Test 3: install.sh cleans stale pre-v0.3 registrations ───────────────────
echo "3. install.sh stale registration cleanup"

FAKE_HOME=$(mktemp -d)
mkdir -p "$FAKE_HOME/.claude"
cat > "$FAKE_HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/handoff-inject.sh"}]}
    ]
  }
}
JSON
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1 || true
grep -q "handoff-inject.sh" "$FAKE_HOME/.claude/settings.json" \
  && fail "stale handoff-inject.sh registration not removed" || pass "stale handoff-inject.sh registration removed"
rm -rf "$FAKE_HOME"

# ── Test 4: pre-compact.sh save-and-allow behavior ───────────────────────────
echo "4. pre-compact.sh save-and-allow"

FAKE_HOME=$(mktemp -d)
FAKE_REPO=$(mktemp -d)
git -C "$FAKE_REPO" init -q 2>/dev/null
git -C "$FAKE_REPO" commit --allow-empty -m "init" > /dev/null 2>&1 || true

INPUT=$(python3 -c "import json; print(json.dumps({'cwd': '$FAKE_REPO'}))")
OUTPUT=$(echo "$INPUT" | HOME="$FAKE_HOME" bash "$SCRIPT_DIR/hooks/pre-compact.sh" 2>/dev/null)

# must NOT emit decision:block
echo "$OUTPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    blocked = d.get('decision') == 'block'
except Exception:
    blocked = False
sys.exit(1 if blocked else 0)
" && pass "pre-compact does not block compaction" || fail "pre-compact still emits decision:block"

# must emit systemMessage (PreCompact does not support additionalContext)
echo "$OUTPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    found = 'systemMessage' in d and 'additionalContext' not in d
except Exception:
    found = False
sys.exit(0 if found else 1)
" && pass "pre-compact emits systemMessage (not additionalContext)" || fail "pre-compact output wrong: expected systemMessage"

# must save snapshot to disk
REPO_NAME=$(basename "$FAKE_REPO")
[ -f "$FAKE_HOME/.claude/handoffs/$REPO_NAME/latest.md" ] \
  && pass "pre-compact saves mini-snapshot to disk"   || fail "mini-snapshot not written"
[ -s "$FAKE_HOME/.claude/handoffs/$REPO_NAME/latest.md" ] \
  && pass "mini-snapshot is non-empty"                || fail "mini-snapshot is empty"

# ── Sonda: el umbral de compact medido, no inferido ──────────────────────────
# El hook corre justo cuando se compacta, así que el último .pct ES el umbral.
# Es lo que permite calibrar CTX_RESERVE con dato observado.
mkdir -p "$FAKE_HOME/.claude/ctx"
echo "84.2" > "$FAKE_HOME/.claude/ctx/probe.pct"
echo "83"   > "$FAKE_HOME/.claude/ctx/probe.compact"
echo "190000" > "$FAKE_HOME/.claude/ctx/probe.tok"
echo "opus"   > "$FAKE_HOME/.claude/ctx/probe.tier"
PROBE_IN=$(python3 -c "import json; print(json.dumps({'cwd': '$FAKE_REPO', 'session_id': 'probe', 'model': {'id': 'claude-opus-5'}}))")
echo "$PROBE_IN" | HOME="$FAKE_HOME" bash "$SCRIPT_DIR/hooks/pre-compact.sh" > /dev/null 2>&1
OBSERVED="$FAKE_HOME/.claude/ctx/compact-observed.tsv"
[ -f "$OBSERVED" ] \
  && pass "compact real registrado al dispararse el hook" || fail "no se registró la observación"
grep -q "observed=84.2" "$OBSERVED" 2>/dev/null \
  && pass "guarda el % observado (juez real)"             || fail "% observado ausente: $(cat "$OBSERVED" 2>/dev/null)"
grep -q "predicted=83" "$OBSERVED" 2>/dev/null \
  && pass "guarda el % predicho, para contrastar"         || fail "% predicho ausente"
# El modelo y los tokens: la evidencia dice que la familia manda, así que una
# curva propia sin esa columna no sirve para recalibrar nada.
grep -q "model=claude-opus-5" "$OBSERVED" 2>/dev/null \
  && pass "la sonda registra el modelo"                   || fail "modelo ausente: $(cat "$OBSERVED")"
grep -q "tokens=190000" "$OBSERVED" 2>/dev/null \
  && pass "la sonda registra los tokens"                  || fail "tokens ausentes"
grep -q "tier=opus" "$OBSERVED" 2>/dev/null \
  && pass "la sonda registra la familia"                  || fail "tier ausente"

# Sin session_id la sonda se calla, pero el snapshot debe salir igual: medir
# nunca puede costar una compactación.
LINES_BEFORE=$(wc -l < "$OBSERVED")
NOSID_IN=$(python3 -c "import json; print(json.dumps({'cwd': '$FAKE_REPO'}))")
echo "$NOSID_IN" | HOME="$FAKE_HOME" bash "$SCRIPT_DIR/hooks/pre-compact.sh" > /dev/null 2>&1 \
  && pass "sin session_id el hook sigue saliendo 0"       || fail "la sonda tumbó el hook"
[ "$(wc -l < "$OBSERVED")" -eq "$LINES_BEFORE" ] \
  && pass "sin datos no inventa una medición"             || fail "escribió una observación sin fuente"

rm -rf "$FAKE_HOME" "$FAKE_REPO"

# ── Test 5: install.sh hook verification ─────────────────────────────────────
echo "5. install.sh hook verification"

FAKE_HOME=$(mktemp -d)
# Fresh install — verification must pass (exit 0)
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /tmp/install_out.txt 2>&1 || true
grep -q "✓" /tmp/install_out.txt \
  && pass "verification shows ✓ for registered hooks" || fail "verification output missing ✓"
! grep -q "MISSING" /tmp/install_out.txt \
  && pass "no MISSING hooks after fresh install"       || fail "MISSING reported after fresh install"

# Remove a hook from settings.json and re-verify
python3 - "$FAKE_HOME/.claude/settings.json" <<'PYEOF'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
# Remove Stop hooks entirely to simulate clobber by another tool
d['hooks'].pop('Stop', None)
p.write_text(json.dumps(d, indent=2))
PYEOF
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /tmp/install_repair.txt 2>&1 || true
# After re-install the hook must be back
grep -q "handoff-monitor.sh" "$FAKE_HOME/.claude/settings.json" \
  && pass "re-install repairs missing Stop hook"          || fail "Stop hook not repaired"

rm -rf "$FAKE_HOME"

# ── Test 6: foreign statusline detection ─────────────────────────────────────
echo "6. install.sh foreign statusline"

FAKE_HOME=$(mktemp -d)
mkdir -p "$FAKE_HOME/.claude"
echo '{"statusLine": {"type": "command", "command": "bash ~/other-statusline.sh"}}' > "$FAKE_HOME/.claude/settings.json"

if HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /tmp/install_foreign.txt 2>&1; then
  fail "install exits 0 with foreign statusline (alerts silently dead)"
else
  pass "install fails loudly with foreign statusline"
fi
grep -q "NOT ours" /tmp/install_foreign.txt \
  && pass "foreign statusline reported in verification"   || fail "foreign statusline not reported"
grep -q "other-statusline.sh" "$FAKE_HOME/.claude/settings.json" \
  && pass "foreign statusline not clobbered"              || fail "foreign statusline was overwritten"

# Forced replacement must succeed
if HANDOFF_FORCE_STATUSLINE=1 HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1; then
  pass "HANDOFF_FORCE_STATUSLINE=1 replaces and passes"
else
  fail "forced statusline replacement did not pass verification"
fi
grep -q "statusline-context.sh" "$FAKE_HOME/.claude/settings.json" \
  && pass "statusline replaced after force flag"          || fail "statusline not replaced with force flag"

rm -rf "$FAKE_HOME"

# ── Test 7: handoff-monitor.sh thresholds & sentinels ────────────────────────
echo "7. handoff-monitor.sh thresholds"

FAKE_HOME=$(mktemp -d)
FAKE_BIN=$(mktemp -d)
SID="handofftest$$"
mkdir -p "$FAKE_HOME/.claude/ctx"
# Sentinels now live in $HOME/.claude/ctx (not /tmp) — FAKE_HOME is fresh, so no
# cross-run contamination. Clear any legacy /tmp leftovers from older versions.
rm -f "/tmp/handoff_w60_$SID" "/tmp/handoff_w75_$SID" "/tmp/handoff_w81_$SID"

# Fake dialog binaries so no real dialog pops on any platform:
# darwin branch calls osascript, linux branch calls zenity.
make_dialogs() {  # $1 = Yes|No
  if [ "$1" = "Yes" ]; then
    printf '#!/usr/bin/env bash\necho "Yes"\n' > "$FAKE_BIN/osascript"
    printf '#!/usr/bin/env bash\nexit 0\n'     > "$FAKE_BIN/zenity"
  else
    printf '#!/usr/bin/env bash\necho "No"\n'  > "$FAKE_BIN/osascript"
    printf '#!/usr/bin/env bash\nexit 1\n'     > "$FAKE_BIN/zenity"
  fi
  chmod +x "$FAKE_BIN/osascript" "$FAKE_BIN/zenity"
}

INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID" "$PWD")
run_monitor() {
  echo "$INPUT" | HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/hooks/handoff-monitor.sh" 2>/dev/null
}

make_dialogs Yes

echo "50" > "$FAKE_HOME/.claude/ctx/$SID.pct"
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "below threshold → silence" || fail "output below threshold: $OUT"

echo "62" > "$FAKE_HOME/.claude/ctx/$SID.pct"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "60% + Yes → block with HANDOFF REQUESTED" || fail "no block at 60%: $OUT"

# Sentinel written under ~/.claude/ctx (owned, not world-writable) — NOT /tmp
[ -f "$FAKE_HOME/.claude/ctx/handoff_w60_$SID" ] \
  && pass "sentinel in ~/.claude/ctx (not /tmp)" || fail "sentinel not in ctx dir"
[ ! -f "/tmp/handoff_w60_$SID" ] \
  && pass "no sentinel leaked to /tmp"           || fail "sentinel still written to /tmp"

OUT=$(run_monitor)
[ -z "$OUT" ] && pass "60% alert consumed — no repeat" || fail "alert repeated at same level: $OUT"

echo "76" > "$FAKE_HOME/.claude/ctx/$SID.pct"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "next threshold (75%) fires again" || fail "75% threshold did not fire: $OUT"

make_dialogs No
echo "82" > "$FAKE_HOME/.claude/ctx/$SID.pct"
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "critical + No → no block" || fail "block emitted after No: $OUT"

make_dialogs Yes
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "No consumed the critical alert" || fail "critical alert re-fired after No: $OUT"

# ── Techo dinámico: el último aviso se ancla al compact, no a un 90 fijo ─────
# Regresión del bug que motivó la recalibración: con ventana de 200k el compact
# cae en ~83%, así que un umbral en 90 no dispara NUNCA. El aviso crítico tiene
# que caer por debajo del compact de la ventana que esté en uso.
# Los tramos fijos se dan por consumidos para aislar el ÚLTIMO aviso, que es el
# que se calcula: el monitor escala de a un nivel por Stop, así que sin esto
# siempre respondería el 60 y el crítico no se ejercitaría nunca.
seed_fixed() {
  touch "$FAKE_HOME/.claude/ctx/handoff_w60_$1" "$FAKE_HOME/.claude/ctx/handoff_w75_$1"
}

SID3="handofftest3$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID3" "$PWD")
seed_fixed "$SID3"
echo "82" > "$FAKE_HOME/.claude/ctx/$SID3.pct"
echo "83" > "$FAKE_HOME/.claude/ctx/$SID3.compact"     # ventana de 200k → crít 81
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "200k: crítico dispara bajo el compact (82 ≥ 81)" || fail "crítico no disparó en 200k: $OUT"
[ -f "$FAKE_HOME/.claude/ctx/handoff_w81_$SID3" ] \
  && pass "200k: el sentinel usa el corte calculado (81), no un 90 fijo" || fail "sentinel w81 ausente"

# El contraste que justifica todo el cambio: MISMO 82% de contexto, y el
# veredicto se invierte según el tamaño de ventana. Con el 90 fijo anterior,
# 200k no avisaba nunca y 1M avisaba tardísimo — el mismo número para dos
# físicas distintas.
SID4="handofftest4$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID4" "$PWD")
seed_fixed "$SID4"
echo "82" > "$FAKE_HOME/.claude/ctx/$SID4.pct"
echo "96" > "$FAKE_HOME/.claude/ctx/$SID4.compact"     # ventana de 1M → crít 94
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "1M: 82% todavía NO es crítico (compact está en 96)" \
              || fail "crítico disparó antes de tiempo en 1M: $OUT"

echo "95" > "$FAKE_HOME/.claude/ctx/$SID4.pct"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "1M: el crítico se corre solo hasta 94" || fail "crítico no disparó a 95% en 1M: $OUT"

# ── El monitor sigue a la barra: cortes por token también acá ───────────────
# Si el statusline dice que degradaste a los 200k tokens de una ventana de 1M,
# el handoff no puede esperar al 60% (= 600,000 tokens). Sería avisar cuatro
# veces tarde justo en la ventana donde más se nota.
SID7="handofftest7$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID7" "$PWD")
echo "20" > "$FAKE_HOME/.claude/ctx/$SID7.pct"       # 20% — muy lejos del 60
echo "96" > "$FAKE_HOME/.claude/ctx/$SID7.compact"   # ventana de 1M
echo "200000" > "$FAKE_HOME/.claude/ctx/$SID7.tok"   # pero 200k tokens
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "1M: 200k tokens ofrece handoff pese a ir en 20%" \
  || fail "el monitor ignoró los tokens: $OUT"

# Y no al revés: pocos tokens no pueden disparar sólo por el porcentaje bajo.
SID8="handofftest8$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID8" "$PWD")
echo "20" > "$FAKE_HOME/.claude/ctx/$SID8.pct"
echo "96" > "$FAKE_HOME/.claude/ctx/$SID8.compact"
echo "50000" > "$FAKE_HOME/.claude/ctx/$SID8.tok"
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "1M: 50k tokens al 20% no molesta" || fail "disparó sin motivo: $OUT"

# Sin .tok (statusline vieja) los cortes por token no participan y manda el
# porcentaje — degradar a silencio es peor que degradar al comportamiento viejo.
SID9="handofftest9$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID9" "$PWD")
echo "62" > "$FAKE_HOME/.claude/ctx/$SID9.pct"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "sin .tok, el corte por porcentaje sigue vivo" || fail "sin .tok el monitor enmudeció: $OUT"

# ── El monitor usa la misma escala que la barra ─────────────────────────────
# Si la barra dice que Opus está sano a los 200k, el monitor no puede estar
# ofreciendo handoff ahí — y viceversa para Sonnet.
SID10="handofftest10$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID10" "$PWD")
echo "20" > "$FAKE_HOME/.claude/ctx/$SID10.pct"
echo "96" > "$FAKE_HOME/.claude/ctx/$SID10.compact"
echo "200000" > "$FAKE_HOME/.claude/ctx/$SID10.tok"
echo "opus" > "$FAKE_HOME/.claude/ctx/$SID10.tier"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "Opus: 200k cruza el primer corte (192k)" || fail "opus no disparó a 200k: $OUT"

# Los mismos 150k: para Sonnet ya es hora, para Opus todavía no.
SID11="handofftest11$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID11" "$PWD")
echo "15" > "$FAKE_HOME/.claude/ctx/$SID11.pct"
echo "96" > "$FAKE_HOME/.claude/ctx/$SID11.compact"
echo "150000" > "$FAKE_HOME/.claude/ctx/$SID11.tok"
echo "opus" > "$FAKE_HOME/.claude/ctx/$SID11.tier"
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "Opus: 150k todavía no molesta" || fail "opus cortó demasiado pronto: $OUT"

SID12="handofftest12$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID12" "$PWD")
echo "15" > "$FAKE_HOME/.claude/ctx/$SID12.pct"
echo "96" > "$FAKE_HOME/.claude/ctx/$SID12.compact"
echo "150000" > "$FAKE_HOME/.claude/ctx/$SID12.tok"
echo "std" > "$FAKE_HOME/.claude/ctx/$SID12.tier"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "Sonnet: los mismos 150k sí ofrecen handoff" || fail "std no disparó a 150k: $OUT"

# Sin .tier → escala conservadora, no la de Opus.
SID13="handofftest13$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID13" "$PWD")
echo "15" > "$FAKE_HOME/.claude/ctx/$SID13.pct"
echo "96" > "$FAKE_HOME/.claude/ctx/$SID13.compact"
echo "150000" > "$FAKE_HOME/.claude/ctx/$SID13.tok"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "sin .tier cae a la escala conservadora" || fail "sin .tier se relajaron los umbrales: $OUT"

# .compact ausente (statusline no instalada) → 83, el valor medido en 200k
SID5="handofftest5$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID5" "$PWD")
seed_fixed "$SID5"
echo "82" > "$FAKE_HOME/.claude/ctx/$SID5.pct"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "sin .compact → cae al default de 200k" || fail "fallback de compact roto: $OUT"

# Un .compact corrupto no puede reventar la aritmética ni inventar un umbral
SID6="handofftest6$$"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID6" "$PWD")
seed_fixed "$SID6"
echo "82" > "$FAKE_HOME/.claude/ctx/$SID6.pct"
printf 'no-soy-un-numero' > "$FAKE_HOME/.claude/ctx/$SID6.compact"
OUT=$(run_monitor 2>&1)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass ".compact corrupto → cae al default sin reventar" || fail "compact corrupto rompió el monitor: $OUT"

INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID" "$PWD")

# per-session pct: another session's percentage must not trigger this session
SID2="handofftest2$$"
rm -f "/tmp/handoff_w60_$SID2" "/tmp/handoff_w75_$SID2" "/tmp/handoff_w81_$SID2"
echo "10" > "$FAKE_HOME/.claude/ctx/$SID2.pct"
echo "99" > "$FAKE_HOME/.claude/ctx/$SID.pct"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID2" "$PWD")
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "session reads its own pct (no cross-session trigger)" || fail "cross-session pct leak: $OUT"

rm -f /tmp/handoff_w60_"$SID"* /tmp/handoff_w75_"$SID"* /tmp/handoff_w81_"$SID"* \
      "/tmp/handoff_w60_$SID2" "/tmp/handoff_w75_$SID2" "/tmp/handoff_w81_$SID2"
rm -rf "$FAKE_HOME" "$FAKE_BIN"

# ── Test 8: CUSTOMIZE injection robustness (sed→python3) ─────────────────────
echo "8. install.sh CUSTOMIZE injection robustness"

FAKE_HOME=$(mktemp -d)
# Must live inside the repo: install.sh resolves siblings (VERSION, skills/,
# hooks/) via BASH_SOURCE, so a copy in /tmp can't find them.
NASTY_INSTALL="$SCRIPT_DIR/.install.nasty.$$.sh"
# Adversarial title: | is sed's s|...| delimiter and & means "the matched text"
# in a sed replacement — both would corrupt the old sed-based injection.
python3 - "$SCRIPT_DIR/install.sh" "$NASTY_INSTALL" <<'PYEOF'
import sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
t = src.read_text().replace(
    'DIALOG_TITLE="Claude Code — Handoff"',
    'DIALOG_TITLE="Pipe|And&Amp"')
dst.write_text(t)
PYEOF
HOME="$FAKE_HOME" bash "$NASTY_INSTALL" > /dev/null 2>&1 || true
MON="$FAKE_HOME/.claude/hooks/handoff-monitor.sh"

bash -n "$MON" 2>/dev/null \
  && pass "installed monitor is valid bash with |& in title" || fail "nasty CUSTOMIZE corrupted the installed script"
grep -qF 'Pipe|And&Amp' "$MON" \
  && pass "special-char title survived injection intact"     || fail "title mangled by injection"
# ${PCT_INT} template token must stay literal (shlex single-quotes, no expansion)
# shellcheck disable=SC2016  # the single-quoted literal is exactly what we grep for
grep -qF '${PCT_INT}' "$MON" \
  && pass "\${PCT_INT} template token preserved literally"    || fail "\${PCT_INT} token lost during injection"

rm -f "$NASTY_INSTALL"
rm -rf "$FAKE_HOME"

# ── Test 9: statusline 5h countdown & rate-limit state ───────────────────────
echo "9. statusline 5h countdown & rate-limit state"

SL="$SCRIPT_DIR/hooks/statusline-context.sh"
SL_HOME=$(mktemp -d)
mkdir -p "$SL_HOME/.claude"

sl_run() { echo "$1" | HOME="$SL_HOME" COLUMNS=80 bash "$SL" 2>/dev/null; }

# Relative payload: `now` is read at call time, so a slow suite can't drift the
# expected countdown across a minute boundary and make these tests flaky.
sl_payload_rel() {  # $1 = seconds until reset, $2 = used_percentage
  sl_payload_abs "$(( $(date +%s) + $1 ))" "$2"
}
sl_payload_abs() {  # $1 = absolute resets_at, $2 = used_percentage
  printf '{"model":{"id":"opus"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0.5},"context_window":{"used_percentage":42},"session_id":"t9","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s}}}' \
    "$SL_HOME" "$2" "$1"
}

# Offsets land mid-minute (…+30s) on purpose. On the exact boundary a single
# second passing between this date(1) call and the `now` jq computes inside the
# script drops the result into the previous minute — 10020s renders "2h46m",
# not "2h47m" — and the assertion fails perhaps one run in fifteen.
# Output is captured, never piped. Under `set -o pipefail` a consumer that
# exits early (grep -q on a first-line match, head -1) closes the pipe while the
# statusline is still writing later lines; it takes SIGPIPE and the pipeline
# reports failure no matter what the grep found — and on an inverted assertion
# that reads as a false PASS. $(...) reads to EOF, so it cannot happen.
CD_OUT=$(sl_run "$(sl_payload_rel 10050 58)")
echo "$CD_OUT" | grep -q '58% — 2h47m —' \
  && pass "countdown >1h renders as 2h47m" || fail "countdown >1h wrong"
CD_OUT=$(sl_run "$(sl_payload_rel 2610 91)")
echo "$CD_OUT" | grep -q '91% — 43m —' \
  && pass "countdown <1h renders as 43m"   || fail "countdown <1h wrong"
CD_OUT=$(sl_run "$(sl_payload_rel 30 91)")
echo "$CD_OUT" | grep -q '91% — <1m —' \
  && pass "countdown <1m renders as <1m"   || fail "countdown <1m wrong"

# An expired window must NOT paint the bar: used_percentage still carries the
# DEAD window's value, so rendering it would report stale usage as if it were live.
SL_EXPIRED=$(sl_run "$(sl_payload_rel -600 91)")
echo "$SL_EXPIRED" | grep -q 'ventana vencida' \
  && pass "expired window announces itself" || fail "expired window not announced"
echo "$SL_EXPIRED" | grep -q '91%' \
  && fail "expired window still paints the dead window's %" \
  || pass "expired window hides the stale %"

# Field-alignment regression. The single jq call must use `// ""` and never
# `// empty`: with `// empty` an absent rate_limits block drops its lines and
# every field below it slides up one variable — silently, with no error.
SL_NORL='{"model":{"id":"sonnet-x"},"workspace":{"current_dir":"/nonexistent-t9"},"cost":{"total_cost_usd":7.77},"context_window":{"used_percentage":42},"session_id":"t9b"}'
SL_NORL_OUT=$(sl_run "$SL_NORL")
echo "$SL_NORL_OUT" | grep -q '\[sonnet-x\]' \
  && pass "model survives a missing rate_limits block" || fail "model field shifted"
# shellcheck disable=SC2016  # $7.77 is the literal cost string we grep for, not an expansion
echo "$SL_NORL_OUT" | grep -qF '$7.77' \
  && pass "cost survives a missing rate_limits block"  || fail "cost field shifted"
echo "$SL_NORL_OUT" | grep -q 'Cupo horario' \
  && fail "cupo line rendered without rate_limits" \
  || pass "no cupo line for a payload without rate_limits"

# Write policy: the state file refreshes on a timer; the history log grows ONLY
# when resets_at actually changes. That log is the record of window boundaries.
SL_RL="$SL_HOME/.claude/ratelimit.json"
SL_HIST="$SL_HOME/.claude/ratelimit-history.jsonl"
SL_FIXED=$(( $(date +%s) + 10020 ))
# Clean slate: the countdown tests above already wrote a state file with THEIR
# resets_at. Inheriting it would make the "no change" assertion below depend on
# whether those values happened to collide.
rm -f "$SL_RL" "$SL_HIST"
sl_run "$(sl_payload_abs "$SL_FIXED" 58)" > /dev/null
[ -f "$SL_RL" ] && pass "ratelimit.json written" || fail "ratelimit.json never written"
H1=$(wc -l < "$SL_HIST" | tr -d ' ')

touch -t 200001010000 "$SL_RL"
sl_run "$(sl_payload_abs "$SL_FIXED" 59)" > /dev/null
H2=$(wc -l < "$SL_HIST" | tr -d ' ')
[ "$H2" = "$H1" ] && pass "same resets_at appends no history line" \
                  || fail "history grew without a window change ($H1 → $H2)"

touch -t 200001010000 "$SL_RL"
sl_run "$(sl_payload_abs "$(( SL_FIXED + 9999 ))" 12)" > /dev/null
H3=$(wc -l < "$SL_HIST" | tr -d ' ')
[ "$H3" = "$(( H2 + 1 ))" ] && pass "a new resets_at appends exactly one history line" \
                            || fail "history delta wrong ($H2 → $H3)"

sl_run "$(sl_payload_abs "$(( SL_FIXED + 12345 ))" 13)" > /dev/null
H4=$(wc -l < "$SL_HIST" | tr -d ' ')
[ "$H4" = "$H3" ] && pass "write throttle holds while the state file is fresh" \
                  || fail "throttle leaked a write ($H3 → $H4)"

# Both artifacts are machine-read by whatever consumes the window boundary —
# malformed JSON here fails silently downstream, so assert it here instead.
HIST_BAD=0
while IFS= read -r line; do
  echo "$line" | jq -e . > /dev/null 2>&1 || HIST_BAD=1
done < "$SL_HIST"
[ "$HIST_BAD" = 0 ] && pass "every history line is valid JSON" || fail "history contains malformed JSON"
jq -e . "$SL_RL" > /dev/null 2>&1 \
  && pass "ratelimit.json is valid JSON" || fail "ratelimit.json is malformed"

# ── Higiene: la suite no puede tocar el ~/.claude real ───────────────────────
# El statusline escribe estado de contexto a disco en cada corrida. Sin HOME
# fijado, `bash test.sh` sobrescribía ~/.claude/ctx_pct.txt del usuario con el
# valor de un payload de prueba — y ese archivo lo leen los hooks que deciden
# cuándo ofrecer un handoff. Correr los tests podía disparar un diálogo falso o
# tapar uno real, sin dejar rastro de por qué.
LEAK_HOME=$(mktemp -d); mkdir -p "$LEAK_HOME/.claude"
REAL_CTX_BEFORE=$(cat "$HOME/.claude/ctx_pct.txt" 2>/dev/null || echo "__none__")
printf '{"model":{"id":"o"},"workspace":{"current_dir":"/nonexistent-leak"},"cost":{"total_cost_usd":1},"context_window":{"used_percentage":97},"session_id":"leakprobe"}' \
  | HOME="$LEAK_HOME" COST_BUDGET=100 bash "$SL" > /dev/null 2>&1
REAL_CTX_AFTER=$(cat "$HOME/.claude/ctx_pct.txt" 2>/dev/null || echo "__none__")
[ "$REAL_CTX_BEFORE" = "$REAL_CTX_AFTER" ] \
  && pass "la suite no pisa el ctx_pct.txt real" || fail "el test escribió en el HOME real: $REAL_CTX_BEFORE -> $REAL_CTX_AFTER"
[ ! -f "$HOME/.claude/ctx/leakprobe.pct" ] \
  && pass "no deja estado de sesión en el ~/.claude real" || fail "leakprobe.pct quedó en el HOME real"
[ -f "$LEAK_HOME/.claude/ctx/leakprobe.pct" ] \
  && pass "el estado va al HOME de prueba" || fail "no escribió en el HOME de prueba"
rm -rf "$LEAK_HOME"

# Lo anterior prueba que el hook respeta HOME, no que la suite se lo pase. Este
# guard es el que caza la reintroducción: cualquier invocación del statusline
# sin HOME vuelve a escribir en el ~/.claude real, que es como entró el bug.
# Se excluyen los comentarios y las propias líneas de conteo: si no, el guard
# se cuenta a sí mismo (su patrón aparece literal acá) y falla siempre.
# shellcheck disable=SC2016  # el patrón se busca literal en el archivo, no se expande
SL_CALLS=$(grep 'bash "$SL"' "$SCRIPT_DIR/test.sh" | grep -v '^[[:space:]]*#' | grep -v 'grep ')
SL_TOTAL=$(printf '%s\n' "$SL_CALLS" | grep -c . || true)
SL_CON_HOME=$(printf '%s\n' "$SL_CALLS" | grep -c 'HOME=' || true)
[ "$SL_TOTAL" -eq "$SL_CON_HOME" ] \
  && pass "toda invocación del statusline fija HOME ($SL_CON_HOME/$SL_TOTAL)" \
  || fail "hay $(( SL_TOTAL - SL_CON_HOME )) invocación(es) de statusline sin HOME — escriben en el ~/.claude real"

# ── El installer no puede mentir sobre sus propios umbrales ──────────────────
# Regresión real: install.sh inyectaba THRESHOLDS="60 75" y dos líneas más abajo
# anunciaba "At 70/80/90%" en texto fijo. El usuario lee el número viejo y el
# installer suena igual de seguro. Ahora se deriva de la variable — esto lo
# verifica contra la salida de verdad, no contra el código fuente.
INST_HOME=$(mktemp -d)
INST_OUT=$(HOME="$INST_HOME" bash "$SCRIPT_DIR/install.sh" 2>&1)
INST_THRESHOLDS=$(grep -m1 '^THRESHOLDS=' "$SCRIPT_DIR/install.sh" | sed 's/.*"\(.*\)".*/\1/')
INST_EXPECTED="${INST_THRESHOLDS// //}"
echo "$INST_OUT" | grep -q "At ${INST_EXPECTED}%" \
  && pass "el installer anuncia los umbrales que realmente instala ($INST_EXPECTED)" \
  || fail "la prosa del installer no coincide con THRESHOLDS=$INST_THRESHOLDS"
echo "$INST_OUT" | grep -q "thresholds: ${INST_THRESHOLDS}" \
  && pass "la confirmación de instalación cita los mismos umbrales" \
  || fail "el resumen de instalación cita otros umbrales"
rm -rf "$INST_HOME"

# ── Cortes anclados en tokens ────────────────────────────────────────────────
# El bug: la evidencia que justifica los cortes está medida en TOKENS (NoLiMa
# dice 32k), pero se implementaron como PORCENTAJES. En 200k coincide de
# casualidad; en 1M el 20% son 200,000 tokens, seis veces pasado el punto donde
# la calidad ya cayó — y la barra decía "tranqui".
TOK_HOME=$(mktemp -d); mkdir -p "$TOK_HOME/.claude"
tok_run() {  # $1=pct  $2=window  $3=tokens
  printf '{"model":{"id":"o"},"workspace":{"current_dir":"/nonexistent-tok"},"cost":{"total_cost_usd":1},"context_window":{"used_percentage":%s,"context_window_size":%s,"total_input_tokens":%s,"total_output_tokens":0},"session_id":"tok"}' "$1" "$2" "$3" \
    | HOME="$TOK_HOME" COLUMNS=80 bash "$SL" 2>/dev/null | sed -n 2p
}

# El caso exacto que motivó el arreglo: 200k tokens en ventana de 1M.
tok_run 20 1000000 200000 | grep -q "qué hacíamos" \
  && pass "1M: 200k tokens marca degradación, no 'tranqui'" \
  || fail "1M: 200k tokens no disparó el tramo por tokens: $(tok_run 20 1000000 200000)"

# El umbral con cita dura: NoLiMa, 32k. En 1M eso es 3.2% de la barra.
tok_run 3 1000000 32000 | grep -q "tranqui" \
  && pass "1M: el corte de NoLiMa (32k) dispara al 3% de la barra" \
  || fail "32k no cruzó el primer tramo en 1M: $(tok_run 3 1000000 32000)"
tok_run 2 1000000 20000 | grep -q "entero activa" \
  && pass "1M: bajo 32k sigue limpio" || fail "disparó antes de los 32k"

# En 200k el comportamiento aprobado NO debe moverse: ahí los porcentajes y los
# tokens están calibrados sobre la misma escala.
tok_run 40 200000 80000  | grep -q "se calienta"   && pass "200k: 40% sigue siendo 🔥"  || fail "200k: cambió el tramo de 40%"
tok_run 75 200000 150000 | grep -q "qué hacíamos"  && pass "200k: 75% sigue siendo 💀"  || fail "200k: cambió el tramo de 75%"
tok_run 10 200000 20000  | grep -q "entero activa" && pass "200k: 10% sigue limpio"     || fail "200k: cambió el tramo bajo"

# El crítico es cercanía al compact, NO degradación: se queda proporcional. Con
# 940k tokens en 1M debe ser 🆘 aunque los cortes por token saturaron hace rato.
tok_run 94 1000000 940000 | grep -q "handoff altiro" \
  && pass "el crítico sigue siendo proporcional a la ventana" || fail "el crítico se rompió"

# Sin los campos de tokens (payload viejo) se deriva del porcentaje: la barra
# no puede quedarse muda ni apagar los cortes por token en silencio.
printf '{"model":{"id":"o"},"workspace":{"current_dir":"/nonexistent-tok"},"cost":{"total_cost_usd":1},"context_window":{"used_percentage":20,"context_window_size":1000000},"session_id":"tok"}' \
  | HOME="$TOK_HOME" COLUMNS=80 bash "$SL" 2>/dev/null | sed -n 2p | grep -q "qué hacíamos" \
  && pass "sin campos de token, se derivan del porcentaje" || fail "payload sin tokens apagó los cortes"

# El monitor tiene que seguir a la barra: si el statusline dice que degradaste,
# el handoff no puede esperar al 60% de una ventana de 1M (= 600k tokens).
[ -f "$TOK_HOME/.claude/ctx/tok.tok" ] \
  && pass "el statusline publica los tokens para el monitor" || fail ".tok no se escribió"
# ── Anclajes por familia de modelo ──────────────────────────────────────────
# El efecto más grande de la evidencia recogida: con la MISMA ventana de 1M,
# Anthropic mide Opus 4.6 en 76% y Sonnet 4.5 en 18,5%. Un solo juego de
# umbrales está garantizado a estar mal para uno de los dos.
tier_run() {  # $1=model  $2=pct  $3=tokens
  printf '{"model":{"id":"%s"},"workspace":{"current_dir":"/nonexistent-tok"},"cost":{"total_cost_usd":1},"context_window":{"used_percentage":%s,"context_window_size":1000000,"total_input_tokens":%s,"total_output_tokens":0},"session_id":"tier"}' "$1" "$2" "$3" \
    | HOME="$TOK_HOME" COLUMNS=80 bash "$SL" 2>/dev/null | sed -n 2p
}
tier_run claude-sonnet-5 25 252000 | grep -q "qué hacíamos" \
  && pass "252k en Sonnet marca degradación fuerte" || fail "sonnet: $(tier_run claude-sonnet-5 25 252000)"
tier_run claude-opus-5 25 252000 | grep -q "qué hacíamos" \
  && fail "opus tratado con la escala conservadora a 252k" \
  || pass "252k en Opus NO marca lo mismo que en Sonnet"
tier_run claude-opus-5 26 260000 | grep -q "me pase po" \
  && pass "Opus: el 🔪 cae en el 256k medido por Anthropic" || fail "opus 260k: $(tier_run claude-opus-5 26 260000)"
tier_run claude-opus-5 40 400000 | grep -q "qué hacíamos" \
  && pass "Opus: 400k sí llega al 💀" || fail "opus 400k no escaló"

# Modelo desconocido → escala conservadora. Avisar de más es preferible a que
# un id nuevo apague los avisos sin que nadie se entere.
tier_run modelo-que-no-existe 25 252000 | grep -q "qué hacíamos" \
  && pass "modelo desconocido usa la escala conservadora" || fail "un id desconocido relajó los umbrales"
tier_run "Opus 4.6" 25 252000 | grep -q "qué hacíamos" \
  && fail "display_name 'Opus 4.6' no fue reconocido como opus" \
  || pass "reconoce la familia también por display_name"

# El conteo de tokens en la línea (opción 1): sin él, "25% — ¿qué hacíamos?"
# se lee como contradicción en vez de como dos hechos distintos.
tier_run claude-sonnet-5 25 252000 | grep -q "252k tok" \
  && pass "la línea muestra el conteo de tokens" || fail "falta el conteo en la línea"
tier_run claude-sonnet-5 1 500 | grep -q "· 500 tok" \
  && pass "bajo 1000 se muestra crudo, no '0k'" || fail "formateo de tokens chicos roto"

[ -f "$TOK_HOME/.claude/ctx/tier.tier" ] \
  && pass "la familia se publica para el monitor" || fail ".tier no se escribió"
# Explícito y en este orden: el archivo refleja la ÚLTIMA corrida, así que la
# aserción tiene que fijar cuál fue en vez de asumirla.
tier_run claude-opus-5 25 252000 > /dev/null
[ "$(cat "$TOK_HOME/.claude/ctx/tier.tier")" = "opus" ] \
  && pass ".tier dice opus tras una corrida de Opus" || fail ".tier no siguió al modelo"
tier_run claude-sonnet-5 25 252000 > /dev/null
[ "$(cat "$TOK_HOME/.claude/ctx/tier.tier")" = "std" ] \
  && pass ".tier vuelve a std tras una corrida de Sonnet" || fail ".tier se quedó pegado en opus"

rm -rf "$TOK_HOME"

rm -rf "$SL_HOME"

# ── Test 10: install.sh registers refreshInterval ────────────────────────────
# Without it Claude Code re-renders the statusline only after each assistant
# message, so the 5h countdown freezes mid-window and reads as a broken clock —
# a failure that looks identical to "the feature was never installed".
echo "10. install.sh refreshInterval (keeps the countdown live)"

RI_HOME=$(mktemp -d)
ri_interval() {  # prints the configured refreshInterval, or "unset"
  python3 - "$RI_HOME/.claude/settings.json" <<'PYEOF'
import json, sys
sl = json.load(open(sys.argv[1])).get('statusLine', {})
print(sl.get('refreshInterval', 'unset'))
PYEOF
}

HOME="$RI_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1 || true
[ "$(ri_interval)" = "10" ] \
  && pass "fresh install sets refreshInterval=10" || fail "fresh install left refreshInterval=$(ri_interval)"

# v0.3 upgrade path: our statusline is already registered but predates the countdown
python3 - "$RI_HOME/.claude/settings.json" <<'PYEOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s['statusLine'].pop('refreshInterval', None)
json.dump(s, open(p, 'w'), indent=2)
PYEOF
HOME="$RI_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1 || true
[ "$(ri_interval)" = "10" ] \
  && pass "upgrade adds refreshInterval to an existing install" || fail "upgrade left refreshInterval=$(ri_interval)"

# An interval the user picked is theirs — reinstalling must not overwrite it
python3 - "$RI_HOME/.claude/settings.json" <<'PYEOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s['statusLine']['refreshInterval'] = 1
json.dump(s, open(p, 'w'), indent=2)
PYEOF
HOME="$RI_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1 || true
[ "$(ri_interval)" = "1" ] \
  && pass "a user-chosen refreshInterval is preserved" || fail "clobbered the user's refreshInterval (now $(ri_interval))"

rm -rf "$RI_HOME"

# ── Test 11: statusline caches (git part + housekeeping sweep) ───────────────
# A cache that never refreshes and a sweep that never runs both fail silently:
# the statusline keeps rendering, just with a frozen branch or a directory that
# grows forever. Both directions are asserted here.
echo "11. statusline caches: git part & housekeeping throttle"

CA_HOME=$(mktemp -d)
mkdir -p "$CA_HOME/.claude"
CA_CTX="$CA_HOME/.claude/ctx"
ca_payload() {
  printf '{"model":{"id":"opus"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":1.0},"context_window":{"used_percentage":42},"session_id":"ca1"}' \
    "$SCRIPT_DIR"
}
ca_run() { ca_payload | HOME="$CA_HOME" bash "$SCRIPT_DIR/hooks/statusline-context.sh" 2>/dev/null; }

ca_run > /dev/null
CA_GIT=$(find "$CA_CTX" -name 'gitpart_*' 2>/dev/null | head -1)
[ -n "$CA_GIT" ] && pass "git part cache file created" || fail "no gitpart_* cache written"

# Fresh timestamp + a sentinel payload: if the cache is really consulted, the
# sentinel comes back out instead of the real branch.
printf '%s|%s' "$(date +%s)" " | SENTINEL-CACHED" > "$CA_GIT"
CA_OUT=$(ca_run)
echo "$CA_OUT" | grep -q 'SENTINEL-CACHED' \
  && pass "fresh cache is reused instead of forking git" || fail "cache ignored — git ran anyway"

# Same sentinel, timestamp aged past GIT_TTL: it must be recomputed, not served.
printf '%s|%s' "0" " | SENTINEL-CACHED" > "$CA_GIT"
CA_OUT=$(ca_run)
echo "$CA_OUT" | grep -q 'SENTINEL-CACHED' \
  && fail "stale cache served — git part would freeze forever" \
  || pass "stale cache is recomputed"

# A corrupt timestamp must degrade to a miss, never render a torn value.
printf '%s' "garbage-no-separator" > "$CA_GIT"
CA_OUT=$(ca_run)
echo "$CA_OUT" | grep -q 'garbage' \
  && fail "corrupt cache leaked into the statusline" || pass "corrupt cache treated as a miss"

# Housekeeping: the sweep still deletes day-old state when the stamp is stale...
touch -t 200001010000 "$CA_CTX/zombie.pct"
# Un sentinel por cada prefijo que el barrido dice cubrir. Si alguien agrega un
# tipo de archivo de sesión y se olvida del glob, se acumula para siempre en el
# ~/.claude del usuario y nadie se entera: no rompe nada, solo crece.
touch -t 200001010000 "$CA_CTX/zombie.compact" "$CA_CTX/handoff_w60_zombie" \
                      "$CA_CTX/effort_w50_zombie" "$CA_CTX/gitpart_zombie"
printf '%s' "0" > "$CA_CTX/.housekeeping"
ca_run > /dev/null
[ -f "$CA_CTX/zombie.pct" ] \
  && fail "stale stamp did not trigger the sweep" || pass "stale stamp triggers the sweep"
CA_LEFT=$(find "$CA_CTX" \( -name 'zombie.compact' -o -name 'handoff_w60_zombie' \
                          -o -name 'effort_w50_zombie' -o -name 'gitpart_zombie' \) 2>/dev/null | wc -l | tr -d ' ')
[ "$CA_LEFT" -eq 0 ] \
  && pass "el barrido cubre todos los prefijos de estado de sesión" \
  || fail "$CA_LEFT archivo(s) de sesión sobrevivieron al barrido"

# ...and is skipped while the stamp is fresh, which is the whole point.
touch -t 200001010000 "$CA_CTX/zombie2.pct"
printf '%s' "$(date +%s)" > "$CA_CTX/.housekeeping"
ca_run > /dev/null
[ -f "$CA_CTX/zombie2.pct" ] \
  && pass "fresh stamp skips the sweep" || fail "sweep ran despite a fresh stamp"

rm -rf "$CA_HOME"

# ── Presupuesto de sesión (API key) ───────────────────────────────────────────
echo ""
echo "Presupuesto de sesión (API key)"

# Payload de API key: sin bloque rate_limits, que es exactamente lo que
# distingue una sesión con key de una con suscripción.
sl_budget() {
  printf '{"model":{"id":"o"},"workspace":{"current_dir":"/nonexistent-cb"},"cost":{"total_cost_usd":%s},"context_window":{"used_percentage":42},"session_id":"cb"}' "$1" \
    | HOME="$SL_HOME" COST_BUDGET="$2" bash "$SL" 2>/dev/null
}

out=$(sl_budget 12.34 100)
echo "$out" | grep -q '12%' \
  && pass "el gasto de sesión se pinta como % del presupuesto" \
  || fail "porcentaje de presupuesto mal calculado"
# El gasto y el techo van literales al lado de la barra: un porcentaje solo no
# dice si el 12% son doce dólares o doce centavos.
# shellcheck disable=SC2016  # $100 es el literal que buscamos, no una expansión
echo "$out" | grep -q '12.34 / \$100' \
  && pass "muestra el monto gastado y el presupuesto" \
  || fail "no muestra monto/presupuesto"

# Sin presupuesto no hay línea: un porcentaje contra un techo inventado es peor
# que no tener porcentaje.
sl_budget 12.34 0 | grep -q 'Presupuesto' \
  && fail "pintó la línea con COST_BUDGET=0" \
  || pass "sin presupuesto configurado no se pinta la línea"

# La regresión que importa: con suscripción el costo es nocional y el límite
# real es la ventana. Si esta línea aparece ahí, está midiendo plata que nadie
# paga.
printf '{"model":{"id":"o"},"workspace":{"current_dir":"/nonexistent-cb"},"cost":{"total_cost_usd":40},"context_window":{"used_percentage":42},"session_id":"cb2","rate_limits":{"five_hour":{"used_percentage":83,"resets_at":%s}}}' "$(( $(date +%s) + 9000 ))" \
  | HOME="$SL_HOME" COST_BUDGET=100 bash "$SL" 2>/dev/null | grep -q 'Presupuesto' \
  && fail "pintó presupuesto en una sesión con rate_limits" \
  || pass "no se pinta presupuesto cuando hay cupos (suscripción)"

# Sobregiro: el porcentaje pasa de 100 pero la barra satura. Recortar el
# número borraría la diferencia entre ir justo y haberse pasado al doble.
out=$(sl_budget 118.75 100)
echo "$out" | grep -q '118%' \
  && pass "el sobregiro se reporta por encima de 100%" \
  || fail "el porcentaje se recortó a 100"
# Solo la línea de presupuesto: la de contexto también dibuja barra, y
# `grep -c` cuenta líneas con coincidencia, no coincidencias.
bar=$(echo "$out" | grep 'Presupuesto' | grep -c '░' || true)
[ "$bar" = "0" ] \
  && pass "la barra satura en lleno al pasarse" \
  || fail "la barra dejó huecos con el presupuesto excedido"
echo "$out" | grep -q 'te pasaste' \
  && pass "el sobregiro tiene su propio aviso" \
  || fail "el sobregiro reusa el mensaje del 90%"

# Un cost ausente o basura no debe reventar la aritmética ni pintar un número
# inventado — el statusline entero se caería con set -u sobre una variable rota.
printf '{"model":{"id":"o"},"workspace":{"current_dir":"/nonexistent-cb"},"context_window":{"used_percentage":42},"session_id":"cb3"}' \
  | HOME="$SL_HOME" COST_BUDGET=100 bash "$SL" 2>/dev/null | grep -q '0%' \
  && pass "un payload sin cost no rompe la línea" \
  || fail "payload sin cost rompió el presupuesto"

# ── Cupo mensual (endpoint propio) ────────────────────────────────────────────
echo ""
echo "Cupo mensual (endpoint de consumo)"

U_HOME=$(mktemp -d)
mkdir -p "$U_HOME/.claude"
U_PAYLOAD='{"model":{"id":"o"},"workspace":{"current_dir":"/nonexistent-um"},"cost":{"total_cost_usd":0.5},"context_window":{"used_percentage":12},"session_id":"um"}'

# Render determinista: la caché se siembra a mano y el TTL se pone absurdamente
# alto para que NINGÚN fetch se dispare. Así estas aserciones no dependen de la
# red, del reloj, ni de que un hijo en segundo plano alcance a terminar.
u_seed() {  # $1 = json de .data, $2 = ok, $3 = error, $4 = antigüedad en segundos
  jq -n -c --argjson d "$1" --argjson ok "$2" --arg e "$3" \
           --argjson at "$(( $(date +%s) - ${4:-0} ))" \
    '{ok:$ok, checked_at:$at, fetched_at:(if $ok then $at else 0 end), error:$e, data:$d}' \
    > "$U_HOME/.claude/usage.json"
}
u_seed_err_with_data() {  # error PERO conservando un dato previo de $2 segundos atrás
  jq -n -c --argjson d "$1" --arg e "$2" \
           --argjson now "$(date +%s)" --argjson old "$(( $(date +%s) - ${3:-60} ))" \
    '{ok:false, checked_at:$now, fetched_at:$old, error:$e, data:$d}' \
    > "$U_HOME/.claude/usage.json"
}
u_render() { echo "$U_PAYLOAD" | HOME="$U_HOME" COLUMNS=80 USAGE_TTL=999999 USAGE_URL="${1:-file:///dev/null}" bash "$SL" 2>/dev/null | grep 'Cupo mensual' || true; }

# La regresión que más importa: sin endpoint configurado esto no existe. Ni la
# línea, ni la consulta, ni un archivo de caché. Instalar la nueva versión sin
# tocar nada tiene que dejar el statusline byte por byte como estaba.
NO_URL=$(echo "$U_PAYLOAD" | HOME="$U_HOME" COLUMNS=80 bash "$SL" 2>/dev/null)
echo "$NO_URL" | grep -q 'Cupo mensual' \
  && fail "pintó la línea sin USAGE_URL configurado" \
  || pass "sin endpoint configurado no se pinta la línea"

# La respuesta documentada del endpoint, tal cual.
u_seed '{"month":"2026-09","spentUsd":1.12,"limitUsd":100,"remainingUsd":98.88,"percentUsed":1.1,"blocked":false}' true "" 0
out=$(u_render)
echo "$out" | grep -q '1%' \
  && pass "porcentaje mensual del endpoint" || fail "porcentaje mensual mal leído"
# shellcheck disable=SC2016  # $1.12 y $100 son literales que buscamos, no expansiones
echo "$out" | grep -q '\$1.12 / \$100' \
  && pass "gasto y límite en la línea" || fail "falta gasto/límite"
# shellcheck disable=SC2016
echo "$out" | grep -q 'queda \$98.88' \
  && pass "crédito restante en la línea" || fail "falta el restante"

# percentUsed ausente: se calcula de spent/limit en vez de rendirse. Un endpoint
# que no manda el porcentaje sigue teniendo toda la información para pintarlo.
u_seed '{"spentUsd":50,"limitUsd":200}' true "" 0
out=$(u_render)
echo "$out" | grep -q '25%' \
  && pass "porcentaje derivado cuando el endpoint no lo manda" \
  || fail "no derivó el porcentaje de spent/limit"

# blocked es un estado, no un tramo: manda por sobre el porcentaje. Una cuenta
# bloqueada al 12% no puede pintarse "tranqui, queda mes".
u_seed '{"spentUsd":12,"limitUsd":100,"percentUsed":12,"blocked":true}' true "" 0
out=$(u_render)
echo "$out" | grep -q '🚫' \
  && pass "blocked manda por sobre el porcentaje" || fail "blocked ignorado"
echo "$out" | grep -q 'tranqui, queda mes' \
  && fail "una cuenta bloqueada se pintó como tranquila" \
  || pass "blocked no reusa el mensaje del tramo bajo"

# EL fallo silencioso. Una línea que se apaga al fallar es indistinguible de una
# que nunca se configuró: el día que el token deje de renovarse, nadie se entera.
u_seed 'null' false "HTTP 401 — token rechazado" 0
out=$(u_render)
[ -n "$out" ] \
  && pass "un error NO borra la línea" || fail "la línea desapareció al fallar"
echo "$out" | grep -q '401' \
  && pass "el error dice cuál fue" || fail "el error no se identifica"

# El último dato bueno sobrevive al error, y el error se anexa en vez de
# reemplazarlo: se ve el número Y que ya no es de fiar.
u_seed_err_with_data '{"spentUsd":40,"limitUsd":100,"percentUsed":40}' "HTTP 401 — token rechazado" 60
out=$(u_render)
echo "$out" | grep -q '40%' \
  && pass "el último dato bueno sobrevive al error" || fail "el error tiró el dato previo"
echo "$out" | grep -q '⚠' \
  && pass "el dato viejo viene marcado como no confiable" || fail "dato stale sin marca"

# Dato viejo aunque el fetch diga OK: si el reloj avanzó y nadie refrescó, la
# línea lo confiesa. Un número de hace media hora pintado como fresco miente.
u_seed '{"spentUsd":40,"limitUsd":100,"percentUsed":40}' true "" 3600
out=$(u_render)
echo "$out" | grep -q 'dato de hace 1h00m' \
  && pass "un dato añejo declara su edad" || fail "dato añejo se pintó como fresco"

# ── El camino real: fetch, caché y validación de la respuesta ────────────────
# file:// en vez de red: ejercita curl, el lock, la escritura atómica y el
# parseo sin depender de que el runner del CI tenga salida a internet.
U_LOCK="$U_HOME/.claude/ctx/.usage.lock"
u_fetch() {  # $1 = url · UNA consulta, y se espera a que el hijo termine
  rm -rf "$U_LOCK"; rm -f "$U_HOME/.claude/usage.json"
  # Un solo render: sin caché el primero siempre dispara el fetch. Renderizar
  # en bucle con TTL=0 lanzaba varias consultas a la vez y una rezagada pisaba
  # el archivo DESPUÉS del rm del caso siguiente — el test se contaminaba solo.
  echo "$U_PAYLOAD" | HOME="$U_HOME" COLUMNS=80 USAGE_TTL=0 USAGE_URL="$1" bash "$SL" >/dev/null 2>&1
  # El hijo escribe la caché y recién después suelta el lock: esperar al lock
  # garantiza que no queda ningún fetch en vuelo. La espera es acotada, así que
  # un lock que de verdad se trabe sigue fallando el test de abajo.
  local n=0
  while [ -d "$U_LOCK" ] && [ "$n" -lt 40 ]; do sleep 0.25; n=$((n+1)); done
  [ -f "$U_HOME/.claude/usage.json" ]
}

echo '{"spentUsd":7.5,"limitUsd":50,"percentUsed":15}' > "$U_HOME/real.json"
if u_fetch "file://$U_HOME/real.json"; then
  pass "el fetch en segundo plano escribe la caché"
  jq -e '.ok == true and .data.spentUsd == 7.5' "$U_HOME/.claude/usage.json" >/dev/null 2>&1 \
    && pass "la caché guarda la respuesta del endpoint" || fail "caché con contenido incorrecto"
else
  fail "el fetch en segundo plano nunca escribió la caché"
  fail "la caché guarda la respuesta del endpoint (no ejecutado)"
fi

# Un 401 devuelve JSON VÁLIDO: {"message":"Unauthorized"}. Que parsee no prueba
# nada. Sin este chequeo el render pintaría un 0% inventado con cara de dato
# real — el peor resultado posible de los tres.
echo '{"message":"Unauthorized"}' > "$U_HOME/junk.json"
if u_fetch "file://$U_HOME/junk.json"; then
  jq -e '.ok == false' "$U_HOME/.claude/usage.json" >/dev/null 2>&1 \
    && pass "una respuesta sin campos de cupo se trata como error" \
    || fail "aceptó como válida una respuesta sin campos de cupo"
  out=$(u_render)
  echo "$out" | grep -q '0%' \
    && fail "pintó un 0% inventado con una respuesta inválida" \
    || pass "no inventa un 0% cuando la respuesta no sirve"
else
  fail "no se escribió caché para la respuesta inválida"
  fail "no inventa un 0% (no ejecutado)"
fi

# El endpoint inalcanzable no puede colgar el render ni dejar el lock tomado:
# un lock huérfano congelaría la línea para siempre.
u_fetch "file://$U_HOME/no-existe.json" >/dev/null 2>&1 || true
[ ! -d "$U_LOCK" ] \
  && pass "el lock se libera aunque el fetch falle" || fail "quedó un lock huérfano"

# El token no puede ir en argv: `curl(1) -H "Bearer ..."` lo deja a la vista de
# cualquier `ps` de la máquina. Se exige la forma con archivo de config.
grep -qE 'curl[[:space:]]-K' "$SL" \
  && pass "la credencial va por archivo de config, no por argv" \
  || fail "el token podría estar viajando en la línea de comandos"
grep -qE 'curl[[:space:]].*-H[[:space:]].*Authorization' "$SL" \
  && fail "hay un header con credencial en argv" \
  || pass "ningún header con credencial en argv"

# El installer inyecta la URL SIN matar el override por entorno: cambiar de
# endpoint no puede obligar a reinstalar.
UI_HOME=$(mktemp -d)
HOME="$UI_HOME" HANDOFF_USAGE_URL="https://ejemplo.test/usage" \
  HANDOFF_USAGE_TOKEN_CMD="mi-token" bash "$SCRIPT_DIR/install.sh" >/dev/null 2>&1 </dev/null || true
UI_SL="$UI_HOME/.claude/hooks/statusline-context.sh"
# shellcheck disable=SC2016  # ${USAGE_URL:-...} es el literal que debe estar en el archivo
grep -q '^USAGE_URL=${USAGE_URL:-https://ejemplo.test/usage}' "$UI_SL" \
  && pass "el installer inyecta la URL conservando el override" \
  || fail "la URL inyectada no conserva el override por entorno"
# shellcheck disable=SC2016  # idem: literal, no expansión
grep -q '^USAGE_TOKEN_CMD=${USAGE_TOKEN_CMD:-mi-token}' "$UI_SL" \
  && pass "el installer inyecta el comando de token" \
  || fail "comando de token no inyectado"

# Sin endpoint el installer deja las variables vacías — instalar no puede
# encender una feature que nadie pidió.
UI2_HOME=$(mktemp -d)
HOME="$UI2_HOME" bash "$SCRIPT_DIR/install.sh" >/dev/null 2>&1 </dev/null || true
grep -q "^USAGE_URL=\${USAGE_URL:-''}" "$UI2_HOME/.claude/hooks/statusline-context.sh" \
  && pass "sin endpoint el installer deja la feature apagada" \
  || fail "el installer encendió el endpoint sin configuración"

# El prompt sólo puede existir con terminal en los DOS extremos, y un EOF ahí
# no puede matar la instalación. `read` devuelve 1 al recibir EOF (Ctrl-D, o un
# stdin cerrado) y bajo `set -e` eso abortaba el installer justo después de
# anunciar que instalaba y antes de copiar un solo archivo. Se prueba con un pty
# de verdad: sin terminal el prompt ni siquiera se evalúa y el bug no aparece.
UI3_HOME=$(mktemp -d)
UI3_OUT=$(HOME="$UI3_HOME" python3 - "$SCRIPT_DIR" <<'PY'
import os, pty, select, subprocess, sys, time
m, s = pty.openpty()
p = subprocess.Popen(["bash", "install.sh"], cwd=sys.argv[1],
                     stdin=s, stdout=s, stderr=s, close_fds=True)
os.close(s)
os.close(os.dup(m)); os.write(m, b"\x04")   # EOF inmediato en el primer prompt
deadline = time.time() + 60
while time.time() < deadline and p.poll() is None:
    r, _, _ = select.select([m], [], [], 0.4)
    if r:
        try:
            if not os.read(m, 4096):
                break
        except OSError:
            break
p.wait(timeout=15)
print(p.returncode)
PY
)
[ "$UI3_OUT" = "0" ] \
  && pass "un EOF en el prompt no aborta la instalación" \
  || fail "el installer murió con un EOF en el prompt (rc=$UI3_OUT)"
[ -f "$UI3_HOME/.claude/hooks/statusline-context.sh" ] \
  && pass "tras el EOF los archivos igual quedan instalados" \
  || fail "el EOF dejó la instalación a medias"

rm -rf "$UI3_HOME"
rm -rf "$U_HOME" "$UI_HOME" "$UI2_HOME"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
