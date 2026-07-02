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
git -C "$FAKE_REPO" commit --allow-empty -m "init" 2>/dev/null || true

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

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
