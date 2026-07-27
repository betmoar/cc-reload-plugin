#!/usr/bin/env bash
#
# cc-reload SessionStart hook — the auto-reload.
#
# Fires on startup|resume|clear|compact. Rehydrates the session digest ONLY if a
# reload was armed (.reload/pending exists), so a deliberate /clear with nothing
# armed is respected and never undone. One-shot: the marker is consumed on use.
#
source "$(dirname "$0")/lib.sh"
repete_active && exit 0

HOOK_INPUT="$(cat)"
SOURCE="$(printf '%s' "$HOOK_INPUT" | jq -r '.source // ""')"

# Stamp the model + resolved window to disk so the Stop hook (which gets NO model
# field) can turn raw token usage into a real % of the context window.
MODEL="$(printf '%s' "$HOOK_INPUT" | jq -r '.model // ""')"
if [ -n "$MODEL" ]; then
  ensure_reload_dir
  printf 'model: %s\nwindow: %s\n' "$MODEL" "$(model_window "$MODEL")" > "$MODELFILE"
fi

# Marker hygiene on a genuine context reset (NOT resume — a resumed session keeps
# its context, so a mid-flight snapshot handshake may legitimately complete and
# the notify ladder still reflects real occupancy):
#   - a leaked `summarizing` (pass 1 blocked, user interrupted the snapshot turn,
#     then /clear'd) must not survive into the fresh session, where the first Stop
#     would run pass 2 and arm a dead session's digest with a misleading warning.
#   - the notify ladder resets so the next budget crossing announces itself.
case "$SOURCE" in
  startup|clear|compact) rm -f "$SUMMARIZING" "$NOTIFIED" 2>/dev/null ;;
esac

# Only rehydrate when armed. The one-shot .reload/pending marker — written next to
# the digest by THIS project's own Stop/PreCompact hook — is the sole gate. We do
# NOT also gate on session id: /clear (and resume) mint a fresh session id every
# time, so the armed digest is always stamped with the PRIOR id and an id-equality
# check would suppress the banner on its primary trigger 100% of the time. The arm
# is self-scoping (per-project dir, consumed on use), so identity adds nothing.
# (Since 0.3 we DO compare ids — but only to WARN, and NOT against this
# session's own id: see the arm-coherence block below for why that comparison
# is meaningless here. The gate is still the arm alone. "Warn" and "gate" are
# different things: the second is the v0.1.5 bug. Never let a comparison reach
# an `exit`.)
[ -f "$PENDING" ] || exit 0
[ -f "$DIGEST" ]  || { rm -f "$PENDING"; exit 0; }

# Arm coherence (spec §4.2.3, revised — lineage not identity). WARNS on
# incoherence; NEVER gates on it (invariant 3).
#
# ARM_OWNER != SESSION_ID is NOT a collision signal — it is the definition of
# /clear, which mints a fresh session id every time. Comparing the arm's owner
# against THIS session's incoming id would fire on every ordinary reset for a
# single user in a single directory (the defect this revision fixes).
#
# The real signal is whether the arm and the digest AGREE: whoever armed
# should also be who wrote the digest.
#   ARM_OWNER == DIGEST_OWNER            -> coherent handoff (ordinary /clear,
#       or a second session that armed its own snapshot). Silent.
#   ARM_OWNER != DIGEST_OWNER (both set) -> INCOHERENT: session A armed, then
#       session B overwrote the digest beside that arm. The arm now points at
#       a thread its armer never wrote — two sessions sharing this directory.
#       Warn.
#   either side empty                    -> undetectable (pre-0.3 arm, or no
#       runtime id). Silent — per spec §4.4 limit 1.
ARM_OWNER="$(cat "$PENDING" 2>/dev/null)"
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
DIGEST_OWNER_AT_REHYDRATE="$(digest_owner)"
INCOHERENT_ARM=""
[ -n "$ARM_OWNER" ] && [ -n "$DIGEST_OWNER_AT_REHYDRATE" ] && [ "$ARM_OWNER" != "$DIGEST_OWNER_AT_REHYDRATE" ] && INCOHERENT_ARM=1

rm -f "$PENDING"   # consume the arm

# This session now carries the working thread it just rehydrated: claim the
# digest by rewriting its frontmatter session_id to our own id. The next
# /snapshot then sees INCUMBENT==WRITER and stays silent — this is what makes
# the ordinary /clear path (S1 arms+writes -> S2 rehydrates+claims -> S2 arms+
# writes -> ...) idempotent instead of tripping claim-digest.sh on every reset.
# A genuinely foreign write that never passed through this handoff still
# collides normally. Happens AFTER the rehydrate decision (the PENDING/DIGEST
# existence checks above) — never gates anything, fails open and silent
# (claim_digest, hooks/lib.sh).
#
# BODY is captured AFTER this call, not before: it becomes the injected
# additionalContext, and it must be byte-consistent with what actually landed
# on disk (the same reason INTENT/DONE_LINE/NEXT_LINE below all re-read
# "$DIGEST" live rather than reusing a pre-claim snapshot). Reading BODY first
# would inject a digest showing the OLD owner while the file on disk already
# shows the new one — cosmetically wrong and a trap for anything that later
# diffs "what the model saw" against "what's on disk". No external process
# writes .reload/session.md concurrently with this hook (SessionStart is not
# reentrant within one project dir's synchronous hook invocation), so there is
# no read/write race to guard against here beyond claim_digest's own
# temp-file+mv atomicity.
claim_digest "$SESSION_ID"
BODY="$(cat "$DIGEST")"

# systemMessage fires AFTER /clear's screen wipe and is shown in the blank
# terminal — it is the reliable visible signal for all trigger sources. Keep it.
# additionalContext carries the full digest for Claude to read.
INTENT="$(awk -F'"' '/^intent:/{print $2; exit}' "$DIGEST" 2>/dev/null)"

# Extract first bullet from each section for summary
_first_bullet() {
  awk "/^## ${1}/{f=1;next} f && /^- /{print;exit} f && /^##/{exit}" "$DIGEST" 2>/dev/null | sed 's/^- //'
}
# The Next-step section is a single PROSE line in the template (not a bullet like
# Done/In-flight), so _first_bullet misses it and the banner would drop the most
# valuable line across a reset. Grab the first non-blank content line instead,
# stripping a leading "- " so a bulleted next step works too.
_first_line() {
  awk "/^## ${1}/{f=1;next} f && /^##/{exit} f && NF{print;exit}" "$DIGEST" 2>/dev/null | sed 's/^- //'
}
_truncate() { local s="$1" n="${2:-60}"; [ ${#s} -gt $n ] && printf '%s…' "${s:0:$n}" || printf '%s' "$s"; }

DONE_LINE="$(_first_bullet 'Done this stretch')"
NEXT_LINE="$(_first_line 'Next concrete step')"
INFLIGHT_LINE="$(_first_bullet 'In flight')"

MSG="🔄 cc-reload (${SOURCE})"
[ -n "$INCOHERENT_ARM" ] && MSG="⚠️ this arm was set by a different session than the one that wrote the digest (armed by $ARM_OWNER, digest by $DIGEST_OWNER_AT_REHYDRATE) — another session is sharing this directory; verify before trusting it | $MSG"
[ -n "$INTENT" ] && MSG="$MSG — $(_truncate "$INTENT" 80)"
if [ -n "$DONE_LINE" ]; then
  MSG="$MSG | ✓ $(_truncate "$DONE_LINE" 60)"
fi
if [ -n "$INFLIGHT_LINE" ] && ! printf '%s' "$INFLIGHT_LINE" | grep -qi 'nothing'; then
  MSG="$MSG | ⚡ $(_truncate "$INFLIGHT_LINE" 55)"
fi
if [ -n "$NEXT_LINE" ]; then
  MSG="$MSG | → $(_truncate "$NEXT_LINE" 60)"
fi
MSG="$MSG | /reload for full sitrep"

jq -n --arg ctx "$BODY" --arg src "$SOURCE" --arg msg "$MSG" '{
  systemMessage: $msg,
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("cc-reload restored this session (trigger: " + $src + "). Resume from the \"Next concrete step\".\n\n" + $ctx)
  }
}'
exit 0
