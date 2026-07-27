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

echo; echo "RESULT: $pass passed, $fail failed"; exit $fail
