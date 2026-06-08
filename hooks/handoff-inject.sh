#!/usr/bin/env bash
[ -f /tmp/handoff_pending ] || exit 0
rm -f /tmp/handoff_pending
echo '{"additionalContext": "HANDOFF REQUESTED — genera el snapshot ahora."}'
