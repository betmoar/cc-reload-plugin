#!/usr/bin/env bash
#
# cc-reload SessionStart hook — the auto-reload.
#
# Fires on startup|resume|clear|compact|fork. Rehydrates the session digest ONLY
# if a reload is armed for THIS lineage (an arm this process wrote, a pid-less
# arm, or an orphan whose owner process is gone), so a deliberate /clear with
# nothing armed is respected and never undone, and a second live session in the
# same directory never takes the first one's reload (0.5.0 — invariant 21).
# One-shot: consumed arms are removed.
#
source "$(dirname "$0")/lib.sh"
repete_active && exit 0

HOOK_INPUT="$(cat)"
SOURCE="$(printf '%s' "$HOOK_INPUT" | jq -r '.source // ""')"
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)"

# Stamp the model + resolved window to disk so the Stop hook (which gets NO model
# field) can turn raw token usage into a real % of the context window. Stamped
# PER SESSION (F04): another session starting here must not move this one's
# window.
MODEL="$(printf '%s' "$HOOK_INPUT" | jq -r '.model // ""')"
if [ -n "$MODEL" ]; then
  # Precedence: .reload/config's context_window override (checked later, in
  # stop-hook.sh — it always wins, unchanged) > a live cc-proxy lookup > the
  # curated table. proxy_window() only fires for a loopback ANTHROPIC_BASE_URL
  # and fails silently (empty output) for every Claude id, so the F05 [1m]
  # 1M-window guard is untouched: cc-proxy publishes no window for claude-*.
  WIN="$(proxy_window "$MODEL")"
  [ -n "$WIN" ] || WIN="$(model_window "$MODEL")"
  stamp_model "$SESSION_ID" "$MODEL" "$WIN"
fi

# Marker hygiene on a genuine context reset (NOT resume or fork — those keep
# their context, so a mid-flight snapshot handshake may legitimately complete
# and the notify ladder still reflects real occupancy):
#   - a leaked `summarizing` (pass 1 blocked, user interrupted the snapshot turn,
#     then /clear'd) must not survive into the fresh session, where the first Stop
#     would run pass 2 and arm a dead session's digest with a misleading warning.
#     UNLESS it belongs to another LIVE session (invariant 22): that handshake is
#     someone else's, mid-flight, and purging it strands their digest un-armed.
#   - the notify ladder resets so the next budget crossing announces itself.
case "$SOURCE" in
  startup|clear|compact)
    marker_foreign_live "$SUMMARIZING" || rm -f "$SUMMARIZING" 2>/dev/null
    rm -f "$NOTIFIED" 2>/dev/null ;;
esac

# Only rehydrate when armed FOR THIS LINEAGE. The arm is the sole gate. We do
# NOT gate on session id: /clear (and resume) mint a fresh session id every time,
# so an id-equality check would suppress the banner on its primary trigger 100%
# of the time (the v0.1.5 bug). The PROCESS id is the lineage key instead — it
# does not rotate across /clear (see lib.sh "process lineage"). A foreign LIVE
# arm is left where it is; when nothing is ours, say so once and start fresh.
ARM="$(arms_here | head -n 1)"
if [ -z "$ARM" ]; then
  FOREIGN="$(arms_foreign_live)"
  if [ -n "$FOREIGN" ]; then
    FOREIGN_SID="$(marker_sid "$(printf '%s\n' "$FOREIGN" | head -n 1)")"
    LAST_ARM="$(journal_last arm)"
    journal defer "$SESSION_ID" "$SOURCE: left $(printf '%s\n' "$FOREIGN" | wc -l | tr -d ' ') live foreign arm(s)"
    M="🔒 cc-reload ($SOURCE): a reload armed by another live session (${FOREIGN_SID:-unknown id}) was left in place — this session starts fresh. /reload pulls that digest in on purpose; /snapshot starts your own thread."
    [ -n "$LAST_ARM" ] && M="$M Last arm: ${LAST_ARM%% sid=*}."
    jq -n --arg m "$M" '{systemMessage:$m}'
    exit 0
  fi
  # Nothing armed. On a compaction, an arm that PreCompact could not write is the
  # one failure it cannot report itself (Claude Code discards PreCompact's
  # systemMessage), so surface it here, once.
  if [ "$SOURCE" = "compact" ]; then
    LAST="$(tail -n 1 "$JOURNAL" 2>/dev/null)"
    if [[ "$LAST" =~ ^[^\ ]+\ arm-failed\  ]]; then   # the EVENT field, not any mention in a detail
      journal reported "$SESSION_ID" "surfaced the failed arm"
      jq -n --arg m "⚠️ cc-reload: this compaction was NOT armed — PreCompact could not write the arm marker (${LAST#* pid=* }). Run /reload to rehydrate by hand, then remove whatever sits at .reload/pending*." '{systemMessage:$m}'
    fi
  fi
  exit 0
fi

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
#   ARM_OWNER != DIGEST_OWNER (both set) -> another session's write landed in
#       session.md beside this arm. Since 0.5.0, FIRST look for the side-file
#       claim-digest.sh kept for the armer (session.<ARM_OWNER>.md): that IS
#       this lineage's thread, so rehydrate it and say so — each session gets
#       its own thread back. Only with no side-file does the old behaviour
#       apply: rehydrate session.md (invariant 3) and warn.
#   either side empty                    -> undetectable (pre-0.3 arm, or no
#       runtime id). Silent.
ARM_OWNER="$(marker_sid "$ARM")"
DIGEST_OWNER_AT_REHYDRATE="$(digest_owner)"
INCOHERENT_ARM=""
SRC="$DIGEST"
if [ -n "$ARM_OWNER" ] && [ -n "$DIGEST_OWNER_AT_REHYDRATE" ] && [ "$ARM_OWNER" != "$DIGEST_OWNER_AT_REHYDRATE" ]; then
  SIDE="$(sidefile_for "$ARM_OWNER")"
  if [ -n "$SIDE" ] && [ -f "$SIDE" ]; then SRC="$SIDE"; else INCOHERENT_ARM=1; fi
fi

# Consume every arm this lineage owns (own + orphans): one-shot. Foreign live
# arms are not in this list and stay untouched.
arms_here | while IFS= read -r f; do [ -n "$f" ] && rm -f "$f" 2>/dev/null; done

[ -f "$SRC" ] || exit 0    # armed, but the digest vanished: nothing to inject

# Digest age must be read HERE, before claim_digest below. That claim rewrites
# the file through a temp file + mv, and the mv gives the digest a brand-new
# mtime (measured: a file backdated to 2020 reads as `now` immediately after) —
# so every digest looks 0 days old once claimed, and the age signal would be
# dead on its own primary path. Same trap in a different costume as the v0.1.5
# id-equality bug: a check that is structurally false exactly when it matters.
DIGEST_AGE_DAYS="$(digest_age_days 1 "$SRC")"

# This session now carries the working thread it just rehydrated: claim the
# digest by rewriting its frontmatter session_id to our own id. The next
# /snapshot then sees INCUMBENT==WRITER and stays silent — this is what makes
# the ordinary /clear path (S1 arms+writes -> S2 rehydrates+claims -> S2 arms+
# writes -> ...) idempotent instead of tripping claim-digest.sh on every reset.
# A genuinely foreign write that never passed through this handoff still
# collides normally. Happens AFTER the rehydrate decision — never gates
# anything, fails open and silent (claim_digest, hooks/lib.sh).
#
# Only session.md is ever claimed. A thread rehydrated from a SIDE-FILE leaves
# session.md (the other session's) untouched: this session's next /snapshot
# writes session.md normally, and claim-digest.sh side-files the other thread
# in turn — two live sessions ping-pong the slot with nothing lost.
#
# BODY is captured AFTER this call, not before: it becomes the injected
# additionalContext, and it must be byte-consistent with what actually landed
# on disk (the same reason INTENT/DONE_LINE/NEXT_LINE below all re-read the
# file live rather than reusing a pre-claim snapshot).
[ "$SRC" = "$DIGEST" ] && claim_digest "$SESSION_ID"
BODY="$(cat "$SRC")"

# systemMessage fires AFTER /clear's screen wipe and is shown in the blank
# terminal — it is the reliable visible signal for all trigger sources. Keep it.
# additionalContext carries the full digest for Claude to read.
# Frontmatter-scoped, quoted or not (hooks/lib.sh digest_field — audit F08).
_field() { DIGEST="$SRC" digest_field "$1"; }
INTENT="$(_field intent)"

# Extract first bullet from each section for summary
_first_bullet() {
  awk "/^## ${1}/{f=1;next} f && /^- /{print;exit} f && /^##/{exit}" "$SRC" 2>/dev/null | sed 's/^- //'
}
# The Next-step section is a single PROSE line in the template (not a bullet like
# Done/In-flight), so _first_bullet misses it and the banner would drop the most
# valuable line across a reset. Grab the first non-blank content line instead,
# stripping a leading "- " so a bulleted next step works too.
_first_line() {
  awk "/^## ${1}/{f=1;next} f && /^##/{exit} f && NF{print;exit}" "$SRC" 2>/dev/null | sed 's/^- //'
}
_truncate() { local s="$1" n="${2:-60}"; [ ${#s} -gt $n ] && printf '%s…' "${s:0:$n}" || printf '%s' "$s"; }

DONE_LINE="$(_first_bullet 'Done this stretch')"
NEXT_LINE="$(_first_line 'Next concrete step')"
INFLIGHT_LINE="$(_first_bullet 'In flight')"

MSG="🔄 cc-reload (${SOURCE})"
[ -n "$INCOHERENT_ARM" ] && MSG="⚠️ this arm was set by a different session than the one that wrote the digest (armed by $ARM_OWNER, digest by $DIGEST_OWNER_AT_REHYDRATE) — another session is sharing this directory; verify before trusting it | $MSG"
[ "$SRC" != "$DIGEST" ] && MSG="$MSG — restored YOUR thread from ${SRC#"$RELOAD_DIR/"} (session.md now belongs to another session; your next /snapshot takes the slot back)"
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
# Measured staleness (0.4.2). The digest stamps the HEAD it was written at;
# head_drift() counts the commits since, and prints NOTHING unless it has a real
# number (no git, no stamp, foreign sha, shallow clone, zero drift — all silent;
# see lib.sh). Advisory only: it never gates, never blocks, and the rehydrate
# above has already happened. This is a fact the digest itself cannot know,
# which is the whole reason it is worth a line — the digest says what the
# session was doing, this says how much has moved under it since.
DRIFT="$(head_drift "$(_field head)")"
[ -n "$DRIFT" ] && MSG="$MSG | ⏱ $DRIFT commits since this digest — re-read before trusting it"
# The second staleness axis, and the one that works with no git: how long ago
# the digest was written. Occupancy is the plugin's only refresh trigger, so a
# session that never crosses the budget can carry a weeks-old digest with no
# signal whatsoever. Captured BEFORE claim_digest (see DIGEST_AGE_DAYS above) —
# reading it here would measure the claim's own mv, not the digest.
[ -n "$DIGEST_AGE_DAYS" ] && MSG="$MSG | 🕰 digest is $DIGEST_AGE_DAYS days old"
MSG="$MSG | /reload for full sitrep"

CTX="cc-reload restored this session (trigger: ${SOURCE}). Resume from the \"Next concrete step\".

$BODY"
# Claude Code caps every hook output string at 10,000 characters and replaces a
# longer one with a preview + a file path (docs: hooks reference, "JSON
# output"). The digest is injected in FULL regardless — a silent cut here would
# be worse than the cap (backlog #6) — but the user must know the model may
# have received a preview, not the thread, and that /reload reads the file.
CAP_WARN=""
if [ "${#CTX}" -gt 9500 ]; then
  CAP_WARN="⚠️ digest is ${#CTX} chars — over Claude Code's 10,000-char hook-output cap, so Claude may have been handed a preview and a path instead of the thread. Run /reload to read it in full, then /snapshot a tighter one (~30 lines). | "
fi
journal rehydrate "$SESSION_ID" "$SOURCE ${SRC#"$RELOAD_DIR/"}"

jq -n --arg ctx "$CTX" --arg msg "${CAP_WARN}${MSG}" '{
  systemMessage: $msg,
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
exit 0
