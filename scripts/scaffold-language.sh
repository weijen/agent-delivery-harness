#!/usr/bin/env bash
# Language profile scaffold generator — issue #37.
#
# Creates or updates a language's harness assets from in-script SKELETON
# templates so adding a language profile no longer requires copy-paste:
#
#   - profiles/<id>.profile.sh            (the Bash-sourced profile descriptor)
#   - .copilot/instructions/<id>.instructions.md  (the matching Copilot guide)
#
# The generator is conservative and visible (Delivery Plan step 5 of
# docs/multi-language-profiles.md § Generator):
#
#   * It refuses unknown profiles (known set = the five Built-In Profiles).
#   * It defaults to a dry run: it prints what it would create or update and
#     writes nothing.
#   * --write creates missing assets and is a no-op when an asset already
#     matches the canonical skeleton (idempotent); it refuses to overwrite an
#     existing asset that differs, printing the diff and asking for --update.
#   * --update overwrites a differing asset after showing the diff.
#   * It reports exactly which gates the profile will add to init.sh.
#   * It only ever writes under profiles/ and .copilot/instructions/. It never
#     touches the issue lifecycle, worktree, review-gate, or closeout scripts.
#
# The emitted descriptor/instruction files are SKELETONS; the real per-language
# gate logic and conventions land in the per-language profile issues (#38–#41).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILES_DIR="${REPO_ROOT}/profiles"
INSTRUCTIONS_DIR="${REPO_ROOT}/.copilot/instructions"

KNOWN_PROFILES="python go node java ruby"

usage() {
	cat <<'USAGE'
Usage: scaffold-language.sh <profile> [--write|--update]

  <profile>   one of: python go node java ruby
  (no flag)   dry run — print what would be created/updated, write nothing
  --write     create missing assets; no-op when already up to date;
              refuse (with diff) to overwrite an asset that differs
  --update    overwrite a differing asset after showing the diff

Generates profiles/<profile>.profile.sh and
.copilot/instructions/<profile>.instructions.md from skeleton templates.
USAGE
}

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

# --- Per-language metadata (from docs/multi-language-profiles.md § Built-In Profiles)
# Sets META_* globals for the given profile id. Bash 3.2 compatible (no assoc arrays).
load_metadata() {
	case "$1" in
	python)
		META_DETECT="pyproject.toml"
		META_TOOLS="uv"
		META_FRAMEWORKS="FastAPI Django Flask"
		META_GATES="format_check lint typecheck test"
		META_EXT="py"
		META_SYNC="uv sync --all-groups"
		;;
	go)
		META_DETECT="go.mod"
		META_TOOLS="go"
		META_FRAMEWORKS="Gin Echo Chi net/http"
		META_GATES="format_check lint test"
		META_EXT="go"
		META_SYNC="go mod download"
		;;
	node)
		META_DETECT="package.json"
		META_TOOLS="node"
		META_FRAMEWORKS="Next.js Express NestJS"
		META_GATES="format_check lint typecheck test"
		META_EXT="ts"
		META_SYNC="pnpm install"
		;;
	java)
		META_DETECT="pom.xml"
		META_TOOLS="java"
		META_FRAMEWORKS="Spring-Boot Quarkus"
		META_GATES="format_check lint test"
		META_EXT="java"
		META_SYNC="./mvnw -q dependency:resolve"
		;;
	ruby)
		META_DETECT="Gemfile"
		META_TOOLS="ruby"
		META_FRAMEWORKS="Rails Sinatra Hanami"
		META_GATES="lint test"
		META_EXT="rb"
		META_SYNC="bundle install"
		;;
	*)
		return 1
		;;
	esac
}

# Echo "command|OK|FAIL|FIX" for a (profile, gate-slot) pair. Skeleton commands
# carry the intended real tool invocation; the per-language issue refines them.
# shellcheck disable=SC2016  # literal command text is intentional in the emitted descriptor
gate_spec() {
	case "$1:$2" in
	python:format_check) printf 'uv run ruff format --check .|ruff format clean|ruff format would reformat|uv run ruff format .' ;;
	python:lint) printf 'uv run ruff check|ruff clean|ruff failed|uv run ruff check' ;;
	python:typecheck) printf 'uv run mypy|mypy clean|mypy failed|uv run mypy' ;;
	python:test) printf 'uv run pytest -q|pytest passing|pytest failed|uv run pytest' ;;
	go:format_check) printf 'test -z "$(gofmt -l .)"|gofmt clean|gofmt would reformat|gofmt -w .' ;;
	go:lint) printf 'go vet ./...|go vet clean|go vet failed|go vet ./...' ;;
	go:test) printf 'go test ./...|go test passing|go test failed|go test ./...' ;;
	node:format_check) printf 'prettier --check .|prettier clean|prettier would reformat|prettier --write .' ;;
	node:lint) printf 'eslint .|eslint clean|eslint failed|eslint .' ;;
	node:typecheck) printf 'tsc --noEmit|tsc clean|tsc failed|tsc --noEmit' ;;
	node:test) printf 'pnpm test|tests passing|tests failed|pnpm test' ;;
	java:format_check) printf './mvnw -q spotless:check|spotless clean|spotless would reformat|./mvnw spotless:apply' ;;
	java:lint) printf './mvnw -q checkstyle:check|checkstyle clean|checkstyle failed|./mvnw checkstyle:check' ;;
	java:test) printf './mvnw -q test|junit passing|junit failed|./mvnw test' ;;
	ruby:lint) printf 'bundle exec standardrb|standardrb clean|standardrb failed|bundle exec standardrb --fix' ;;
	ruby:test) printf 'bundle exec rspec|rspec passing|rspec failed|bundle exec rspec' ;;
	*) return 1 ;;
	esac
}

# --- Canonical content builders ---------------------------------------------
emit_descriptor() {
	local id="$1" slot cmd ok fail fix
	local lang_title
	lang_title="$(printf '%s' "${id:0:1}" | tr '[:lower:]' '[:upper:]')${id:1}"
	cat <<EOF
# ${lang_title} profile descriptor — generated by scripts/scaffold-language.sh (issue #37).
#
# SKELETON. The per-language profile issue (#38–#41) refines the gate commands
# and metadata. Bash-sourced descriptor: scripts/init.sh sources this file and
# drives the surface label, dependency sync, and quality gates from the values
# and functions declared here. See profiles/README.md for the descriptor contract.
#
# shellcheck shell=bash
# These PROFILE_* variables are consumed by scripts/init.sh after sourcing, not
# within this file, so shellcheck cannot see their use.
# shellcheck disable=SC2034

# --- Metadata (Profile Interface fields) -------------------------------------
PROFILE_ID="${id}"
PROFILE_DETECT="${META_DETECT}"
PROFILE_VARIANTS=""
PROFILE_TOOL_REQUIREMENTS="${META_TOOLS}"
PROFILE_INSTRUCTIONS=".copilot/instructions/${id}.instructions.md"
PROFILE_FRAMEWORKS="${META_FRAMEWORKS}"
PROFILE_SURFACE_LABEL="${lang_title} surface detected (${META_DETECT})"

# --- Detection ---------------------------------------------------------------
profile_detect() { [ -f "\$PWD/${META_DETECT}" ]; }

# --- Dependency sync ---------------------------------------------------------
PROFILE_SYNC_OK="${id} dependencies synced"
PROFILE_SYNC_FAIL="${id} dependency sync failed"
PROFILE_SYNC_FIX="inspect: ${META_SYNC}"
PROFILE_TOOL_MISSING="${META_TOOLS} not installed but ${META_DETECT} present"
PROFILE_TOOL_MISSING_FIX="install: see ${id} toolchain docs"
PROFILE_SYNC_SKIP_MSG="no ${META_DETECT} yet — skipping ${id} sync (will become a hard check once code lands)"

profile_sync() { ${META_SYNC}; }

# --- Quality gates -----------------------------------------------------------
PROFILE_GATES=(${META_GATES})
EOF
	for slot in ${META_GATES}; do
		IFS='|' read -r cmd ok fail fix <<<"$(gate_spec "$id" "$slot")"
		cat <<EOF

profile_gate_${slot}() { ${cmd}; }  # TODO(${id} profile issue): confirm command
PROFILE_GATE_${slot}_OK="${ok}"
PROFILE_GATE_${slot}_FAIL="${fail}"
PROFILE_GATE_${slot}_FIX="${fix}"
EOF
	done
}

emit_instructions() {
	local id="$1"
	local lang_title
	lang_title="$(printf '%s' "${id:0:1}" | tr '[:lower:]' '[:upper:]')${id:1}"
	cat <<EOF
---
description: '${lang_title} conventions for the ${id} harness profile (SKELETON — issue #37).'
applyTo: '**/*.${META_EXT}'
---

# ${lang_title} Best Practices

> SKELETON generated by \`scripts/scaffold-language.sh\`. The per-language profile
> issue (#38–#41) fills in the real ${lang_title} conventions. While this profile
> has no project code it is intentionally inert.

## Gates

This profile contributes the following \`init.sh\` gates: ${META_GATES}.

## Frameworks

Supported framework hints: ${META_FRAMEWORKS}.

## TODO

- Fill in ${lang_title} project & environment conventions.
- Fill in formatting, lint, type-check, and test guidance per gate.
EOF
}

# --- Reconcile one target file against canonical content --------------------
# Args: <path> <canonical-content>
reconcile() {
	local path="$1" canonical="$2"
	local rel="${path#"${REPO_ROOT}/"}"
	if [ ! -e "$path" ]; then
		if [ "$MODE" = "dry" ]; then
			printf '  would create %s\n' "$rel"
		else
			mkdir -p "$(dirname "$path")"
			printf '%s\n' "$canonical" >"$path"
			printf '  created %s\n' "$rel"
		fi
		return 0
	fi
	if printf '%s\n' "$canonical" | cmp -s - "$path"; then
		printf '  up to date %s\n' "$rel"
		return 0
	fi
	# Exists and differs.
	if [ "$MODE" = "update" ]; then
		printf '  updating %s (diff):\n' "$rel"
		printf '%s\n' "$canonical" | diff -u "$path" - || true
		printf '%s\n' "$canonical" >"$path"
		printf '  updated %s\n' "$rel"
	else
		printf '  differs %s — pass --update to overwrite (diff):\n' "$rel"
		printf '%s\n' "$canonical" | diff -u "$path" - || true
	fi
}

# --- Argument parsing --------------------------------------------------------
PROFILE=""
MODE="dry"
for arg in "$@"; do
	case "$arg" in
	--write) MODE="write" ;;
	--update) MODE="update" ;;
	-h | --help)
		usage
		exit 0
		;;
	-*) die "unknown option '$arg'" ;;
	*)
		[ -z "$PROFILE" ] || die "unexpected extra argument '$arg'"
		PROFILE="$arg"
		;;
	esac
done

if [ -z "$PROFILE" ]; then
	usage >&2
	die "no profile given (known: ${KNOWN_PROFILES})"
fi

if ! load_metadata "$PROFILE"; then
	die "unknown profile '$PROFILE' (known: ${KNOWN_PROFILES})"
fi

printf 'Profile: %s\n' "$PROFILE"
printf 'Gates this profile adds to init.sh: %s\n' "$META_GATES"
case "$MODE" in
dry) printf 'Mode: dry run (no files written; pass --write to apply)\n' ;;
write) printf 'Mode: write\n' ;;
update) printf 'Mode: update (overwrite differing files)\n' ;;
esac

reconcile "${PROFILES_DIR}/${PROFILE}.profile.sh" "$(emit_descriptor "$PROFILE")"
reconcile "${INSTRUCTIONS_DIR}/${PROFILE}.instructions.md" "$(emit_instructions "$PROFILE")"
