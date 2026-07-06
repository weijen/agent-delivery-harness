# Ruby language profile descriptor — issue #40.
#
# Bash-sourced profile descriptor. scripts/init.sh sources this file and drives
# the Ruby surface label and quality gates from the values and functions declared
# here. Ruby carries TWO load-bearing variant axes: the lint/format tool
# (Standard Ruby — a combined lint+format path — vs RuboCop) and the test
# framework (RSpec vs Minitest). A typecheck slot is added ONLY when the project
# explicitly configures Sorbet or Steep (empty-slot rule otherwise). Gates SKIP
# (return 2 → warn) when the Ruby toolchain is not installed. See
# profiles/README.md for the descriptor contract.
#
# shellcheck shell=bash
# These PROFILE_* variables are consumed by scripts/init.sh after sourcing, not
# within this file, so shellcheck cannot see their use.
# shellcheck disable=SC2034

# --- Metadata (Profile Interface fields) -------------------------------------
PROFILE_ID="ruby"
PROFILE_DETECT="Gemfile"
# Grep signatures (extended regex) proving a project-CI workflow runs this
# surface's gates (issue #129); consumed by scripts/ci-coverage-lib.sh.
PROFILE_CI_SIGNATURES="rubocop|standardrb|rspec|minitest|rake test"
PROFILE_VARIANTS="standardrb rubocop rspec minitest"
PROFILE_TOOL_REQUIREMENTS="ruby"
PROFILE_INSTRUCTIONS=".copilot/instructions/ruby.instructions.md"
PROFILE_FRAMEWORKS="Rails Sinatra Hanami"

# --- Helpers -----------------------------------------------------------------
# ruby_gemfile_has <pattern>: succeeds when the Gemfile or Gemfile.lock mentions
# <pattern> (a gem name). Used for variant detection without parsing Ruby.
ruby_gemfile_has() {
	grep -Eqi "$1" "$PWD/Gemfile" 2>/dev/null ||
		grep -Eqi "$1" "$PWD/Gemfile.lock" 2>/dev/null
}

# ruby_gemfile_direct_has <pattern>: succeeds only when the Gemfile itself (a
# direct dependency) mentions <pattern> — it ignores Gemfile.lock, which also
# lists transitive deps. The `standard` gem pulls in rubocop transitively, so a
# lockfile rubocop match must not be treated as an intentional RuboCop setup.
ruby_gemfile_direct_has() {
	grep -Eqi "$1" "$PWD/Gemfile" 2>/dev/null
}

# --- Detection ---------------------------------------------------------------
profile_detect() { [ -f "$PWD/Gemfile" ]; }

# --- Variant detection (load-bearing) ----------------------------------------
# Lint/format tool precedence:
#   1. an explicit .rubocop.yml          -> rubocop (an intentional RuboCop config wins)
#   2. Standard configured (.standard.yml or a direct `standard` gem) -> standardrb
#      (standard depends on rubocop transitively, so a lockfile-only rubocop
#       match must not beat an explicit Standard Ruby setup — see issue #72)
#   3. a rubocop gem present (Gemfile or lock) -> rubocop
#   4. otherwise prefer Standard Ruby for low-configuration lint+format.
PROFILE_RUBY_LINTER="standardrb"
if [ -f "$PWD/.rubocop.yml" ]; then
	PROFILE_RUBY_LINTER="rubocop"
elif [ -f "$PWD/.standard.yml" ] || ruby_gemfile_direct_has '\bstandard\b'; then
	PROFILE_RUBY_LINTER="standardrb"
elif ruby_gemfile_has '\brubocop\b'; then
	PROFILE_RUBY_LINTER="rubocop"
fi

# Test framework: RSpec when a spec/ dir or the rspec gem is present, else
# Minitest (the standard-library default).
PROFILE_RUBY_TEST="minitest"
if [ -d "$PWD/spec" ] || ruby_gemfile_has '\brspec\b'; then
	PROFILE_RUBY_TEST="rspec"
fi

# Optional static typing: only when Sorbet or Steep is explicitly configured.
PROFILE_RUBY_TYPECHECK=""
if [ -f "$PWD/sorbet/config" ] || ruby_gemfile_has '\bsorbet\b'; then
	PROFILE_RUBY_TYPECHECK="sorbet"
elif [ -f "$PWD/Steepfile" ] || ruby_gemfile_has '\bsteep\b'; then
	PROFILE_RUBY_TYPECHECK="steep"
fi

PROFILE_SURFACE_LABEL="Ruby surface detected (Gemfile, ${PROFILE_RUBY_LINTER}/${PROFILE_RUBY_TEST})"

# --- Dependency sync (declared-but-unused) -----------------------------------
# init.sh is a sensor, not an installer: it does not run `bundle install`
# (a heavy side effect) on every preflight. These strings declare the sync
# contract for tooling that opts in.
PROFILE_SYNC_OK="bundle install satisfied"
PROFILE_SYNC_FAIL="bundle install failed"
PROFILE_SYNC_FIX="inspect: bundle install"
PROFILE_SYNC_SKIP_MSG="no Gemfile yet — skipping ruby checks"

profile_sync() { bundle install; }

# --- Quality gates -----------------------------------------------------------
# Standard Ruby is a COMBINED lint+format path, so it occupies the single `lint`
# slot (no separate format_check). RuboCop likewise runs as the `lint` slot. A
# `typecheck` slot is appended only when Sorbet/Steep is configured.
if [ -n "$PROFILE_RUBY_TYPECHECK" ]; then
	PROFILE_GATES=(lint typecheck test)
else
	PROFILE_GATES=(lint test)
fi

# ruby_have: the Ruby toolchain (ruby + bundler) needed to run any gate.
ruby_have() { command -v ruby >/dev/null 2>&1 && command -v bundle >/dev/null 2>&1; }

profile_gate_lint() {
	ruby_have || return 2
	if [ "$PROFILE_RUBY_LINTER" = "rubocop" ]; then
		bundle exec rubocop
	else
		bundle exec standardrb
	fi
}
if [ "$PROFILE_RUBY_LINTER" = "rubocop" ]; then
	PROFILE_GATE_lint_OK="rubocop clean"
	PROFILE_GATE_lint_FAIL="rubocop reported offenses"
	PROFILE_GATE_lint_FIX="bundle exec rubocop -a"
else
	PROFILE_GATE_lint_OK="standardrb clean (lint+format)"
	PROFILE_GATE_lint_FAIL="standardrb reported issues"
	PROFILE_GATE_lint_FIX="bundle exec standardrb --fix"
fi
PROFILE_GATE_lint_SKIP="ruby lint skipped (ruby/bundler not installed)"

profile_gate_typecheck() {
	ruby_have || return 2
	if [ "$PROFILE_RUBY_TYPECHECK" = "steep" ]; then
		bundle exec steep check
	else
		bundle exec srb tc
	fi
}
if [ "$PROFILE_RUBY_TYPECHECK" = "steep" ]; then
	PROFILE_GATE_typecheck_OK="steep check clean"
	PROFILE_GATE_typecheck_FAIL="steep check failed"
	PROFILE_GATE_typecheck_FIX="bundle exec steep check"
else
	PROFILE_GATE_typecheck_OK="sorbet typecheck clean"
	PROFILE_GATE_typecheck_FAIL="sorbet typecheck failed"
	PROFILE_GATE_typecheck_FIX="bundle exec srb tc"
fi
PROFILE_GATE_typecheck_SKIP="ruby typecheck skipped (ruby/bundler not installed)"

profile_gate_test() {
	ruby_have || return 2
	if [ "$PROFILE_RUBY_TEST" = "rspec" ]; then
		bundle exec rspec
	else
		bundle exec rake test
	fi
}
if [ "$PROFILE_RUBY_TEST" = "rspec" ]; then
	PROFILE_GATE_test_OK="rspec passing"
	PROFILE_GATE_test_FAIL="rspec failed"
	PROFILE_GATE_test_FIX="bundle exec rspec"
else
	PROFILE_GATE_test_OK="minitest passing"
	PROFILE_GATE_test_FAIL="minitest failed"
	PROFILE_GATE_test_FIX="bundle exec rake test"
fi
PROFILE_GATE_test_SKIP="ruby tests skipped (ruby/bundler not installed)"
