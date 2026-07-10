#!/usr/bin/env bash
# Regression sensor (issue #274, feature docs-shipped-vs-generator): the docs
# must state the SHIPPED profile set (Python, Node) versus the
# GENERATOR-SUPPORTED set (Go, Java, Ruby), and must not keep the stale
# "initial supported set is five languages" claim now that go/java/ruby ship
# only via scaffold-language.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

docs="README.md docs/HARNESS.md docs/multi-language-profiles.md profiles/README.md docs/getting-started.md"

# --- 1. No stale five-language / all-five-shipped claim survives. -------------
# Case-insensitive scan for the retired framings across the target docs.
for d in $docs AGENTS.md; do
  [ -f "$d" ] || { note "missing $d"; continue; }
  grep -Eqi 'five (built-?in|language|supported)' "$d" \
    && note "$d still claims a 'five languages/profiles' set (retired by #274)"
  grep -Eqi 'initial supported (language )?set is .*(five|python, go)' "$d" \
    && note "$d still claims the initial supported set is five languages"
  # "ships profiles for Python, Go, Node.js, Java, and Ruby" — all-five-shipped.
  grep -Eqi 'ships? (the )?profiles? for .*python, *go' "$d" \
    && note "$d still claims all five profiles ship (Go/Java/Ruby are now generator-supported)"
done

# --- 2. The shipped vs generator-supported distinction is stated. ------------
# At least the two hub docs must name both sets explicitly.
for d in README.md docs/HARNESS.md docs/multi-language-profiles.md docs/getting-started.md; do
  [ -f "$d" ] || continue
  grep -Eqi 'generator-supported|generator-generated|scaffold(ed)?[ -]on[ -]demand|generated on demand' "$d" \
    || note "$d must frame Go/Java/Ruby as generator-supported (scaffolded on demand)"
done

# --- 3. Python + Node are named as the shipped set somewhere in the hubs. -----
for d in README.md docs/getting-started.md; do
  [ -f "$d" ] || continue
  grep -Eqi 'python[^.]*(and )?node|node[^.]*(and )?python' "$d" \
    || note "$d must name Python and Node as the shipped profile set"
done

# --- 4. profiles/README.md must not present Go/Java/Ruby as SHIPPED descriptors.
# The demoted languages (issue #274) no longer ship a *.profile.sh; each profile
# section here must be explicitly marked generator-supported (issue #285 item 2),
# so a reader can't mistake the reference design for a shipped file.
readme="profiles/README.md"
if [ -f "$readme" ]; then
  grep -Eqi 'generator-supported' "$readme" \
    || note "$readme must frame Go/Java/Ruby as generator-supported"
  for lang in Go Ruby Java; do
    # A profile section for a demoted language must carry the generator-supported
    # marker on (or immediately under) its heading.
    if grep -Eq "^## The ${lang} profile" "$readme"; then
      awk -v lang="$lang" '
        $0 ~ "^## The " lang " profile" { inband=1; hit=0; next }
        /^## / && inband { inband=0 }
        inband && tolower($0) ~ /generator-supported/ { hit=1 }
        END { exit (hit ? 0 : 1) }
      ' "$readme" \
        || note "$readme '## The ${lang} profile' section must be marked generator-supported (not a shipped descriptor)"
    fi
  done
fi

if [ "$fail" -ne 0 ]; then
  echo "docs shipped-vs-generator sensor FAILED"
  exit 1
fi
echo "docs shipped-vs-generator sensor passed"
