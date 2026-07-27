#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT is consumed inside ck()'s eval'd assertions
# claim-digest.sh + pretooluse-hook.sh tests. Run: bash tests/test-claim-digest.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.reload"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required (lib.sh exits silently without it, which would false-green this whole suite)"; exit 99; }
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

# A "nothing happened" assertion must not pass merely because the implementation
# is MISSING. `foo: command not found` and `No such file` both go to stderr and
# leave stdout empty, so a bare [ -z "$(...)" ] passes before any code exists —
# which would make the TDD "verify it fails" step lie. Gate those on the
# implementation being present.
have(){ [ -f "$ROOT/$1" ]; }
have_fn(){ grep -q "^$1()" "$ROOT/hooks/lib.sh" 2>/dev/null; }

# Source lib.sh the way a hook does, with the temp dir as the project.
# In `bash -c '<script>' ARG`, $0 is set to ARG — so $0 is $ROOT here, and the
# function name is interpolated from the OUTER function's $1. Do not "fix" this.
libcall(){ # libcall <function-name>   (bare identifier only — it is interpolated)
  CLAUDE_PROJECT_DIR="$TMP" bash -c \
    'source "$0/hooks/lib.sh"; '"$1" "$ROOT"
}

echo "== digest_owner: reads the frontmatter session_id =="
printf -- '---\nsession_id: "S_A"\nupdated_at: "x"\nintent: "i"\n---\n' > "$TMP/.reload/session.md"
ck "reads a quoted id" '[ "$(libcall digest_owner)" = "S_A" ]'

printf -- '---\nsession_id: ""\n---\n' > "$TMP/.reload/session.md"
ck "empty id reads empty" 'have_fn digest_owner && [ -z "$(libcall digest_owner)" ]'

printf -- '## Done this stretch\nno frontmatter at all\n' > "$TMP/.reload/session.md"
ck "no frontmatter reads empty" 'have_fn digest_owner && [ -z "$(libcall digest_owner)" ]'

# The body is UNTRUSTED (CLAUDE.md invariant 8). kv() greps ^session_id: anywhere
# in the file, so a body line starting with it would be read as the owner.
printf -- '---\nsession_id: "S_A"\n---\n## Open questions\nsession_id: NOT-THE-OWNER\n' > "$TMP/.reload/session.md"
ck "body line does NOT override frontmatter" '[ "$(libcall digest_owner)" = "S_A" ]'

rm -f "$TMP/.reload/session.md"
ck "absent digest reads empty" 'have_fn digest_owner && [ -z "$(libcall digest_owner)" ]'

echo "== owner_window: default and override =="
rm -f "$TMP/.reload/config"
ck "default is 14400" '[ "$(libcall owner_window)" = "14400" ]'
printf 'context_owner_window: 60\n' > "$TMP/.reload/config"
ck "override honored" '[ "$(libcall owner_window)" = "60" ]'
printf 'context_owner_window: 0\n' > "$TMP/.reload/config"
ck "zero honored (disables)" '[ "$(libcall owner_window)" = "0" ]'
printf 'context_owner_window: garbage\n' > "$TMP/.reload/config"
ck "garbage falls back to default" '[ "$(libcall owner_window)" = "14400" ]'
rm -f "$TMP/.reload/config"

claim(){ CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/scripts/claim-digest.sh" "$@"; }
fresh_digest(){ # fresh_digest <owner-id>  -> a digest owned by <owner-id>, mtime now
  printf -- '---\nsession_id: "%s"\nupdated_at: "x"\nintent: "work by %s"\n---\n## Done this stretch\n- BODY-%s\n' \
    "$1" "$1" "$1" > "$TMP/.reload/session.md"
}
reset_reload(){ rm -f "$TMP"/.reload/session.*.md "$TMP/.reload/session.md" "$TMP/.reload/config"; }

echo "== claim-digest: foreign fresh incumbent is side-filed =="
reset_reload; fresh_digest S_A
OUT="$(claim S_B)"
ck "side-file created" '[ -f "$TMP/.reload/session.S_A.md" ]'
ck "side-file holds the incumbent body" 'grep -q "BODY-S_A" "$TMP/.reload/session.S_A.md"'
ck "warning names the incumbent" 'printf "%s" "$OUT" | grep -q "S_A"'
ck "exit 0" 'claim S_B >/dev/null; [ $? -eq 0 ]'
ck "digest itself untouched (caller writes it)" 'grep -q "BODY-S_A" "$TMP/.reload/session.md"'

echo "== claim-digest: a second claim with the SAME bytes is already preserved -> silent =="
# /snapshot reaches this comparator twice for one write: the command's own
# courtesy call, then PreToolUse on the Write it triggers. Byte-identical
# incumbent content means the first call already preserved it — the second
# call must not stamp a redundant mtime-suffixed copy or warn a second time.
reset_reload; fresh_digest S_A
claim S_B >/dev/null                      # first side-file: session.S_A.md
OUT="$(claim S_B)"                        # second call, SAME incumbent bytes
ck "still exactly one side-file" '[ "$(ls "$TMP"/.reload/session.S_A*.md 2>/dev/null | wc -l)" -eq 1 ]'
ck "second identical call is silent" '[ -z "$OUT" ]'

echo "== claim-digest: collision with DIFFERENT content appends mtime =="
reset_reload; fresh_digest S_A
claim S_B >/dev/null                      # first side-file
printf -- '---\nsession_id: "S_A"\nupdated_at: "y"\nintent: "work by S_A, take 2"\n---\n## Done this stretch\n- BODY-S_A-v2\n' > "$TMP/.reload/session.md"
touch "$TMP/.reload/session.md"           # ensure a distinct mtime for the suffix
claim S_B >/dev/null                      # second collision, genuinely different bytes
ck "a second, differently-named side-file exists" '[ "$(ls "$TMP"/.reload/session.S_A.*.md 2>/dev/null | wc -l)" -ge 1 ]'

echo "== claim-digest: silent when un-owned or self or stale or disabled =="
# NOTE: every "silent" assertion is gated on `have scripts/claim-digest.sh` — a
# missing script also produces empty stdout and no side-file, so an ungated
# assertion here passes BEFORE the implementation exists (false-green).
reset_reload; fresh_digest ""
ck "empty incumbent id -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session..md" ]'

reset_reload; fresh_digest S_B
ck "self-owned -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_B.md" ]'

reset_reload; fresh_digest S_A
ck "empty writer id -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim "")" ]'

reset_reload; fresh_digest S_A
touch -t 202001010000 "$TMP/.reload/session.md"      # far outside any window
ck "stale incumbent -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_A.md" ]'

reset_reload; fresh_digest S_A
printf 'context_owner_window: 0\n' > "$TMP/.reload/config"
ck "window 0 disables -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_A.md" ]'
reset_reload

echo "== claim-digest: the 4h default-window boundary (spec criterion 6) =="
# The criterion's actual claim is about the DEFAULT window, not an extreme date.
reset_reload; fresh_digest S_A
touch -t "$(date -v-239M +%Y%m%d%H%M 2>/dev/null || date -d '239 minutes ago' +%Y%m%d%H%M)" "$TMP/.reload/session.md"
ck "3h59m old -> side-filed" 'claim S_B >/dev/null; [ -f "$TMP/.reload/session.S_A.md" ]'

reset_reload; fresh_digest S_A
touch -t "$(date -v-241M +%Y%m%d%H%M 2>/dev/null || date -d '241 minutes ago' +%Y%m%d%H%M)" "$TMP/.reload/session.md"
ck "4h01m old -> silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_A.md" ]'
reset_reload

echo "== claim-digest: stands down for a cc-repete loop (spec criterion 9) =="
fresh_digest S_A
mkdir -p "$TMP/.repete"; printf -- '---\nactive: true\n---\n' > "$TMP/.repete/loop.local.md"
ck "repete active -> no side-file" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ] && [ ! -f "$TMP/.reload/session.S_A.md" ]'
rm -rf "$TMP/.repete"
ck "repete gone -> guard resumes" 'claim S_B >/dev/null; [ -f "$TMP/.reload/session.S_A.md" ]'
reset_reload

echo "== claim-digest: a hostile owner id cannot escape .reload/ =="
# The frontmatter is model-written and untrusted. cc-operator hit exactly this
# (ops-verdict.sh:276 records a 2026-07-10 path traversal through the same door).
reset_reload
printf -- '---\nsession_id: "../../ESCAPED"\nupdated_at: "x"\nintent: "hostile"\n---\n## Done this stretch\n- BODY-EVIL\n' > "$TMP/.reload/session.md"
claim S_B >/dev/null
ck "no file written outside .reload/" '[ ! -e "$TMP/../ESCAPED.md" ] && [ ! -e "$TMP/ESCAPED.md" ]'
# The negative assertion above also passes if the script silently does nothing
# at all (e.g. `tr -cd` regressed into a no-op that just skips the write). Pin
# down what SHOULD have happened: the `../` is stripped down to the safe
# charset and the side-file lands, by that sanitized name, inside .reload/.
ck "sanitized filename exists inside .reload/" '[ -f "$TMP/.reload/session.ESCAPED.md" ]'
reset_reload

echo "== claim-digest: no digest at all -> silent, exit 0 =="
ck "absent digest silent" 'have scripts/claim-digest.sh && [ -z "$(claim S_B)" ]'
ck "absent digest exits 0" 'have scripts/claim-digest.sh && { claim S_B >/dev/null; [ $? -eq 0 ]; }'

echo "== claim-digest: unwritable .reload still exits 0 and still warns (fail-open) =="
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP: running as root — chmod 500 does not block root, assertion would be vacuous"
else
  fresh_digest S_A
  chmod 500 "$TMP/.reload"
  OUT="$(claim S_B)"; RC=$?
  chmod 700 "$TMP/.reload"
  ck "unwritable dir still exits 0" '[ "$RC" -eq 0 ]'
  ck "unwritable dir still warns" 'printf "%s" "$OUT" | grep -q "could NOT be saved aside"'
fi
reset_reload

pth(){ # pth <json>  -> run the PreToolUse hook with that payload
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" \
    bash "$ROOT/hooks/pretooluse-hook.sh"
}

echo "== PreToolUse: Write to the digest triggers the guard =="
reset_reload; fresh_digest S_A
OUT="$(pth "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}")"
ck "side-files on the enforced path" '[ -f "$TMP/.reload/session.S_A.md" ]'
ck "permits the write (exit 0)" 'have hooks/pretooluse-hook.sh && { pth "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" >/dev/null; [ $? -eq 0 ]; }'
ck "never denies" 'have hooks/pretooluse-hook.sh && ! printf "%s" "$OUT" | grep -q "deny"'

echo "== PreToolUse: Edit is covered too =="
reset_reload; fresh_digest S_A
pth "{\"session_id\":\"S_B\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" >/dev/null
ck "Edit side-files" '[ -f "$TMP/.reload/session.S_A.md" ]'

echo "== PreToolUse: unrelated paths and tools are untouched =="
reset_reload; fresh_digest S_A
OUT="$(pth "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/somewhere-else.md\"}}")"
ck "other path -> no side-file" 'have hooks/pretooluse-hook.sh && [ ! -f "$TMP/.reload/session.S_A.md" ]'
ck "other path -> silent" 'have hooks/pretooluse-hook.sh && [ -z "$OUT" ]'

reset_reload; fresh_digest S_A
OUT="$(pth "{\"session_id\":\"S_B\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}")"
ck "Read -> no side-file" 'have hooks/pretooluse-hook.sh && [ ! -f "$TMP/.reload/session.S_A.md" ]'
ck "Read -> silent" 'have hooks/pretooluse-hook.sh && [ -z "$OUT" ]'

echo "== PreToolUse: a symlinked path still matches (no silent miss) =="
reset_reload; fresh_digest S_A
ln -s .reload "$TMP/linked-reload" 2>/dev/null
pth "{\"session_id\":\"S_B\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/linked-reload/session.md\"}}" >/dev/null
ck "symlinked digest path fires the guard" '[ -f "$TMP/.reload/session.S_A.md" ]'
rm -f "$TMP/linked-reload"
reset_reload

echo "== PreToolUse: malformed payload fails open =="
reset_reload; fresh_digest S_A
ck "empty stdin exits 0" 'have hooks/pretooluse-hook.sh && { printf "" | CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/hooks/pretooluse-hook.sh" >/dev/null 2>&1; [ $? -eq 0 ]; }'
ck "garbage stdin exits 0" 'have hooks/pretooluse-hook.sh && { printf "not json" | CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/hooks/pretooluse-hook.sh" >/dev/null 2>&1; [ $? -eq 0 ]; }'
ck "missing session_id exits 0" 'have hooks/pretooluse-hook.sh && { pth "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/.reload/session.md\"}}" >/dev/null; [ $? -eq 0 ]; }'
# The hook must not reference $CLAUDE_PLUGIN_ROOT: under `set -u` an unexported
# var is a fatal unbound error, and no production hook in this plugin gets it.
ck "does not depend on CLAUDE_PLUGIN_ROOT" '! grep -q "CLAUDE_PLUGIN_ROOT" "$ROOT/hooks/pretooluse-hook.sh"'
reset_reload

echo "== command prose carries the runtime-id instructions =="
ck "snapshot.md stamps session_id from the runtime" 'grep -q "CLAUDE_CODE_SESSION_ID" "$ROOT/commands/snapshot.md"'
ck "snapshot.md arms with an owner, not bare touch" '! grep -qE "^[0-9]+\. Arm the reload: .touch" "$ROOT/commands/snapshot.md"'
ck "snapshot.md calls the guard" 'grep -q "claim-digest.sh" "$ROOT/commands/snapshot.md"'

echo "== the documented invariant survives edits =="
ck "README states the one-session rule" 'grep -qi "one session per working directory" "$ROOT/README.md"'

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
