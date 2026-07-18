#!/usr/bin/env bash
set -euo pipefail

reject_usage() {
  printf 'error: unsupported customization path: %s\n' "$1" >&2
  exit 2
}

validate_file() {
  local file="$1"
  local kind expected_name reason

  if [ ! -f "$file" ]; then
    printf 'error: customization file not found: %s\n' "$file" >&2
    exit 2
  fi

  case "$file" in
    */skills/*/SKILL.md)
      kind="skill"
      expected_name="$(basename "$(dirname "$file")")"
      ;;
    *.agent.md)
      kind="agent"
      expected_name=""
      ;;
    *) reject_usage "$file" ;;
  esac

  reason="$(awk -v kind="$kind" -v expected_name="$expected_name" -v tab="$(printf '\t')" '
    function strip_inline_comment(value, i, character, next_character, in_single, in_double, escaped) {
      for (i = 1; i <= length(value); i++) {
        character = substr(value, i, 1)
        next_character = substr(value, i + 1, 1)
        if (in_double) {
          if (escaped) {
            escaped = 0
          } else if (character == "\\") {
            escaped = 1
          } else if (character == "\"") {
            in_double = 0
          }
          continue
        }
        if (in_single) {
          if (character == "\047" && next_character == "\047") {
            i++
          } else if (character == "\047") {
            in_single = 0
          }
          continue
        }
        if (character == "\"") {
          in_double = 1
        } else if (character == "\047") {
          in_single = 1
        } else if (character == "#" && (i == 1 || substr(value, i - 1, 1) ~ /[[:space:]]/)) {
          return substr(value, 1, i - 1)
        }
      }
      return value
    }
    function scalar_value(line, key, value, first, last) {
      value = line
      sub("^" key ":[[:space:]]*", "", value)
      value = strip_inline_comment(value)
      sub(/[[:space:]]+$/, "", value)
      if (length(value) >= 2) {
        first = substr(value, 1, 1)
        last = substr(value, length(value), 1)
        if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
          value = substr(value, 2, length(value) - 2)
        }
      }
      return value
    }
    function is_block_scalar(line, key, value) {
      value = line
      sub("^" key ":[[:space:]]*", "", value)
      value = strip_inline_comment(value)
      sub(/[[:space:]]+$/, "", value)
      return value ~ /^[|>]([+-][1-9]?|[1-9][+-]?)?$/
    }
    NR == 1 {
      saw_first = 1
      if ($0 != "---") {
        missing_frontmatter = 1
      }
      next
    }
    !closed {
      if ($0 == "---") {
        closed = 1
        next
      }
      if ($0 ~ ("^[ ]*" tab)) {
        tab_indentation = 1
      }
      if ($0 ~ /^name:[[:space:]]*/) {
        name = scalar_value($0, "name")
      }
      if ($0 ~ /^description:[[:space:]]*/) {
        if (is_block_scalar($0, "description")) {
          description = ""
        } else {
          description = scalar_value($0, "description")
        }
      }
    }
    END {
      if (!saw_first || missing_frontmatter) {
        print "missing_frontmatter"
        exit
      }
      if (!closed) {
        print "unterminated_frontmatter"
        exit
      }
      if (tab_indentation) {
        print "tab_indentation"
        exit
      }
      if (kind == "skill") {
        if (name == "") {
          print "missing_name"
          exit
        }
        if (index(name, "/") > 0) {
          print "namespace_prefix"
          exit
        }
        if (length(name) > 64 || name !~ /^[a-z0-9][a-z0-9-]*$/) {
          print "invalid_name"
          exit
        }
        if (name != expected_name) {
          print "name_mismatch"
          exit
        }
      }
      if (description == "") {
        print "missing_description"
        exit
      }
      if (length(description) > 1024) {
        print "description_too_long"
        exit
      }
    }
  ' "$file")"

  if [ -n "$reason" ]; then
    printf 'invalid_frontmatter: %s: %s\n' "$reason" "$file" >&2
    return 1
  fi

  printf 'valid_frontmatter: %s\n' "$file"
}

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  shopt -s nullglob
  files=("${ROOT}"/.copilot/agents/*.agent.md "${ROOT}"/.copilot/skills/*/SKILL.md)
fi

for file in "${files[@]}"; do
  validate_file "$file"
done