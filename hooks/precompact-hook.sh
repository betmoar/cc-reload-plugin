#!/usr/bin/env bash
#
# cc-reload PreCompact hook — safety net for compaction (manual /compact + auto).
#
# A hook is a shell command: the MODEL is not running here, so we cannot author a
# good summary. We only (a) arm a reload and (b) make sure SOME digest exists, so
# SessionStart(compact) has something to inject. The durable mitigation is the
# skill keeping .reload/session.md continuously fresh — this is just the floor.
#
source "$(dirname "$0")/lib.sh"
repete_active && exit 0

# Read the session id so a mechanical fallback digest can be stamped with it.
# /compact (and auto-compaction) preserve the session id, so stamping it lets the
# SessionStart staleness guard rehydrate this digest in THIS session and refuse to
# inject it into any other one (an empty id would match every session).
HOOK_INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""')"

ensure_reload_dir
touch "$PENDING"   # arm: rehydrate after compaction completes

if [ ! -f "$DIGEST" ]; then
  # Mechanical fallback — no agent-authored digest exists yet. Leave an honest
  # stub so the next session knows the snapshot is thin and should re-derive
  # state from disk/git rather than trust this.
  {
    printf -- '---\nsession_id: "%s"\nupdated_at: "%s"\nintent: "(mechanical fallback — no agent-authored digest)"\n---\n' \
      "$SESSION_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '## Done this stretch\n(unknown — auto-compaction fired before a digest was written)\n\n'
    printf '## In flight\n(unknown)\n\n'
    printf '## Next concrete step\nRe-derive state from the repo and recent git history, then run /checkpoint to start tracking again.\n\n'
    printf '## Open questions & risks\nThis digest is a fallback; trust files and commits over it.\n'
  } > "$DIGEST"
fi
exit 0
