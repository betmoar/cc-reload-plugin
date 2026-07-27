#!/usr/bin/env bash
#
# cc-reload PreToolUse hook — the enforcement point for the ownership guard.
#
# Fires before the MODEL's Write/Edit is processed. Both paths that can clobber
# the digest end in the model calling Write, so a check reached by a documented
# step ("run this first") is skippable by the actor it polices — and its unit
# tests would pass green over the unguarded live path. This hook is what makes
# the guard unskippable for the built-in file tools.
# See docs/spec/concurrent-sessions.md §4.3 (and §4.4 for what it does NOT cover:
# a digest written via a Bash heredoc bypasses PreToolUse entirely).
#
# ALWAYS exits 0 — permits the write. It must never block a snapshot.
#
source "$(dirname "$0")/lib.sh"
repete_active && exit 0

HOOK_INPUT="$(cat)"

# matcher filters on TOOL NAME only, so path scoping happens here. Anything that
# is not a write to OUR digest is none of our business — leave silently.
FILE="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)" || exit 0
[ -n "$FILE" ] || exit 0

# Compare RESOLVED paths, not strings. A symlinked .reload/, a symlinked
# worktree, or a relative file_path would all miss a string compare — and a
# guard that silently fails to fire is worse than no guard, since the user
# believes they are covered. `cd … && pwd -P` is the portable resolver;
# macOS has no `readlink -f`.
_resolve() { # _resolve <path> -> absolute, symlinks resolved; empty if the dir is gone
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  d="$(cd "$d" 2>/dev/null && pwd -P)" || return 0
  printf '%s/%s' "$d" "$b"
}
[ "$(_resolve "$FILE")" = "$(_resolve "$DIGEST")" ] || exit 0

TOOL="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL" in Write|Edit) ;; *) exit 0 ;; esac

SID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -n "$SID" ] || exit 0    # no runtime identity on this path -> undetectable

# Path via $0, NOT the plugin-root env var hooks.json exports for the command
# line: under `set -u` an unexported variable is a fatal unbound error, which
# would make this hook exit non-zero — the one outcome its contract forbids.
# No production hook in this plugin references that var directly; only the
# test harness sets it. $0 is always defined.
bash "$(dirname "$0")/../scripts/claim-digest.sh" "$SID" 2>/dev/null
exit 0
