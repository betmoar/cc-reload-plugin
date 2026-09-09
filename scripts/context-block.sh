#!/usr/bin/env bash
#
# context-block.sh — the mechanical half of a session digest.
#
# Prints a short, bounded block of facts a SHELL knows for certain: branch,
# short HEAD, uncommitted paths, and the last few commit subjects. The digest's
# four prose sections carry the working thread — the delta that is not on disk;
# this carries the part that IS on disk, so the model never has to recall a sha
# or reconstruct what was dirty. Two callers:
#
#   * /snapshot, folded under "Done this stretch" — cheap, and exact where
#     recall is not.
#   * precompact-hook.sh's mechanical fallback. That is the worst path in the
#     whole plugin (auto-compaction fired before any agent-authored digest
#     existed) and until 0.4.2 it produced three literal "(unknown)" lines. A
#     hook cannot author prose, but it CAN state where the repo stood.
#
# git is a SOFT dependency with exactly THREE call sites (invariant 20): this
# script, head_drift() in hooks/lib.sh, and precompact-hook.sh's head: stamp.
# This is the only one whose whole purpose is git and the only FREE-FORM caller;
# the other two make one narrowly-scoped call each. digest_age_days() reads
# mtime and is deliberately not one of them, so the age axis keeps working in a
# directory with no repo at all. Adding a fourth means auditing all four against
# invariant 20, not just this script.
# Everything else is bash + jq + coreutils. The contract, in one line: on any
# doubt, print NOTHING and exit 0 — same fail-open-silent shape as
# proxy_window() in hooks/lib.sh. Half a block, or one with git's stderr pasted
# into it, is worse than no block: it lands in a digest that is injected into a
# fresh context as fact.
#
# Every git call is `-C "$PROJECT_DIR"` (never a cd), stderr-suppressed, and
# guarded on its own exit status. Output is capped so it cannot eat the ~30-line
# digest budget it is supposed to serve, and opens no `## ` heading — a heading
# here would look like a fifth digest section to the parity test and to
# sessionstart-hook.sh's readers alike.
#
# Usage: context-block.sh            (reads $CLAUDE_PROJECT_DIR, else $PWD)
# Exit:  always 0.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SUBJECTS="${1:-5}"                       # how many recent commit subjects
[[ "$SUBJECTS" =~ ^[0-9]+$ ]] || SUBJECTS=5

command -v git >/dev/null 2>&1 || exit 0
[ -d "$PROJECT_DIR" ] || exit 0

g(){ git -C "$PROJECT_DIR" "$@" 2>/dev/null; }

# Not a work tree (or a .git so broken git refuses to answer) -> nothing to say.
[ "$(g rev-parse --is-inside-work-tree)" = "true" ] || exit 0

# An empty repo has no HEAD to resolve. `rev-parse --short HEAD` fails there,
# which is exactly the "unknown revision" fatal the tests forbid leaking. No
# sha, no block: there is no state worth reporting before the first commit.
SHA="$(g rev-parse --short HEAD)"
[ -n "$SHA" ] || exit 0

# A detached HEAD prints "HEAD" as its symbolic name — report that as detached
# rather than as a branch, or the digest says the session was on a branch called
# HEAD. --show-current is empty when detached (git >= 2.22); fall back to the
# older form so this works on whatever git the user has.
BRANCH="$(g rev-parse --abbrev-ref HEAD)"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  BRANCH="detached HEAD"
fi

printf 'Repo state at snapshot (mechanical — read from git, not recalled):\n'
printf -- '- branch: %s @ %s\n' "$BRANCH" "$SHA"

# Uncommitted work. `status --porcelain` is the stable, script-facing form.
# Cap the listing: a digest is ~30 lines and a big refactor can dirty hundreds
# of paths, so name the first few and count the rest.
#
# Test the EXIT STATUS, not just emptiness. `git status` prints nothing when it
# FAILS (corrupt or locked index, an I/O error, a permission problem) — so
# `[ -z "$STATUS" ]` alone cannot tell "clean" from "could not look", and the
# first cut of this script asserted "working tree clean" over a genuinely dirty
# tree whenever the index was unreadable (measured with a deliberately corrupted
# .git/index). Silence about dirtiness is fine; a false claim of cleanliness is
# the silent-wrong shape this whole file is written to avoid, and it lands in a
# digest a fresh session is told to trust.
if ! STATUS="$(g status --porcelain)"; then
  printf -- '- (working tree state unavailable — git status failed)\n'
elif [ -z "$STATUS" ]; then
  printf -- '- working tree clean\n'
else
  N="$(printf '%s\n' "$STATUS" | grep -c .)"
  printf -- '- uncommitted (%s):\n' "$N"
  printf '%s\n' "$STATUS" | head -8 | sed 's/^/    /'
  [ "$N" -gt 8 ] && printf '    … and %s more\n' "$((N - 8))"
  DIFFSTAT="$(g diff --shortstat)"
  [ -n "$DIFFSTAT" ] && printf -- '- tracked changes:%s\n' "$DIFFSTAT"
fi

SUBJ="$(g log --oneline --no-decorate -n "$SUBJECTS")"
if [ -n "$SUBJ" ]; then
  printf -- '- recent commits:\n'
  printf '%s\n' "$SUBJ" | sed 's/^/    /'
fi
exit 0
