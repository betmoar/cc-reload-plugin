#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
#
# Two sessions, one directory — the LINEAGE rules (CLAUDE.md invariants 21–23).
#
# Until 0.5.0 the arm was a single unowned slot: whichever session started or
# /clear'd next consumed it, whoever had set it. A second Claude Code session
# opened in the same tree silently took the first session's reload (audit
# 2026-09-17 F01/F02) — the first session's /clear then rehydrated nothing.
#
# The fix keys ownership on the PROCESS, not the session id: /clear rotates the
# session id but keeps the process (CLAUDE_PID, exported by Claude Code to hooks
# and to the Bash tool — measured on 2.1.274, undocumented). An arm carries its
# owner's pid; a session consumes its own arms, pid-less (legacy) arms, and
# ORPHANS (owner pid dead — the restart-after-quit case), and leaves a FOREIGN
# LIVE arm untouched with a one-line notice. No CLAUDE_PID → no pid on the arm →
# exactly the pre-0.5 behaviour (fail-open, F14).
#
# Liveness is `kill -0`. A live foreign pid here is a background `sleep`; a dead
# one is 2147483647 (beyond pid_max on Linux and macOS, so never alive).
#
# Run from anywhere: bash tests/test-concurrent.sh   (exit code = #failures)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hooks"
TMP="$(mktemp -d)"
sleep 600 & LIVE=$!
trap 'kill "$LIVE" 2>/dev/null; rm -rf "$TMP"' EXIT
DEAD=2147483647
ME=$$
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
# run <pid-or-empty> <hook> <json>: the hook runs AS process <pid> (CLAUDE_PID).
run(){ printf '%s' "$3" | ANTHROPIC_BASE_URL="" CLAUDE_PID="$1" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H/$2"; }
arm(){ CLAUDE_PID="$1" CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/scripts/arm-reload.sh" "$2"; }
reset(){ rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"; }
digest(){ # digest <owner-sid> <magic> [file]
  printf -- '---\nsession_id: "%s"\nmission: "m"\nupdated_at: "x"\nintent: "intent of %s"\n---\n## Done this stretch\n- done %s\n## In flight\n- nothing\n## Next concrete step\n%s\n## Open questions & risks\n- none\n' \
    "$1" "$1" "$1" "$2" > "${3:-$TMP/.reload/session.md}"
}
mktx(){ printf '{"message":{"role":"assistant","model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "${2:-claude-opus-4-8}" "$1" > "$TMP/t.jsonl"; }
ctx(){ printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }
msg(){ printf '%s' "$1" | jq -r '.systemMessage // ""'; }

echo "== arm-reload.sh: ONE writer for the arm, and what it writes is what SessionStart reads =="
reset
ck "script exists" '[ -f "$ROOT/scripts/arm-reload.sh" ]'
arm "$ME" S_OWN >/dev/null
ck "with CLAUDE_PID the arm lands at pending.<pid>" '[ -f "$TMP/.reload/pending.$ME" ]'
ck "line 1 is the session id" '[ "$(sed -n 1p "$TMP/.reload/pending.$ME")" = "S_OWN" ]'
ck "the pid line names the process" 'grep -q "^pid: $ME$" "$TMP/.reload/pending.$ME"'
ck "no bare pending was written beside it" '[ ! -e "$TMP/.reload/pending" ]'
reset
arm "" S_LEGACY >/dev/null
ck "without CLAUDE_PID the arm is the legacy bare pending (F14 fail-open)" '[ "$(cat "$TMP/.reload/pending")" = "S_LEGACY" ]'
reset; mkdir -p "$TMP/.reload/pending.$ME"
OUT="$(arm "$ME" S_DIR 2>&1)"; RC=$?
ck "a directory at the slot: non-zero exit and a NOT-armed message (invariant 15)" '[ "$RC" -ne 0 ] && printf "%s" "$OUT" | grep -qi "not armed"'
rmdir "$TMP/.reload/pending.$ME"

echo "== F01: a foreign LIVE arm is left in place on startup; the owner's own /clear still rehydrates it =="
reset; digest S_A MAGIC-A-NEXT
arm "$LIVE" S_A >/dev/null                        # session A (process LIVE) armed
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_B","source":"startup","model":"claude-opus-4-8"}')"
ck "B injects nothing" '[ -z "$(ctx "$OUT")" ]'
ck "A's arm survives B's startup" '[ -f "$TMP/.reload/pending.$LIVE" ]'
ck "B is told another live session owns the arm" 'msg "$OUT" | grep -qi "another live session"'
ck "B did NOT claim A's digest" 'grep -q "^session_id: \"S_A\"" "$TMP/.reload/session.md"'
ck "B's notice names /reload as the opt-in" 'msg "$OUT" | grep -q "/reload"'
OUT="$(run "$LIVE" sessionstart-hook.sh '{"session_id":"S_A2","source":"clear"}')"
ck "A's /clear (new sid, same process) rehydrates A's thread" 'ctx "$OUT" | grep -q "MAGIC-A-NEXT"'
ck "A's /clear consumed A's arm" '[ ! -e "$TMP/.reload/pending.$LIVE" ]'
ck "A's /clear warns nothing (coherent lineage)" '! msg "$OUT" | grep -qi "different session\|another live session"'
ck "the digest is claimed by A's new sid" 'grep -q "^session_id: \"S_A2\"" "$TMP/.reload/session.md"'

echo "== F02: A's /clear never consumes live B's arm =="
reset; digest S_B MAGIC-B-NEXT
arm "$LIVE" S_B >/dev/null                        # B (process LIVE) armed
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_A2","source":"clear"}')"
ck "A's /clear injects nothing of B's" '! ctx "$OUT" | grep -q "MAGIC-B-NEXT"'
ck "B's arm survives A's /clear" '[ -f "$TMP/.reload/pending.$LIVE" ]'
ck "A is told the arm belongs to another live session" 'msg "$OUT" | grep -qi "another live session"'

echo "== the restart case: an ORPHAN arm (owner pid dead) rehydrates on startup =="
reset; digest S_Q MAGIC-Q-NEXT
arm "$DEAD" S_Q >/dev/null
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_R","source":"startup"}')"
ck "orphan arm rehydrates" 'ctx "$OUT" | grep -q "MAGIC-Q-NEXT"'
ck "orphan arm consumed" '[ ! -e "$TMP/.reload/pending.$DEAD" ]'
ck "no collision warning on an orphan" '! msg "$OUT" | grep -qi "another live session"'

echo "== own arm wins over a newer orphan; every orphan is consumed; the foreign live arm survives =="
reset; digest S_OWN MAGIC-OWN-NEXT
arm "$ME" S_OWN >/dev/null; touch -t 202001010000 "$TMP/.reload/pending.$ME"   # ours, OLD
arm "$DEAD" S_Q >/dev/null                                                     # orphan, newer
arm "$LIVE" S_L >/dev/null                                                     # foreign live
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_OWN2","source":"clear"}')"
ck "own thread wins" 'ctx "$OUT" | grep -q "MAGIC-OWN-NEXT"'
ck "own arm consumed" '[ ! -e "$TMP/.reload/pending.$ME" ]'
ck "orphan consumed too (dead sessions leave no one-shot behind)" '[ ! -e "$TMP/.reload/pending.$DEAD" ]'
ck "foreign live arm untouched" '[ -f "$TMP/.reload/pending.$LIVE" ]'

echo "== legacy bare pending (pre-0.5 arm, no pid) still rehydrates =="
reset; digest S_OLD MAGIC-OLD-NEXT; printf 'S_OLD' > "$TMP/.reload/pending"
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_NEW","source":"clear"}')"
ck "bare pending rehydrates" 'ctx "$OUT" | grep -q "MAGIC-OLD-NEXT"'
ck "bare pending consumed" '[ ! -e "$TMP/.reload/pending" ]'

echo "== hooks without CLAUDE_PID write a pid-less arm (F14: absent oracle -> pre-0.5 behaviour) =="
reset; digest S_P MAGIC-P
run "" precompact-hook.sh '{"session_id":"S_PC","trigger":"manual"}' >/dev/null
ck "PreCompact without CLAUDE_PID arms the bare slot" '[ "$(cat "$TMP/.reload/pending")" = "S_PC" ]'
reset; digest S_P MAGIC-P
run "$ME" precompact-hook.sh '{"session_id":"S_PC","trigger":"manual"}' >/dev/null
ck "PreCompact with CLAUDE_PID arms pending.<pid>" '[ "$(sed -n 1p "$TMP/.reload/pending.$ME")" = "S_PC" ]'

echo "== each lineage gets ITS thread back: the arm's sid resolves to the side-file when session.md was taken =="
reset
digest S_B MAGIC-B-NEXT                                  # B snapshotted last: session.md is B's
digest S_A MAGIC-A-SIDE "$TMP/.reload/session.S_A.md"    # A's thread, side-filed by claim-digest
arm "$LIVE" S_A >/dev/null                               # A's arm (process LIVE), sid S_A
OUT="$(run "$LIVE" sessionstart-hook.sh '{"session_id":"S_A2","source":"clear"}')"
ck "A's /clear injects A's side-filed thread" 'ctx "$OUT" | grep -q "MAGIC-A-SIDE"'
ck "not B's" '! ctx "$OUT" | grep -q "MAGIC-B-NEXT"'
ck "no incoherence warning (the side-file IS coherent)" '! msg "$OUT" | grep -qi "different session"'
ck "banner says the thread came from the side-file" 'msg "$OUT" | grep -q "session.S_A.md"'
ck "session.md (B's) untouched, not claimed" 'grep -q "^session_id: \"S_B\"" "$TMP/.reload/session.md"'
ck "the side-file is never auto-deleted" '[ -f "$TMP/.reload/session.S_A.md" ]'
digest S_A MAGIC-A-NEWER "$TMP/.reload/session.S_A.1700000000.md"   # a later mtime-suffixed copy
arm "$LIVE" S_A >/dev/null
OUT="$(run "$LIVE" sessionstart-hook.sh '{"session_id":"S_A3","source":"clear"}')"
ck "the NEWEST side-file for that sid wins" 'ctx "$OUT" | grep -q "MAGIC-A-NEWER"'
reset; digest S_B MAGIC-B-NEXT; arm "$LIVE" S_A >/dev/null   # no side-file at all
OUT="$(run "$LIVE" sessionstart-hook.sh '{"session_id":"S_A2","source":"clear"}')"
ck "no side-file -> falls back to session.md (invariant 3)" 'ctx "$OUT" | grep -q "MAGIC-B-NEXT"'
ck "and the incoherence warning still fires" 'msg "$OUT" | grep -qi "different session"'

echo "== F03: the handshake marker is owned too =="
reset; digest S_A MAGIC-A; printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\n' > "$TMP/.reload/config"
printf 'S_A\npid: %s\n' "$LIVE" > "$TMP/.reload/summarizing"    # A is mid pass-1
mktx 50000
OUT="$(run "$ME" stop-hook.sh "{\"session_id\":\"S_B\",\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "B's Stop does not run pass 2 on A's handshake" '[ -z "$OUT" ] && [ -f "$TMP/.reload/summarizing" ]'
ck "no arm was stamped by B" '[ -z "$(ls "$TMP/.reload/pending"* 2>/dev/null)" ]'
mktx 600000
OUT="$(run "$ME" stop-hook.sh "{\"session_id\":\"S_B\",\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "B over budget will not overwrite A's live handshake: no block" '! printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "B gets the notify path instead" 'msg "$OUT" | grep -q "/snapshot"'
ck "A's handshake intact" 'grep -q "^pid: $LIVE$" "$TMP/.reload/summarizing"'
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_C","source":"startup"}')"
ck "startup keeps a foreign LIVE handshake" '[ -f "$TMP/.reload/summarizing" ]'
printf 'S_Q\npid: %s\n' "$DEAD" > "$TMP/.reload/summarizing"
run "$ME" sessionstart-hook.sh '{"session_id":"S_C","source":"startup"}' >/dev/null
ck "startup purges an orphaned handshake" '[ ! -e "$TMP/.reload/summarizing" ]'
# A's own pass 2 still completes on its own marker (the owner's Stop).
digest S_A MAGIC-A; touch -t 202001010000 "$TMP/.reload/summarizing"; printf 'S_A\npid: %s\n' "$LIVE" >> "$TMP/.reload/summarizing"; touch -t 202001010000 "$TMP/.reload/summarizing"
touch "$TMP/.reload/session.md"
OUT="$(run "$LIVE" stop-hook.sh "{\"session_id\":\"S_A\",\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "the owner's Stop completes pass 2" 'msg "$OUT" | grep -q "digest saved" && [ -f "$TMP/.reload/pending.$LIVE" ]'
ck "pass 2 stamps the arm with the owner's sid" '[ "$(sed -n 1p "$TMP/.reload/pending.$LIVE")" = "S_A" ]'

echo "== F12: a foreign live arm does not suppress this session's own pass 1; an own arm does =="
reset; digest S_A MAGIC-A; printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\n' > "$TMP/.reload/config"
arm "$LIVE" S_A >/dev/null; mktx 600000
OUT="$(run "$ME" stop-hook.sh "{\"session_id\":\"S_B\",\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "B blocks for its own snapshot despite A's arm" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "B's handshake carries B's pid" 'grep -q "^pid: $ME$" "$TMP/.reload/summarizing"'
rm -f "$TMP/.reload/summarizing"; arm "$ME" S_B >/dev/null
OUT="$(run "$ME" stop-hook.sh "{\"session_id\":\"S_B\",\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "own arm suppresses the re-block" '! printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "and the notice says the reload is armed" 'msg "$OUT" | grep -q "reload armed"'
rm -f "$TMP/.reload/pending"*; arm "$LIVE" S_A >/dev/null; rm -f "$TMP/.reload/notified"
OUT="$(run "" stop-hook.sh "{\"session_id\":\"S_B\",\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "notify text does not call a FOREIGN arm 'armed' for this session" '! msg "$OUT" | grep -q "reload armed"'

echo "== F04: the model stamp is per session =="
reset
run "" sessionstart-hook.sh '{"session_id":"S_A","source":"startup","model":"claude-sonnet-4-5[1m]"}' >/dev/null
run "" sessionstart-hook.sh '{"session_id":"S_B","source":"startup","model":"claude-opus-4-8"}' >/dev/null
ck "both sessions have a stamp line" 'grep -q "^session: S_A claude-sonnet-4-5\[1m\] 1000000$" "$TMP/.reload/model" && grep -q "^session: S_B claude-opus-4-8 1000000$" "$TMP/.reload/model"'
ck "the legacy pair still reads the LAST stamp" '[ "$(grep -c "^model: claude-opus-4-8$" "$TMP/.reload/model")" -eq 1 ] && grep -q "^window: 1000000$" "$TMP/.reload/model"'
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"
mktx 90000 claude-sonnet-4-5-20250929          # A at 9% of 1M
OUT="$(run "" stop-hook.sh "{\"session_id\":\"S_A\",\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "A keeps its [1m] shield after B started: 9% is silent" '[ -z "$OUT" ]'
ck "A's line was not restamped to the bare 200K id" 'grep -q "^session: S_A claude-sonnet-4-5\[1m\] 1000000$" "$TMP/.reload/model"'
mktx 90000 claude-haiku-4-5-20251001            # A genuinely switched family
run "" stop-hook.sh "{\"session_id\":\"S_A\",\"transcript_path\":\"$TMP/t.jsonl\"}" >/dev/null
ck "a real family switch restamps A's own line only" 'grep -q "^session: S_A claude-haiku-4-5-20251001 200000$" "$TMP/.reload/model" && grep -q "^session: S_B claude-opus-4-8 1000000$" "$TMP/.reload/model"'
for i in $(seq 1 30); do run "" sessionstart-hook.sh "{\"session_id\":\"S_$i\",\"source\":\"clear\",\"model\":\"claude-opus-4-8\"}" >/dev/null; done
ck "session lines are capped (no unbounded growth across /clear)" '[ "$(grep -c "^session: " "$TMP/.reload/model")" -le 16 ]'
ck "the newest stamp survives the cap" 'grep -q "^session: S_30 " "$TMP/.reload/model"'
ESC="$(printf '\033')"
printf 'model: some\nwindow: 200000\nsession: S_A claude-sonnet-4-5[1m] 1000000\n' > "$TMP/.reload/model"; rm -f "$TMP/.reload/config"
SEG="$(printf '{"session_id":"S_A","context_window":{"used_percentage":7,"context_window_size":200000},"workspace":{"project_dir":"%s"}}' "$TMP" | bash "$ROOT/scripts/statusline.sh" | sed "s/${ESC}\[[0-9;]*m//g")"
ck "statusline reads ITS session's window, not the last stamp" '[ "$SEG" = "ctx[1M] 7%·45" ]'
SEG="$(printf '{"session_id":"S_Z","context_window":{"used_percentage":7,"context_window_size":200000},"workspace":{"project_dir":"%s"}}' "$TMP" | bash "$ROOT/scripts/statusline.sh" | sed "s/${ESC}\[[0-9;]*m//g")"
ck "an unknown session falls back to the legacy pair" '[ "$SEG" = "ctx[200k] 7%·45" ]'

echo "== F11: the journal takes note when a snapshot is taken, armed, side-filed, rehydrated, deferred =="
reset; digest S_A MAGIC-A
printf '%s' "{\"session_id\":\"S_A\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" \
  | CLAUDE_PID="$ME" CLAUDE_PROJECT_DIR="$TMP" bash "$H/pretooluse-hook.sh" >/dev/null
ck "a Write to the digest is journaled as a snapshot" 'grep -q " snapshot sid=S_A pid=$ME" "$TMP/.reload/journal"'
arm "$ME" S_A >/dev/null
ck "an arm is journaled" 'grep -q " arm sid=S_A pid=$ME" "$TMP/.reload/journal"'
run "$ME" sessionstart-hook.sh '{"session_id":"S_A2","source":"clear"}' >/dev/null
ck "a rehydrate is journaled with its source" 'grep -q " rehydrate sid=S_A2 pid=$ME clear" "$TMP/.reload/journal"'
ck "events are in order: snapshot, arm, rehydrate" '[ "$(grep -oE " (snapshot|arm|rehydrate) " "$TMP/.reload/journal" | tr -d " " | tr "\n" ",")" = "snapshot,arm,rehydrate," ]'
ck "every line carries a UTC timestamp" '! grep -vqE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z " "$TMP/.reload/journal"'
arm "$LIVE" S_L >/dev/null
run "$ME" sessionstart-hook.sh '{"session_id":"S_X","source":"startup"}' >/dev/null
ck "a deferral is journaled" 'grep -q " defer sid=S_X pid=$ME" "$TMP/.reload/journal"'
digest S_A MAGIC-A
printf '%s' "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" \
  | CLAUDE_PID="$ME" CLAUDE_PROJECT_DIR="$TMP" bash "$H/pretooluse-hook.sh" >/dev/null
ck "a side-file is journaled" 'grep -q " sidefile sid=S_B " "$TMP/.reload/journal"'
for i in $(seq 1 260); do printf '2026-01-01T00:00:00Z filler sid= pid= %s\n' "$i"; done > "$TMP/.reload/journal"
arm "$ME" S_A >/dev/null
ck "the journal is capped at 200 lines" '[ "$(wc -l < "$TMP/.reload/journal")" -le 200 ]'
ck "the cap keeps the newest lines" 'tail -n 1 "$TMP/.reload/journal" | grep -q " arm sid=S_A "'

echo "== F05: a digest over Claude Code's 10,000-char hook-output cap warns, and is still injected in full =="
reset
{ printf -- '---\nsession_id: "S_A"\nintent: "big"\n---\n## Next concrete step\n'; head -c 20000 /dev/zero | tr '\0' 'x'; echo; } > "$TMP/.reload/session.md"
arm "$ME" S_A >/dev/null
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_A2","source":"clear"}')"
ck "the full digest is still injected (no silent cut)" '[ "$(ctx "$OUT" | wc -c)" -gt 20000 ]'
ck "the banner warns about the 10,000-char cap" 'msg "$OUT" | grep -q "10,000"'
ck "the warning tells the user how to recover" 'msg "$OUT" | grep -q "/reload"'
reset; digest S_A MAGIC-SMALL; arm "$ME" S_A >/dev/null
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_A2","source":"clear"}')"
ck "a normal digest carries no cap warning" '! msg "$OUT" | grep -q "10,000"'

echo "== F06: an unwritable arm at compaction is reported by the SessionStart that follows =="
reset; digest S_A MAGIC-A; mkdir -p "$TMP/.reload/pending.$ME"
run "$ME" precompact-hook.sh '{"session_id":"S_A","trigger":"auto"}' >/dev/null
ck "PreCompact journals the failure" 'grep -q " arm-failed sid=S_A " "$TMP/.reload/journal"'
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_A","source":"compact"}')"
ck "SessionStart(compact) surfaces it (PreCompact's own systemMessage is discarded by Claude Code)" 'msg "$OUT" | grep -qi "not armed"'
OUT="$(run "$ME" sessionstart-hook.sh '{"session_id":"S_A","source":"compact"}')"
ck "reported once, not on every compaction after" '[ -z "$OUT" ]'
rmdir "$TMP/.reload/pending.$ME"

echo "== F07: fork is a documented SessionStart source; it keeps its context like resume =="
ck "hooks.json matches fork" 'jq -r ".hooks.SessionStart[0].matcher" "$ROOT/hooks/hooks.json" | grep -q "fork"'
reset; printf 'S_A\npid: %s\n' "$ME" > "$TMP/.reload/summarizing"; printf '30\n' > "$TMP/.reload/notified"
run "$ME" sessionstart-hook.sh '{"session_id":"S_F","source":"fork","model":"claude-opus-4-8"}' >/dev/null
ck "fork stamps its model" 'grep -q "^session: S_F claude-opus-4-8 " "$TMP/.reload/model"'
ck "fork does not purge the handshake or the ladder" '[ -f "$TMP/.reload/summarizing" ] && [ -f "$TMP/.reload/notified" ]'

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
