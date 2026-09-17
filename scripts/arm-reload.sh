#!/usr/bin/env bash
#
# arm-reload.sh — arm a reload for THIS session's lineage. The one arm writer
# reachable from command prose; the hooks call the same arm_reload() in lib.sh.
#
# Usage: arm-reload.sh <session-id>      (empty id -> an un-owned arm, still armed)
# Exit:  0 armed (a reader will find it: -f verified), 1 NOT armed (message on stdout)
#
# Writes .reload/pending.<CLAUDE_PID> when Claude Code exported its pid (it does,
# measured on 2.1.274), else the legacy bare .reload/pending. Journals the arm.
# Needs no jq, so the jq guard in lib.sh is opted out — this script must never
# skip the arm silently when jq is missing, because /snapshot reports "armed"
# from its exit status.
set -uo pipefail
CC_RELOAD_NO_JQ_OK=1
export CC_RELOAD_NO_JQ_OK
source "$(dirname "$0")/../hooks/lib.sh"
if arm_reload "${1:-}"; then
  exit 0
fi
printf 'cc-reload: reload NOT armed — %s is not a writable regular file. Remove whatever is there, then run /snapshot again.\n' "$(arm_path)"
exit 1
