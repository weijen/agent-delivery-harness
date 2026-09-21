#!/usr/bin/env bash
# harness-sensor-stage: boundary
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
INSTALL="${ROOT}/scripts/install-harness.sh"
OUT="${TMP_DIR}/install.out"
fail() { printf 'installed-claude: %s\n' "$*" >&2; exit 1; }

DEFAULT="${TMP_DIR}/default"
"$INSTALL" "$DEFAULT" --write >"$OUT" 2>&1
[ ! -e "${DEFAULT}/optional/runtime-adapters" ] || fail "default shipped the optional bundle"
[ ! -e "${DEFAULT}/tests/scripts/test_claude_adapter.sh" ] || fail "default depends on optional sensors"
if "${DEFAULT}/scripts/install-harness.sh" "${TMP_DIR}/missing" --write --with-claude >"$OUT" 2>&1; then
	fail "core-only source must not pretend to provide optional dependencies"
fi
grep -Fq 'Claude asset manifest missing' "$OUT" || fail "missing optional source was not diagnosed"
[ ! -e "${TMP_DIR}/missing" ] || fail "missing optional source partially wrote a target"

TARGET="${TMP_DIR}/installed with spaces"
mkdir -p "${TARGET}/.claude"
printf '{"permissions":{"deny":["Read(secret/**)"]},"hooks":{"Stop":[]}}\n' \
	>"${TARGET}/.claude/settings.json"
printf '{"env":{"ADOPTER_SETTING":"preserve"}}\n' >"${TARGET}/.claude/settings.local.json"
cp "${TARGET}/.claude/settings.json" "${TMP_DIR}/settings.before"
cp "${TARGET}/.claude/settings.local.json" "${TMP_DIR}/local.before"
"$INSTALL" "$TARGET" --write --with-claude >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "explicit optional install failed"; }
for mode in dry update; do
	args=("$TARGET" --with-claude)
	[ "$mode" = dry ] || args+=("--update")
	"${TARGET}/scripts/install-harness.sh" "${args[@]}" >"$OUT" 2>&1 \
		|| { cat "$OUT" >&2; fail "installed optional mode is not self-contained/idempotent"; }
done
cmp -s "${TMP_DIR}/settings.before" "${TARGET}/.claude/settings.json" \
	|| fail "installer merged or overwrote project settings"
cmp -s "${TMP_DIR}/local.before" "${TARGET}/.claude/settings.local.json" \
	|| fail "installer merged or overwrote local settings"

# Existing optional coverage must also run from the actual installed tree.
(cd "$TARGET" && bash tests/scripts/test_claude_adapter.sh) >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "installed optional behavioral suite failed"; }
git -C "$TARGET" init -q -b feature/issue-19-installed-hook
git -C "$TARGET" config user.name "Harness Test"
git -C "$TARGET" config user.email "harness-test@example.invalid"
git -C "$TARGET" config commit.gpgsign false
git -C "$TARGET" add scripts optional VERSION
git -C "$TARGET" commit -qm 'installed hook fixture'
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID
command="$(jq -er '.hooks.PostToolUse[0].hooks[0].command' \
	"${TARGET}/optional/runtime-adapters/claude-code.settings.example.json")"
jq -cn --arg cwd "$TARGET" '{
	hook_event_name:"PostToolUse", cwd:$cwd, tool_name:"Read", tool_input:{file_path:"fixture"}
}' >"${TMP_DIR}/payload"
CLAUDE_PROJECT_DIR="$TARGET" bash -c "$command" <"${TMP_DIR}/payload" >"${TMP_DIR}/hook.out"
[ ! -s "${TMP_DIR}/hook.out" ] || fail "installed hook wrote stdout"
trace="${TARGET}/.copilot-tracking/issues/issue-19/trace.jsonl"
jq -se --arg version "$(cat "${ROOT}/VERSION")" '
	length == 1 and .[0].span == "tool" and .[0]["harness.version"] == $version
	and (.[0] | has("harness.duration_ms") | not)
	and (.[0] | has("harness.outcome") | not)
' "$trace" >/dev/null || fail "installed emitter omitted its version or fabricated missing observations"

mv "${TARGET}/scripts/lib/trace-lib.sh" "${TMP_DIR}/trace-lib.saved"
CLAUDE_PROJECT_DIR="$TARGET" bash -c "$command" <"${TMP_DIR}/payload" >"${TMP_DIR}/hook.out"
[ ! -s "${TMP_DIR}/hook.out" ] || fail "missing installed emitter disturbed the session"
[ "$(wc -l <"$trace" | tr -d ' ')" = 1 ] || fail "missing emitter produced fake evidence"
mv "${TMP_DIR}/trace-lib.saved" "${TARGET}/scripts/lib/trace-lib.sh"

FRESH="${TMP_DIR}/fresh"
"${TARGET}/scripts/install-harness.sh" "$FRESH" --write --with-claude >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "installed optional source cannot create a fresh target"; }
[ ! -e "${FRESH}/.claude" ] || fail "fresh installation enabled or seeded Claude settings"
printf '\n# adopter hook customization\n' >>"${FRESH}/optional/runtime-adapters/claude-code-trace-hook.sh"
"$INSTALL" "$FRESH" --update --with-claude >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "adopter-only hook customization was not preserved"; }
grep -Fq 'adopter hook customization' "${FRESH}/optional/runtime-adapters/claude-code-trace-hook.sh" \
	|| fail "optional update overwrote hook customization"

"$INSTALL" "$TARGET" --update >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "documented optional deselection failed"; }
[ ! -e "${TARGET}/optional/runtime-adapters/claude-code-trace-hook.sh" ] \
	|| fail "deselection kept an unchanged installer-owned hook"
cmp -s "${TMP_DIR}/settings.before" "${TARGET}/.claude/settings.json" \
	|| fail "deselection silently edited project settings"
cmp -s "${TMP_DIR}/local.before" "${TARGET}/.claude/settings.local.json" \
	|| fail "deselection silently edited local settings"
"$INSTALL" "${TMP_DIR}/combined" --write --with-dev-sensors --with-claude >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "independent opt-ins cannot be combined"; }
[ -x "${TMP_DIR}/combined/tests/evals/bin/run-l0-suite.sh" ] \
	&& [ -x "${TMP_DIR}/combined/optional/runtime-adapters/claude-code-trace-hook.sh" ] \
	|| fail "combined opt-ins dropped a requested runtime"
[ ! -e "${TMP_DIR}/combined/.claude" ] || fail "combined opt-ins enabled Claude settings"
printf 'explicit installed Claude opt-in preserves settings and runtime boundaries\n'
