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
rm -f "/tmp/handoff_w70_$SID" "/tmp/handoff_w80_$SID" "/tmp/handoff_w90_$SID"

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

echo "72" > "$FAKE_HOME/.claude/ctx/$SID.pct"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "70% + Yes → block with HANDOFF REQUESTED" || fail "no block at 70%: $OUT"

# Sentinel written under ~/.claude/ctx (owned, not world-writable) — NOT /tmp
[ -f "$FAKE_HOME/.claude/ctx/handoff_w70_$SID" ] \
  && pass "sentinel in ~/.claude/ctx (not /tmp)" || fail "sentinel not in ctx dir"
[ ! -f "/tmp/handoff_w70_$SID" ] \
  && pass "no sentinel leaked to /tmp"           || fail "sentinel still written to /tmp"

OUT=$(run_monitor)
[ -z "$OUT" ] && pass "70% alert consumed — no repeat" || fail "alert repeated at same level: $OUT"

echo "85" > "$FAKE_HOME/.claude/ctx/$SID.pct"
OUT=$(run_monitor)
echo "$OUT" | grep -q "HANDOFF REQUESTED" \
  && pass "next threshold (80%) fires again" || fail "80% threshold did not fire: $OUT"

make_dialogs No
echo "95" > "$FAKE_HOME/.claude/ctx/$SID.pct"
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "90% + No → no block" || fail "block emitted after No: $OUT"

make_dialogs Yes
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "No consumed the 90% alert" || fail "90% alert re-fired after No: $OUT"

# per-session pct: another session's percentage must not trigger this session
SID2="handofftest2$$"
rm -f "/tmp/handoff_w70_$SID2" "/tmp/handoff_w80_$SID2" "/tmp/handoff_w90_$SID2"
echo "10" > "$FAKE_HOME/.claude/ctx/$SID2.pct"
echo "99" > "$FAKE_HOME/.claude/ctx/$SID.pct"
INPUT=$(printf '{"session_id": "%s", "cwd": "%s"}' "$SID2" "$PWD")
OUT=$(run_monitor)
[ -z "$OUT" ] && pass "session reads its own pct (no cross-session trigger)" || fail "cross-session pct leak: $OUT"

rm -f /tmp/handoff_w70_"$SID"* /tmp/handoff_w80_"$SID"* /tmp/handoff_w90_"$SID"* \
      "/tmp/handoff_w70_$SID2" "/tmp/handoff_w80_$SID2" "/tmp/handoff_w90_$SID2"
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

sl_run "$(sl_payload_rel 10020 58)" | grep -q '58% — 2h47m —' \
  && pass "countdown >1h renders as 2h47m" || fail "countdown >1h wrong"
sl_run "$(sl_payload_rel 2580 91)"  | grep -q '91% — 43m —' \
  && pass "countdown <1h renders as 43m"   || fail "countdown <1h wrong"
sl_run "$(sl_payload_rel 30 91)"    | grep -q '91% — <1m —' \
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

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
