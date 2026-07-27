#!/usr/bin/env bash
#
# claim-digest.sh — the concurrent-session guard's comparator.
#
# Called with the WRITING session's id, immediately before something overwrites
# .reload/session.md. If the digest on disk is owned by a DIFFERENT session and
# was written recently, copy it aside so the incumbent's work is recoverable,
# and say so. Then get out of the way: the caller does the actual write.
#
# EXITS 0 UNCONDITIONALLY. This runs in front of the user's snapshot; a guard
# that can fail the write it guards is worse than the data loss it prevents
# (docs/spec/concurrent-sessions.md §4.2.2). cc-operator's equivalent sentinel
# fails CLOSED because it guards a gate; this one fails OPEN because it guards
# a convenience. That divergence is deliberate — see spec §4.2.1.
#
# On "unconditionally": lib.sh is SOURCED and its `command -v jq || exit 0`
# (lib.sh:24) exits THIS script — with 0, which is the contract, not a violation.
# That is the intended landmine (CLAUDE.md "known landmines"): no jq, no guard,
# no noise. Do not "fix" it into a `return`.
#
# Usage: claim-digest.sh <writer-session-id>
set -uo pipefail

source "$(dirname "$0")/../hooks/lib.sh"
repete_active && exit 0    # cc-repete owns continuity while a loop is live

WRITER="${1:-}"

# Nothing to protect, or nothing to compare with: proceed silently. An empty
# writer id means the runtime gave this path no identity — UNDETECTABLE, which
# the spec (§4.4 limit 1) states as a known coverage gap rather than hiding.
[ -f "$DIGEST" ] || exit 0
[ -n "$WRITER" ] || exit 0

INCUMBENT="$(digest_owner)"
[ -n "$INCUMBENT" ] || exit 0                 # un-owned: pre-0.3 or hand-written
[ "$INCUMBENT" != "$WRITER" ] || exit 0       # our own digest

WINDOW="$(owner_window)"
[ "$WINDOW" -gt 0 ] || exit 0                 # explicitly disabled

# Recency from FILESYSTEM MTIME, not the frontmatter updated_at: mtime is
# written by the OS, updated_at by a model that may omit or staledate it. The
# precedent is stop-hook.sh:50 (`-nt`). `stat -f %m` is the BSD/macOS form.
MTIME="$(stat -f %m "$DIGEST" 2>/dev/null || stat -c %Y "$DIGEST" 2>/dev/null)" || exit 0
[ -n "$MTIME" ] || exit 0
NOW="$(date +%s)"
AGE=$(( NOW - MTIME ))
[ "$AGE" -lt "$WINDOW" ] || exit 0             # stale: assume the owner is gone

# A foreign, live digest. Preserve it, then let the caller overwrite.
ensure_reload_dir

# The incumbent id comes from model-written frontmatter and is interpolated into
# a PATH. Anything outside [A-Za-z0-9_-] is stripped, so `../../x` cannot escape
# .reload/ — cc-operator hit exactly this door (ops-verdict.sh:276, the
# 2026-07-10 traversal). A real session id is a UUID and survives untouched.
SAFE_ID="$(printf '%s' "$INCUMBENT" | tr -cd 'A-Za-z0-9_-')"
[ -n "$SAFE_ID" ] || SAFE_ID="unknown"

SIDE="$RELOAD_DIR/session.$SAFE_ID.md"
if [ -e "$SIDE" ]; then
  # /snapshot reaches this comparator twice for one write (the command's own
  # courtesy call, then PreToolUse on the Write it triggers). If the existing
  # side-file already holds these exact bytes, this claim was already preserved
  # — exit silently instead of stamping a second, mtime-suffixed copy and a
  # second warning for what is really one collision. `cmp -s` is the portable
  # byte-identical test (no GNU-only flags). Genuinely different content (a
  # THIRD session, or the incumbent changed between calls) still falls through
  # to the suffixed name below — that branch is for real collisions, not kept.
  cmp -s "$DIGEST" "$SIDE" && exit 0
  SIDE="$RELOAD_DIR/session.$SAFE_ID.$MTIME.md"
fi

# Two sessions can reach here at the same instant: a bare `[ -e ] && cp` is
# TOCTOU, and both would cp to the same path, truncating the copy that exists to
# prevent exactly this loss. Write to a pid-unique temp, then mv — atomic on
# POSIX within one filesystem, and no lock a fail-open guard could hang on.
TMP_SIDE="$SIDE.tmp.$$"
if cp "$DIGEST" "$TMP_SIDE" 2>/dev/null && mv "$TMP_SIDE" "$SIDE" 2>/dev/null; then
  printf 'cc-reload: .reload/session.md belongs to a different session (%s) and was written %ds ago. Saved it to %s before overwriting. Two sessions are sharing this directory — see README "Known limitations".\n' \
    "$INCUMBENT" "$AGE" "$SIDE"
else
  rm -f "$TMP_SIDE" 2>/dev/null   # never leave a truncated partial behind
  printf 'cc-reload: .reload/session.md belongs to a different session (%s) and is about to be overwritten, but it could NOT be saved aside (%s is unwritable). Proceeding — your snapshot is not blocked.\n' \
    "$INCUMBENT" "$RELOAD_DIR"
fi
exit 0
