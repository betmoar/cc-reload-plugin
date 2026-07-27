#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
#
# cc-reload END-TO-END regression. The other suites exercise each hook in
# isolation; this one chains the REAL hooks through ONE shared .reload/ dir and
# asserts the working-thread CONTENT survives a full session→reset→session round
# trip. This is the regression that matters between releases: a digest written in
# session A must reach the context injected into session B, marker handshake and
# all, with no cross-wiring between the budgeted and compaction reset paths.
#
# Run from anywhere: bash tests/test-e2e.sh   (exit code = #failures)
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
run(){ # script source-json  -> runs the real hook against $TMP as the project dir
  printf '%s' "$2" | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$(dirname "$H")" bash "$H/$1"
}
mktx(){ # used_tokens -> transcript with a matching live model id
  printf '{"message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1" > "$TMP/t.jsonl"
}
# The model can't author a digest inside a hook; the checkpoint turn does. Simulate
# THAT turn: session.md must end up strictly NEWER than the summarizing marker so
# the pass-2 freshness check (-nt) sees a genuine refresh. A real checkpoint turn
# takes many seconds; bash 3.2's `test -nt` on macOS is second-granularity, so a
# sub-second sleep would land in the same second and misread as stale (backlog #2).
# Backdate the marker to a fixed past time — portable across BSD/GNU touch and the
# same trick the isolated suites use — so the just-written digest is always newer.
author_digest(){ # marker-relative freshness + distinctive content
  touch -t 202001010000 "$TMP/.reload/summarizing"
  cat > "$TMP/.reload/session.md" <<EOF
---
session_id: "SESS-A"
updated_at: "2026-07-02T00:00:00Z"
intent: "wire the reload-config validator into /reload-budget"
---
## Done this stretch
- MAGIC-DONE-7f3 landed reload-config.sh with atomic writes
## In flight
- MAGIC-INFLIGHT-9a1 repointing reload-budget.md at the validator
## Next concrete step
MAGIC-NEXT-b52 run the e2e suite, then squash-merge to main
## Open questions & risks
- none blocking
EOF
}

# ── CYCLE 1: the budgeted automated path (checkpoint mode), session A → /clear → session B ──
echo "== E2E cycle 1: checkpoint mode → pass1 block → digest authored → pass2 arm → /clear rehydrate =="

# Session A boots: stamp the model+window so Stop can compute a real %.
run sessionstart-hook.sh '{"session_id":"SESS-A","source":"startup","model":"claude-opus-4-8"}' >/dev/null
ck "1.0 session A stamped a 1M window" 'grep -q "window: 1000000" "$TMP/.reload/model"'
printf 'context_budget_pct: 45\ncontext_budget_mode: snapshot\n' > "$TMP/.reload/config"
rm -f "$TMP/.reload/pending" "$TMP/.reload/summarizing" "$TMP/.reload/session.md"

# Occupancy crosses budget (50% ≥ 45%): pass 1 must block and demand a digest.
mktx 500000
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "1.1 pass1 blocks the stop"          'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "1.2 pass1 asks for session.md"      'printf "%s" "$OUT" | jq -e ".reason|test(\"session.md\")" >/dev/null'
ck "1.3 pass1 surfaces the real %"      'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"50%\")" >/dev/null'
ck "1.4 summarizing handshake on disk"  '[ -f "$TMP/.reload/summarizing" ]'
ck "1.5 not armed yet (digest unwritten)" '[ ! -f "$TMP/.reload/pending" ]'

# The checkpoint turn runs and the model authors the digest.
author_digest

# Next Stop = pass 2: consume the marker, arm the reload, report a FRESH save.
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "1.6 pass2 armed the reload"          '[ -f "$TMP/.reload/pending" ]'
ck "1.7 pass2 cleared the handshake"     '[ ! -f "$TMP/.reload/summarizing" ]'
ck "1.8 pass2 reports a fresh save"      'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"digest saved\")" >/dev/null'
ck "1.9 pass2 did NOT emit a stale warning" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"NOT refresh\")" >/dev/null'

# /clear mints a FRESH session id. SessionStart(clear) must rehydrate regardless
# of the id mismatch (invariant 3) and the DISTINCTIVE content must round-trip.
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-B-FRESH","source":"clear","model":"claude-opus-4-8"}')"
ck "1.10 content round-trips: Next step" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-NEXT-b52\")" >/dev/null'
ck "1.11 content round-trips: Done"      'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-DONE-7f3\")" >/dev/null'
ck "1.12 banner leads with the intent"   'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"wire the reload-config\")" >/dev/null'
ck "1.13 banner points at Next step"     'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"MAGIC-NEXT-b52\")" >/dev/null'
ck "1.14 one-shot marker consumed"       '[ ! -f "$TMP/.reload/pending" ]'

# The reset is done: a SECOND SessionStart must NOT re-inject (arm was one-shot).
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-B-FRESH","source":"clear","model":"claude-opus-4-8"}')"
ck "1.15 no double rehydrate after consume" '[ -z "$OUT" ]'

# ── CYCLE 2: the compaction path, no agent-authored digest present ─────────────
echo "== E2E cycle 2: PreCompact floor → SessionStart(compact) rehydrates the stub =="
rm -f "$TMP/.reload/pending" "$TMP/.reload/session.md"
run precompact-hook.sh '{"session_id":"SESS-C","trigger":"auto","hook_event_name":"PreCompact"}' >/dev/null
ck "2.1 PreCompact armed a reload"       '[ -f "$TMP/.reload/pending" ]'
ck "2.2 PreCompact wrote a fallback digest" '[ -f "$TMP/.reload/session.md" ]'
ck "2.3 fallback is honest about being thin" 'grep -q "mechanical fallback" "$TMP/.reload/session.md"'
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-D","source":"compact","model":"claude-opus-4-8"}')"
ck "2.4 compact rehydrates the fallback" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"Re-derive state\")" >/dev/null'
ck "2.5 compact consumed the arm"        '[ ! -f "$TMP/.reload/pending" ]'

# ── CYCLE 3: a deliberate /clear with nothing armed must be RESPECTED ──────────
echo "== E2E cycle 3: unarmed /clear → no rehydration (intentional context drop) =="
rm -f "$TMP/.reload/pending"
# session.md still exists on disk, but nothing is armed → must stay silent.
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-E","source":"clear","model":"claude-opus-4-8"}')"
ck "3.1 unarmed clear injects nothing"   '[ -z "$OUT" ]'
ck "3.2 digest left intact on disk"      '[ -f "$TMP/.reload/session.md" ]'

# ── CYCLE 4: cross-session isolation — a stale digest arms but is flagged ──────
echo "== E2E cycle 4: checkpoint turn that did NOT refresh the digest → armed as floor, flagged =="
rm -f "$TMP/.reload/pending"
# Digest predates the marker (checkpoint turn never rewrote it).
touch -t 202001010000 "$TMP/.reload/session.md" 2>/dev/null || touch "$TMP/.reload/session.md"
touch "$TMP/.reload/summarizing"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "4.1 stale digest still arms (floor)" '[ -f "$TMP/.reload/pending" ]'
ck "4.2 stale save is flagged honestly"  'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"NOT refresh\")" >/dev/null'
ck "4.3 handshake cleared"               '[ ! -f "$TMP/.reload/summarizing" ]'

# ── CYCLE 5: notify-first (DEFAULT mode) — nudge, manual /snapshot, /clear rehydrate ──
echo "== E2E cycle 5: notify default → nudge only → manual /snapshot → /clear rehydrate =="
printf 'context_budget_pct: 45\n' > "$TMP/.reload/config"   # no mode key -> notify default
rm -f "$TMP/.reload/pending" "$TMP/.reload/notified" "$TMP/.reload/summarizing"
mktx 500000   # 50% >= 45%
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "5.1 nudge names /snapshot + the %"   'printf "%s" "$OUT" | jq -e "(.systemMessage|test(\"/snapshot\")) and (.systemMessage|test(\"50%\"))" >/dev/null'
ck "5.2 no block on the nudge"             'printf "%s" "$OUT" | jq -e ".decision == null" >/dev/null'
ck "5.3 no handshake marker in notify"     '[ ! -f "$TMP/.reload/summarizing" ]'
ck "5.4 nothing armed by the nudge"        '[ ! -f "$TMP/.reload/pending" ]'
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "5.5 next turn same occupancy -> silent" '[ -z "$OUT" ]'
# The user answers the nudge with /snapshot: the command writes the digest and arms.
cat > "$TMP/.reload/session.md" <<'EOF'
---
session_id: "SESS-N"
updated_at: "2026-07-10T00:00:00Z"
intent: "notify-mode continuity check"
---
## Done this stretch
- MAGIC-N5-DONE
## In flight
- nothing
## Next concrete step
MAGIC-N5-NEXT resume here
## Open questions & risks
- none
EOF
touch "$TMP/.reload/pending"
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "5.6 armed + already nudged -> still silent, still no block" '[ -z "$OUT" ]'
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-N2","source":"clear","model":"claude-opus-4-8"}')"
ck "5.7 /clear rehydrates the manual digest" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-N5-NEXT\")" >/dev/null'
ck "5.8 arm consumed"                        '[ ! -f "$TMP/.reload/pending" ]'
ck "5.9 notify ladder reset by the /clear"   '[ ! -f "$TMP/.reload/notified" ]'

# ── CYCLE 6: interrupted checkpoint — leaked handshake must not poison the next session ──
echo "== E2E cycle 6: leaked summarizing marker is purged on /clear (no stale arm) =="
touch "$TMP/.reload/summarizing"; rm -f "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-F","source":"clear","model":"claude-opus-4-8"}')"
ck "6.1 unarmed clear stays silent"          '[ -z "$OUT" ]'
ck "6.2 leaked handshake purged"             '[ ! -f "$TMP/.reload/summarizing" ]'
mktx 50000   # 5% — fresh session, well under budget
OUT="$(run stop-hook.sh "{\"transcript_path\":\"$TMP/t.jsonl\"}")"
ck "6.3 first Stop of fresh session is silent (no phantom pass 2)" '[ -z "$OUT" ]'
ck "6.4 nothing armed in the fresh session"  '[ ! -f "$TMP/.reload/pending" ]'

# ── CYCLE 7: two sessions, one tree — collision is loud, rehydrate still works ──
echo "== E2E cycle 7: session B clobbers session A's digest -> side-filed + warned =="
rm -rf "$TMP/.reload"; mkdir -p "$TMP/.reload"

# Session A snapshots (simulating what /snapshot writes, with a runtime id).
cat > "$TMP/.reload/session.md" <<'EOF'
---
session_id: "SESS-A"
updated_at: "2026-07-27T10:00:00Z"
intent: "session A axes 3+4 spec work"
---
## Done this stretch
- MAGIC-A-DONE drafted the ownership section
## In flight
- MAGIC-A-INFLIGHT reviewing the arm semantics
## Next concrete step
MAGIC-A-NEXT finish the acceptance criteria
## Open questions & risks
- none
EOF

# Session B is about to Write the same path. The PreToolUse hook fires FIRST.
OUT="$(printf '%s' "{\"session_id\":\"SESS-B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" \
  | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$(dirname "$H")" bash "$H/pretooluse-hook.sh")"
ck "7.1 A's digest was side-filed" '[ -f "$TMP/.reload/session.SESS-A.md" ]'
ck "7.2 side-file holds A's working thread" 'grep -q "MAGIC-A-NEXT" "$TMP/.reload/session.SESS-A.md"'
ck "7.3 B was warned, naming A" 'printf "%s" "$OUT" | grep -q "SESS-A"'

# B's write then lands (the hook permitted it).
cat > "$TMP/.reload/session.md" <<'EOF'
---
session_id: "SESS-B"
updated_at: "2026-07-27T10:30:00Z"
intent: "session B implementing the guard"
---
## Done this stretch
- MAGIC-B-DONE wrote claim-digest.sh
## In flight
- MAGIC-B-INFLIGHT wiring the PreToolUse hook
## Next concrete step
MAGIC-B-NEXT run the e2e suite
## Open questions & risks
- none
EOF
ck "7.4 B's write succeeded" 'grep -q "MAGIC-B-NEXT" "$TMP/.reload/session.md"'
ck "7.5 A's copy survives alongside it" 'grep -q "MAGIC-A-NEXT" "$TMP/.reload/session.SESS-A.md"'

# B arms and clears: rehydrates B's own thread, no warning.
run precompact-hook.sh '{"session_id":"SESS-B","trigger":"manual"}' >/dev/null
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-B","source":"clear"}')"
ck "7.6 B rehydrates its own thread" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-B-NEXT\")" >/dev/null'
ck "7.7 own arm -> no cross-session warning" '! printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'

# Now A clears against B's arm: STILL rehydrates (invariant), but is warned.
printf 'SESS-A' > "$TMP/.reload/pending"
OUT="$(run sessionstart-hook.sh '{"session_id":"SESS-B","source":"clear"}')"
ck "7.8 foreign arm STILL rehydrates (v0.1.5 regression guard)" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-B-NEXT\")" >/dev/null'
ck "7.9 foreign arm warns" 'printf "%s" "$OUT" | jq -e ".systemMessage|test(\"different session\")" >/dev/null'

echo "== E2E cycle 8: two project dirs are fully isolated =="
# NOTE: this REPLACES the file's existing `trap 'rm -rf "$TMP"' EXIT` (test-e2e.sh:14).
# The replacement still cleans $TMP, so nothing leaks — but if you add a $TMP_C later,
# it must go in this same trap, not a third one.
TMP_B="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP_B"' EXIT
mkdir -p "$TMP_B/.reload"
printf -- '---\nsession_id: "OTHER"\nupdated_at: "x"\nintent: "other tree"\n---\n## Next concrete step\nMAGIC-OTHER-NEXT\n' > "$TMP_B/.reload/session.md"
printf 'OTHER' > "$TMP_B/.reload/pending"
OUT="$(printf '%s' '{"session_id":"OTHER","source":"clear"}' \
  | CLAUDE_PROJECT_DIR="$TMP_B" CLAUDE_PLUGIN_ROOT="$(dirname "$H")" bash "$H/sessionstart-hook.sh")"
ck "8.1 tree B rehydrates its own digest" 'printf "%s" "$OUT" | jq -e ".hookSpecificOutput.additionalContext|test(\"MAGIC-OTHER-NEXT\")" >/dev/null'
ck "8.2 tree A is untouched by tree B" 'grep -q "MAGIC-B-NEXT" "$TMP/.reload/session.md"'
ck "8.3 tree B never saw tree A's side-file" '[ ! -f "$TMP_B/.reload/session.SESS-A.md" ]'

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
