#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE="${ROOT}/optional/runtime-adapters"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'claude-adapter: %s\n' "$*" >&2; exit 1; }

EXAMPLE="${BUNDLE}/claude-code.settings.example.json"
[ -f "$EXAMPLE" ] && [ -f "${BUNDLE}/claude-code.md" ] \
	|| fail "guide and example must be beside the optional hook"
jq -e '.hooks | keys == ["PostToolUse", "PreToolUse", "Stop", "SubagentStop"]' \
	"$EXAMPLE" >/dev/null || fail "example must configure all four supported events"

TARGET="${TMP_DIR}/project with spaces"
mkdir -p "${TARGET}/optional/runtime-adapters" "${TARGET}/scripts"
cp "${BUNDLE}/claude-code-trace-hook.sh" "${TARGET}/optional/runtime-adapters/"
cp "${ROOT}/scripts/trace-lib.sh" "${TARGET}/scripts/"
cp "${ROOT}/VERSION" "$TARGET/"
git -C "$TARGET" init -q -b feature/issue-07-claude-fixture
git -C "$TARGET" config user.name "Harness Test"
git -C "$TARGET" config user.email "harness-test@example.invalid"
git -C "$TARGET" config commit.gpgsign false
git -C "$TARGET" add scripts optional VERSION
git -C "$TARGET" commit -qm 'configured hook fixture'
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID
for event in PreToolUse PostToolUse Stop SubagentStop; do
	command="$(jq -er --arg event "$event" '
		.hooks[$event] | if length == 1 and (.[0].hooks | length) == 1
		and .[0].hooks[0].type == "command" then .[0].hooks[0].command else error("bad hook") end
	' "$EXAMPLE")"
	# The template is repository-controlled; reject any unexpected shell command.
	# shellcheck disable=SC2016
	[ "$command" = '"$CLAUDE_PROJECT_DIR"/optional/runtime-adapters/claude-code-trace-hook.sh' ] \
		|| fail "configured command does not target the optional hook: ${event}"
	jq -cn --arg event "$event" --arg cwd "$TARGET" '{
		hook_event_name:$event, cwd:$cwd, session_id:"fixture-session",
		tool_use_id:"fixture-tool", tool_name:"Bash", tool_input:{command:"echo fixture"},
		tool_response:{is_error:false}, agent_type:"fixture-agent"
	}' >"${TMP_DIR}/payload"
	CLAUDE_PROJECT_DIR="$TARGET" bash -c "$command" <"${TMP_DIR}/payload" \
		>"${TMP_DIR}/stdout" 2>"${TMP_DIR}/stderr" || fail "${event} did not exit zero"
	[ ! -s "${TMP_DIR}/stdout" ] || fail "${event} wrote session-visible stdout"
done
TRACE="${TARGET}/.copilot-tracking/issues/issue-07/trace.jsonl"
[ -f "$TRACE" ] || fail "configured commands emitted no trace in the issue fixture"
jq -se --arg version "$(cat "${ROOT}/VERSION")" '
	length == 3
	and ([.[] | select(.span == "tool")] | length == 1)
	and ([.[] | select(.span == "agent")] | length == 2)
	and all(.[]; .["harness.version"] == $version)
	and all(.[]; has("gen_ai.usage.input_tokens") | not)
	and any(.[]; .["harness.duration_ms"] >= 0)
' "$TRACE" >/dev/null || fail "configured events lost emission or fabricated usage"

for sensor in "${BUNDLE}"/tests/test_claude_hook_*.sh; do
	[ -f "$sensor" ] || fail "optional behavioral sensors are missing"
	bash "$sensor" >"${TMP_DIR}/sensor.out" 2>&1 \
		|| { cat "${TMP_DIR}/sensor.out" >&2; fail "optional sensor failed: $(basename "$sensor")"; }
done
printf 'configured Claude adapter and session-safety contract honored\n'
