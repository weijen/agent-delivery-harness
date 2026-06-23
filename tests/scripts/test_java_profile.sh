#!/usr/bin/env bash
# Regression sensor (issue #41): the Java profile descriptor must declare every
# Profile Interface field, detect a pom.xml / build.gradle / build.gradle.kts
# surface, resolve the build-tool variant (Maven vs Gradle), prefer the project
# wrappers ./mvnw / ./gradlew over a system tool, expose the gate functions
# init.sh drives, SKIP (return 2) the optional Spotless/lint gates when they are
# not configured, and SKIP every gate when the build tool is unavailable instead
# of hard-failing. Compile/test is the default type-check path (no typecheck slot).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

desc="profiles/java.profile.sh"

if [ ! -f "$desc" ]; then
  note "missing $desc"
  echo "java profile sensor FAILED"
  exit 1
fi

bash -n "$desc" || note "$desc is not valid bash"

probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<PROBE
set -euo pipefail

# --- Fixture A: Maven (pom.xml) + Spotless + Checkstyle + ./mvnw wrapper ------
a="\$(mktemp -d)"
cd "\$a"
printf '<project><build><plugins>spotless checkstyle</plugins></build></project>\n' > pom.xml
printf '#!/bin/sh\nexit 0\n' > mvnw; chmod +x mvnw
# shellcheck source=/dev/null
. "$ROOT/$desc"

[ "\${PROFILE_ID:-}" = "java" ] || { echo "BAD PROFILE_ID=\${PROFILE_ID:-}"; exit 11; }
case "\${PROFILE_DETECT:-}" in *pom.xml*) : ;; *) echo "BAD PROFILE_DETECT"; exit 12 ;; esac
[ "\${PROFILE_TOOL_REQUIREMENTS:-}" = "java" ] || { echo "BAD TOOLREQ"; exit 13; }
[ -n "\${PROFILE_INSTRUCTIONS:-}" ] || { echo "EMPTY INSTRUCTIONS"; exit 14; }
for fw in "Spring Boot" Quarkus; do
  case "\${PROFILE_FRAMEWORKS:-}" in *"\$fw"*) : ;; *) echo "MISSING FRAMEWORK \$fw"; exit 15 ;; esac
done

[ "\${PROFILE_JAVA_BUILD:-}" = "maven" ] || { echo "BAD BUILD=\${PROFILE_JAVA_BUILD:-} (want maven)"; exit 16; }
[ "\${PROFILE_JAVA_CMD:-}" = "./mvnw" ] || { echo "BAD CMD=\${PROFILE_JAVA_CMD:-} (want ./mvnw wrapper)"; exit 17; }
[ "\${PROFILE_JAVA_SPOTLESS:-}" = "spotless" ] || { echo "BAD SPOTLESS=\${PROFILE_JAVA_SPOTLESS:-}"; exit 18; }
[ "\${PROFILE_JAVA_LINT:-}" = "checkstyle" ] || { echo "BAD LINT=\${PROFILE_JAVA_LINT:-} (want checkstyle)"; exit 19; }
[ "\${PROFILE_SURFACE_LABEL:-}" = "Java surface detected (pom.xml, maven)" ] || { echo "BAD LABEL=\${PROFILE_SURFACE_LABEL:-}"; exit 20; }
# No typecheck slot: compile/test covers it.
[ "\${PROFILE_GATES[*]:-}" = "format_check lint test" ] || { echo "BAD GATES=\${PROFILE_GATES[*]:-}"; exit 21; }
case " \${PROFILE_GATES[*]:-} " in *" typecheck "*) echo "java must have no typecheck slot"; exit 22 ;; esac

declare -F profile_detect >/dev/null || { echo "NO profile_detect"; exit 23; }
profile_detect || { echo "detect false with pom.xml"; exit 24; }
declare -F profile_sync >/dev/null || { echo "NO profile_sync"; exit 25; }
for g in "\${PROFILE_GATES[@]}"; do
  declare -F "profile_gate_\${g}" >/dev/null || { echo "NO profile_gate_\${g}"; exit 26; }
  for suffix in OK FAIL FIX SKIP; do
    v="PROFILE_GATE_\${g}_\${suffix}"
    [ -n "\${!v:-}" ] || { echo "EMPTY \$v"; exit 27; }
  done
done

# With Spotless+Checkstyle configured but NO mvn/mvnw invocable (strip PATH and
# remove the wrapper), every gate SKIPs (rc=2) rather than hard-failing.
rm -f mvnw
fakebin="\$(mktemp -d)"  # empty: no mvn
for g in format_check lint test; do
  rc=0; PATH="\$fakebin" "profile_gate_\${g}" || rc=\$?
  [ "\$rc" = "2" ] || { echo "\$g did not SKIP without build tool (rc=\$rc)"; exit 28; }
done
rm -rf "\$fakebin"

empty="\$(mktemp -d)"; ( cd "\$empty" && ! profile_detect ) || { echo "detect true in empty dir"; exit 29; }
rm -rf "\$empty"
cd /; rm -rf "\$a"

# --- Fixture B: Gradle (build.gradle), no wrapper, no Spotless/lint ----------
b="\$(mktemp -d)"
cd "\$b"
printf 'plugins { id "java" }\n' > build.gradle
# shellcheck source=/dev/null
. "$ROOT/$desc"

[ "\${PROFILE_JAVA_BUILD:-}" = "gradle" ] || { echo "BAD BUILD=\${PROFILE_JAVA_BUILD:-} (want gradle)"; exit 30; }
[ "\${PROFILE_JAVA_CMD:-}" = "gradle" ] || { echo "BAD CMD=\${PROFILE_JAVA_CMD:-} (want system gradle)"; exit 31; }
[ "\${PROFILE_SURFACE_LABEL:-}" = "Java surface detected (build.gradle, gradle)" ] || { echo "BAD LABEL=\${PROFILE_SURFACE_LABEL:-}"; exit 32; }
[ -z "\${PROFILE_JAVA_SPOTLESS:-}" ] || { echo "spotless must be unset without config"; exit 33; }
[ -z "\${PROFILE_JAVA_LINT:-}" ] || { echo "lint must be unset without config"; exit 34; }
# Optional gates SKIP when not configured, even if a (fake) gradle is present.
fakebin="\$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "\$fakebin/gradle"; chmod +x "\$fakebin/gradle"
rc=0; PATH="\$fakebin:/usr/bin:/bin" profile_gate_format_check || rc=\$?
[ "\$rc" = "2" ] || { echo "format_check must SKIP when Spotless unconfigured (rc=\$rc)"; exit 35; }
rc=0; PATH="\$fakebin:/usr/bin:/bin" profile_gate_lint || rc=\$?
[ "\$rc" = "2" ] || { echo "lint must SKIP when no linter configured (rc=\$rc)"; exit 36; }
# test runs through the fake gradle and passes.
PATH="\$fakebin:/usr/bin:/bin" profile_gate_test || { echo "test must pass with fake gradle"; exit 37; }
rm -rf "\$fakebin"
cd /; rm -rf "\$b"

# --- Fixture C: build.gradle.kts is detected as a Gradle surface -------------
c="\$(mktemp -d)"
cd "\$c"
printf 'plugins { java }\n' > build.gradle.kts
# shellcheck source=/dev/null
. "$ROOT/$desc"
profile_detect || { echo "detect false with build.gradle.kts"; exit 40; }
[ "\${PROFILE_JAVA_BUILD:-}" = "gradle" ] || { echo "BAD KTS BUILD"; exit 41; }
[ "\${PROFILE_JAVA_BUILD_FILE:-}" = "build.gradle.kts" ] || { echo "BAD KTS FILE=\${PROFILE_JAVA_BUILD_FILE:-}"; exit 42; }
cd /; rm -rf "\$c"

# --- Fixture D: pom.xml AND build.gradle present -> Maven wins ---------------
d="\$(mktemp -d)"
cd "\$d"
printf '<project></project>\n' > pom.xml
printf 'plugins { id "java" }\n' > build.gradle
# shellcheck source=/dev/null
. "$ROOT/$desc"
[ "\${PROFILE_JAVA_BUILD:-}" = "maven" ] || { echo "BAD BUILD=\${PROFILE_JAVA_BUILD:-} (Maven must win when both present)"; exit 43; }
[ "\${PROFILE_JAVA_BUILD_FILE:-}" = "pom.xml" ] || { echo "BAD FILE=\${PROFILE_JAVA_BUILD_FILE:-}"; exit 44; }
cd /; rm -rf "\$d"

# --- Fixture E: Gradle wrapper preferred over system gradle ------------------
e="\$(mktemp -d)"
cd "\$e"
printf 'plugins { id "java" }\n' > build.gradle
printf '#!/bin/sh\nexit 0\n' > gradlew; chmod +x gradlew
# shellcheck source=/dev/null
. "$ROOT/$desc"
[ "\${PROFILE_JAVA_CMD:-}" = "./gradlew" ] || { echo "BAD CMD=\${PROFILE_JAVA_CMD:-} (want ./gradlew wrapper)"; exit 45; }
cd /; rm -rf "\$e"

echo "PROBE-OK"
PROBE

if ! out="$(bash "$probe" 2>&1)"; then
  note "java descriptor probe failed: $out"
elif [ "$out" != "PROBE-OK" ]; then
  note "java descriptor probe unexpected output: $out"
fi

# Lint the descriptor when shellcheck is available (CI also lints it).
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$desc" || note "$desc failed shellcheck"
fi

if [ "$fail" -ne 0 ]; then
  echo "java profile sensor FAILED"
  exit 1
fi
echo "java profile descriptor checks passed"
