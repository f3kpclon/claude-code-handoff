#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# ── Test 1: snapshot save logic ───────────────────────────────────────────────
echo "1. Snapshot save logic"

FAKE_REPO=$(mktemp -d)
HDIR="$FAKE_REPO/.claude/handoffs"
mkdir -p "$HDIR"
TS=$(date '+%Y-%m-%d_%H%M')
SNAPSHOT="# Handoff Snapshot\n**Fecha:** 2026-01-01\n## Objetivo\nTest"

printf "%b" "$SNAPSHOT" > "$HDIR/$TS.md"
cp "$HDIR/$TS.md" "$HDIR/latest.md"

grep -qF '.claude/handoffs/' "$FAKE_REPO/.gitignore" 2>/dev/null \
  || echo '.claude/handoffs/' >> "$FAKE_REPO/.gitignore"

[ -f "$HDIR/$TS.md" ]      && pass "snapshot file created"      || fail "snapshot file missing"
[ -f "$HDIR/latest.md" ]   && pass "latest.md created"          || fail "latest.md missing"
grep -qF '.claude/handoffs/' "$FAKE_REPO/.gitignore" \
                            && pass ".gitignore updated"          || fail ".gitignore not updated"

# idempotent: running again should not duplicate the gitignore entry
grep -qF '.claude/handoffs/' "$FAKE_REPO/.gitignore" 2>/dev/null \
  || echo '.claude/handoffs/' >> "$FAKE_REPO/.gitignore"
COUNT=$(grep -c '.claude/handoffs/' "$FAKE_REPO/.gitignore")
[ "$COUNT" -eq 1 ]         && pass ".gitignore entry not duplicated" || fail ".gitignore has duplicate entry ($COUNT)"

rm -rf "$FAKE_REPO"

# ── Test 2: install.sh copies all required files ─────────────────────────────
echo "2. install.sh file copies"

FAKE_HOME=$(mktemp -d)
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1 || true

[ -f "$FAKE_HOME/.claude/commands/handoff.md" ]          && pass "handoff.md installed"          || fail "handoff.md missing"
[ -f "$FAKE_HOME/.claude/hooks/handoff-monitor.sh" ]     && pass "handoff-monitor.sh installed"  || fail "handoff-monitor.sh missing"
[ -f "$FAKE_HOME/.claude/hooks/handoff-inject.sh" ]      && pass "handoff-inject.sh installed"   || fail "handoff-inject.sh missing"
[ -f "$FAKE_HOME/.claude/hooks/statusline-context.sh" ]  && pass "statusline-context.sh installed" || fail "statusline-context.sh missing"
[ -x "$FAKE_HOME/.claude/hooks/handoff-monitor.sh" ]     && pass "hooks are executable"          || fail "hooks not executable"
[ -f "$FAKE_HOME/.claude/settings.json" ]                && pass "settings.json created"         || fail "settings.json missing"

# hooks must be registered in settings.json
grep -q "handoff-monitor.sh" "$FAKE_HOME/.claude/settings.json" \
                                                          && pass "Stop hook registered"          || fail "Stop hook not in settings.json"
grep -q "handoff-inject.sh"  "$FAKE_HOME/.claude/settings.json" \
                                                          && pass "UserPromptSubmit hook registered" || fail "UserPromptSubmit hook not in settings.json"

# install must be idempotent — run twice, no duplicates
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" > /dev/null 2>&1 || true
STOP_COUNT=$(grep -c "handoff-monitor.sh" "$FAKE_HOME/.claude/settings.json")
[ "$STOP_COUNT" -eq 1 ] && pass "install is idempotent (no duplicate hooks)" || fail "duplicate hooks after re-install ($STOP_COUNT)"

rm -rf "$FAKE_HOME"

# ── Test 3: handoff-inject.sh sentinel behavior ───────────────────────────────
echo "3. handoff-inject.sh sentinel"

rm -f /tmp/handoff_pending
OUTPUT=$(echo '{}' | bash "$SCRIPT_DIR/hooks/handoff-inject.sh" 2>/dev/null)
[ -z "$OUTPUT" ] && pass "no sentinel → no output" || fail "output emitted without sentinel: $OUTPUT"

touch /tmp/handoff_pending
OUTPUT=$(echo '{}' | bash "$SCRIPT_DIR/hooks/handoff-inject.sh" 2>/dev/null)
echo "$OUTPUT" | grep -q "HANDOFF REQUESTED" \
               && pass "sentinel present → HANDOFF REQUESTED injected" || fail "sentinel present but wrong output: $OUTPUT"
[ ! -f /tmp/handoff_pending ] \
               && pass "sentinel removed after inject" || fail "sentinel not removed"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
