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

jq -n --arg ctx "$BODY" --arg src "$SOURCE" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("cc-reload restored this session from .reload/session.md (reset: " + $src + "). Resume from the \"Next concrete step\".\n\n" + $ctx)
  }
}'
exit 0
