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

# Only rehydrate when armed.
[ -f "$PENDING" ] || exit 0
[ -f "$DIGEST" ]  || { rm -f "$PENDING"; exit 0; }

# Optional session-id guard (M3): /clear and /compact preserve the session id,
# so a digest stamped with a different id is likely stale from another session.
HOOK_SESSION="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""')"
DIGEST_SESSION="$(awk -F'"' '/^session_id:/{print $2; exit}' "$DIGEST" 2>/dev/null)"
if [ -n "$DIGEST_SESSION" ] && [ -n "$HOOK_SESSION" ] && [ "$DIGEST_SESSION" != "$HOOK_SESSION" ]; then
  # don't inject another session's digest; leave it armed for its owner
  exit 0
fi

BODY="$(cat "$DIGEST")"
rm -f "$PENDING"   # consume the arm

# systemMessage fires AFTER /clear's screen wipe and is shown in the blank
# terminal — it is the reliable visible signal for all trigger sources. Keep it.
# additionalContext carries the full digest for Claude to read.
INTENT="$(awk -F'"' '/^intent:/{print $2; exit}' "$DIGEST" 2>/dev/null)"

# Extract first bullet from each section for summary
_first_bullet() {
  awk "/^## ${1}/{f=1;next} f && /^- /{print;exit} f && /^##/{exit}" "$DIGEST" 2>/dev/null | sed 's/^- //'
}
_truncate() { local s="$1" n="${2:-60}"; [ ${#s} -gt $n ] && printf '%s…' "${s:0:$n}" || printf '%s' "$s"; }

DONE_LINE="$(_first_bullet 'Done this stretch')"
NEXT_LINE="$(_first_bullet 'Next concrete step')"
INFLIGHT_LINE="$(_first_bullet 'In flight')"

MSG="🔄 cc-reload (${SOURCE})"
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
