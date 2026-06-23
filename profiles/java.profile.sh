# Java language profile descriptor — issue #41.
#
# Bash-sourced profile descriptor. scripts/init.sh sources this file and drives
# the Java surface label and quality gates from the values and functions declared
# here. Java carries a load-bearing build-tool variant axis (Maven vs Gradle) and
# prefers the project wrappers ./mvnw / ./gradlew over a system mvn / gradle when
# present. There is NO separate typecheck slot — compilation via the test task
# covers type checking (empty-slot rule). Spotless (format) and Checkstyle / PMD /
# SpotBugs (lint) are OPTIONAL gates that SKIP (return 2 → warn) when not
# configured or when the build tool is unavailable. See profiles/README.md for the
# descriptor contract.
#
# shellcheck shell=bash
# These PROFILE_* variables are consumed by scripts/init.sh after sourcing, not
# within this file, so shellcheck cannot see their use.
# shellcheck disable=SC2034

# --- Metadata (Profile Interface fields) -------------------------------------
PROFILE_ID="java"
PROFILE_DETECT="pom.xml | build.gradle | build.gradle.kts"
PROFILE_VARIANTS="maven gradle"
PROFILE_TOOL_REQUIREMENTS="java"
PROFILE_INSTRUCTIONS=".copilot/instructions/java.instructions.md"
PROFILE_FRAMEWORKS="Spring Boot, Quarkus"

# --- Helpers -----------------------------------------------------------------
# java_build_file_has <pattern>: succeeds when any present build file (pom.xml,
# build.gradle, build.gradle.kts) mentions <pattern>. Used for variant and
# optional-gate detection without parsing XML / Groovy / Kotlin.
java_build_file_has() {
	local f
	for f in pom.xml build.gradle build.gradle.kts; do
		[ -f "$PWD/$f" ] && grep -Eqi "$1" "$PWD/$f" 2>/dev/null && return 0
	done
	return 1
}

# --- Detection ---------------------------------------------------------------
profile_detect() {
	[ -f "$PWD/pom.xml" ] || [ -f "$PWD/build.gradle" ] || [ -f "$PWD/build.gradle.kts" ]
}

# --- Variant detection (load-bearing) ----------------------------------------
# Build tool: Maven (pom.xml) wins when present; otherwise Gradle (build.gradle
# or its Kotlin DSL). Record which build file drove detection for the label.
if [ -f "$PWD/pom.xml" ]; then
	PROFILE_JAVA_BUILD="maven"
	PROFILE_JAVA_BUILD_FILE="pom.xml"
elif [ -f "$PWD/build.gradle.kts" ]; then
	PROFILE_JAVA_BUILD="gradle"
	PROFILE_JAVA_BUILD_FILE="build.gradle.kts"
else
	PROFILE_JAVA_BUILD="gradle"
	PROFILE_JAVA_BUILD_FILE="build.gradle"
fi

# Runner: prefer the project wrapper (./mvnw / ./gradlew) over a system install.
if [ "$PROFILE_JAVA_BUILD" = "maven" ]; then
	if [ -x "$PWD/mvnw" ]; then PROFILE_JAVA_CMD="./mvnw"; else PROFILE_JAVA_CMD="mvn"; fi
else
	if [ -x "$PWD/gradlew" ]; then PROFILE_JAVA_CMD="./gradlew"; else PROFILE_JAVA_CMD="gradle"; fi
fi

# Optional formatter: Spotless, only when configured in a build file.
PROFILE_JAVA_SPOTLESS=""
if java_build_file_has 'spotless'; then PROFILE_JAVA_SPOTLESS="spotless"; fi

# Optional linter: Checkstyle / PMD / SpotBugs, only when configured. Priority
# checkstyle > pmd > spotbugs when several are present.
PROFILE_JAVA_LINT=""
if java_build_file_has 'checkstyle'; then
	PROFILE_JAVA_LINT="checkstyle"
elif java_build_file_has 'pmd'; then
	PROFILE_JAVA_LINT="pmd"
elif java_build_file_has 'spotbugs'; then
	PROFILE_JAVA_LINT="spotbugs"
fi

PROFILE_SURFACE_LABEL="Java surface detected (${PROFILE_JAVA_BUILD_FILE}, ${PROFILE_JAVA_BUILD})"

# --- Dependency sync (declared-but-unused) -----------------------------------
# init.sh is a sensor, not an installer: it does not resolve dependencies (a heavy
# network side effect) on every preflight. These strings declare the sync contract
# for tooling that opts in.
PROFILE_SYNC_OK="java dependencies resolved"
PROFILE_SYNC_FAIL="dependency resolution failed"
if [ "$PROFILE_JAVA_BUILD" = "maven" ]; then
	PROFILE_SYNC_FIX="inspect: ${PROFILE_JAVA_CMD} -q dependency:go-offline"
else
	PROFILE_SYNC_FIX="inspect: ${PROFILE_JAVA_CMD} dependencies"
fi
PROFILE_SYNC_SKIP_MSG="no Java build file yet — skipping java checks"

profile_sync() {
	if [ "$PROFILE_JAVA_BUILD" = "maven" ]; then
		"$PROFILE_JAVA_CMD" -q dependency:go-offline
	else
		"$PROFILE_JAVA_CMD" dependencies
	fi
}

# --- Quality gates -----------------------------------------------------------
# No typecheck slot: the test task compiles the sources, which exercises the
# type checker. Spotless (format_check) and Checkstyle/PMD/SpotBugs (lint) are
# optional and SKIP when not configured. test is the always-on gate.
PROFILE_GATES=(format_check lint test)

# java_have: the configured build runner is invocable (system tool or wrapper).
java_have() {
	case "$PROFILE_JAVA_BUILD" in
	maven) [ -x "$PWD/mvnw" ] || command -v mvn >/dev/null 2>&1 ;;
	gradle) [ -x "$PWD/gradlew" ] || command -v gradle >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# format_check runs Spotless in CHECK mode (never applies) when configured.
profile_gate_format_check() {
	[ -n "$PROFILE_JAVA_SPOTLESS" ] || return 2
	java_have || return 2
	if [ "$PROFILE_JAVA_BUILD" = "maven" ]; then
		"$PROFILE_JAVA_CMD" -q spotless:check
	else
		"$PROFILE_JAVA_CMD" spotlessCheck
	fi
}
PROFILE_GATE_format_check_OK="spotless check clean"
PROFILE_GATE_format_check_FAIL="spotless check failed"
if [ "$PROFILE_JAVA_BUILD" = "maven" ]; then
	PROFILE_GATE_format_check_FIX="${PROFILE_JAVA_CMD} spotless:apply"
else
	PROFILE_GATE_format_check_FIX="${PROFILE_JAVA_CMD} spotlessApply"
fi
PROFILE_GATE_format_check_SKIP="spotless skipped (not configured or build tool unavailable)"

# lint runs the configured Checkstyle / PMD / SpotBugs goal when present.
profile_gate_lint() {
	[ -n "$PROFILE_JAVA_LINT" ] || return 2
	java_have || return 2
	if [ "$PROFILE_JAVA_BUILD" = "maven" ]; then
		"$PROFILE_JAVA_CMD" -q "${PROFILE_JAVA_LINT}:check"
	else
		case "$PROFILE_JAVA_LINT" in
		checkstyle) "$PROFILE_JAVA_CMD" checkstyleMain ;;
		pmd) "$PROFILE_JAVA_CMD" pmdMain ;;
		spotbugs) "$PROFILE_JAVA_CMD" spotbugsMain ;;
		esac
	fi
}
PROFILE_GATE_lint_OK="java lint clean"
PROFILE_GATE_lint_FAIL="java lint reported issues"
PROFILE_GATE_lint_FIX="inspect the configured Checkstyle/PMD/SpotBugs report"
PROFILE_GATE_lint_SKIP="java lint skipped (no Checkstyle/PMD/SpotBugs configured or build tool unavailable)"

# test compiles and runs the test task; this also covers type checking.
profile_gate_test() {
	java_have || return 2
	if [ "$PROFILE_JAVA_BUILD" = "maven" ]; then
		"$PROFILE_JAVA_CMD" -q test
	else
		"$PROFILE_JAVA_CMD" test
	fi
}
PROFILE_GATE_test_OK="java tests passing"
PROFILE_GATE_test_FAIL="java tests failed"
PROFILE_GATE_test_FIX="${PROFILE_JAVA_CMD} test"
PROFILE_GATE_test_SKIP="java tests skipped (build tool unavailable)"
