#!/usr/bin/env bash
# audit-sweep.sh — run the six repo audit skills locally in one invocation.
#
# Each audit skill runs in its OWN fresh headless `copilot -p` session (a single
# meta-skill that ran all six in one context was rejected in issue #258: six
# whole-repo audits exhaust one window and later skills run degraded). Every
# session is report-only — read + read-only git, never write — and its Markdown
# report lands under logs/audit/<UTC-timestamp>/<skill>.md. A final consolidation
# pass rolls the per-skill Findings tables into one index.md.
#
# This is the deterministic driver the (blocked, #256) scheduled-CI audit will
# reuse as its entry point: checkout + install CLI + ./scripts/audit-sweep.sh.
#
# Usage:
#   ./scripts/audit-sweep.sh                       # run all six audit skills
#   ./scripts/audit-sweep.sh find-duplicates security-audit   # run a subset
#   ./scripts/audit-sweep.sh --dry-run             # print the per-skill commands
#   ./scripts/audit-sweep.sh --consolidate <dir>   # rebuild index.md from <dir>/*.md
#
# The audit skill set is DERIVED from .copilot/skills/ (every skill dir minus the
# three non-audit skills below), so adding an audit skill needs no edit here.
#
# Exit codes: 0 all selected skills succeeded · 1 one or more skills failed
# (fail-soft: the sweep still runs every skill and consolidates) · 2 usage error
# (unknown skill / bad flag / missing --consolidate dir).

set -euo pipefail

# Non-audit skills that live under .copilot/skills/ but are not part of the sweep.
NON_AUDIT=("code-review" "create-pr" "public-exposure-audit")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${ROOT}/.copilot/skills"
CONVENTIONS=".copilot/skills/_audit-conventions.md"
LOG_ROOT="${AUDIT_LOG_ROOT:-${ROOT}/logs/audit}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()   { printf 'audit-sweep: error: %s\n' "$*" >&2; exit "${2:-2}"; }

# --- Derive the audit skill set from the skill directory ---------------------
discover_audit_skills() {
  [ -d "${SKILLS_DIR}" ] || die "skills dir not found: ${SKILLS_DIR}"
  local d name skip n
  for d in "${SKILLS_DIR}"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    skip=0
    for n in "${NON_AUDIT[@]}"; do
      [ "$name" = "$n" ] && skip=1 && break
    done
    [ "$skip" -eq 0 ] && printf '%s\n' "$name"
  done | sort
}

# --- Per-skill headless command (array) --------------------------------------
# Report-only tool policy: read + read-only git only, no write, no ask_user,
# silent so stdout is just the report body.
skill_prompt() {
  local skill="$1"
  # SC2016: the backticks are literal Markdown code spans in the prompt text,
  # not command substitutions — expansion is deliberately not wanted here.
  # shellcheck disable=SC2016
  printf 'Run the `%s` audit skill over this repository. Follow its SKILL.md and the shared report conventions in `%s` (exclusions, "search broadly, judge narrowly", severity + Fix-now/Plan-first/Defer-accept grading, and the Findings-table-first report shape). This is a REPORT-ONLY audit: do not modify any file. Emit the report as Markdown to stdout.' \
    "${skill}" "${CONVENTIONS}"
}

skill_command() {
  # Prints the command as a single shell-quoted line (for --dry-run and logs).
  local skill="$1" outfile="$2"
  printf "copilot -p %q --allow-tool 'read' --allow-tool 'shell(git:*)' --deny-tool write --no-ask-user -s > %q" \
    "$(skill_prompt "${skill}")" "${outfile}"
}

run_skill() {
  local skill="$1" outfile="$2"
  # Run from the repo root so each audit sees the whole repo regardless of the
  # caller's CWD (defensive for the future #256 CI entry point). The subshell
  # keeps the loop's CWD untouched; outfile is an absolute path under LOG_ROOT.
  ( cd "${ROOT}" && copilot -p "$(skill_prompt "${skill}")" \
    --allow-tool 'read' \
    --allow-tool 'shell(git:*)' \
    --deny-tool write \
    --no-ask-user \
    -s ) > "${outfile}"
}

# --- Consolidation: per-skill reports -> index.md roll-up --------------------
# Roll-up table is keyed (skill, severity, priority, file); the per-skill report
# Findings table is `| Severity | Priority | File | ... |`, so we prefix a Skill
# column and re-emit each data row, then append every report verbatim.
consolidate() {
  local dir="$1"
  [ -d "$dir" ] || die "--consolidate: dir not found: ${dir}"
  local index="${dir}/index.md"
  local ts
  ts="$(basename "${dir}")"

  {
    printf '# Audit Sweep — %s\n\n' "${ts}"
    printf '## Findings\n\n'
    printf '| Skill | Severity | Priority | File | Finding |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    local f skill
    for f in "${dir}"/*.md; do
      [ -e "$f" ] || continue
      skill="$(basename "${f}" .md)"
      [ "${skill}" = "index" ] && continue
      # Extract Findings-table data rows: enter on the `| Severity …` header,
      # skip the separator, prefix each data row with the skill, leave on the
      # first non-`|` line.
      awk -v skill="${skill}" '
        /^\|[[:space:]]*[Ss]everity/ { inf = 1; next }
        inf && /^\|[[:space:]]*-/     { next }
        inf && /^\|/                  { print "| " skill " " $0; next }
        inf                            { inf = 0 }
      ' "${f}"
    done
    printf '\n'
    # Per-skill sections, verbatim.
    for f in "${dir}"/*.md; do
      [ -e "$f" ] || continue
      skill="$(basename "${f}" .md)"
      [ "${skill}" = "index" ] && continue
      printf -- '---\n\n## %s\n\n' "${skill}"
      cat "${f}"
      printf '\n'
    done
  } > "${index}"

  green "✓ consolidated ${index}"
}

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local dry_run=0
  local -a requested=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --consolidate)
        [ "$#" -ge 2 ] || die "--consolidate requires a directory argument"
        consolidate "$2"
        return 0 ;;
      -h|--help) usage; return 0 ;;
      --*) die "unknown flag: $1" ;;
      *) requested+=("$1"); shift ;;
    esac
  done

  mapfile -t ALL < <(discover_audit_skills)
  [ "${#ALL[@]}" -gt 0 ] || die "no audit skills discovered under ${SKILLS_DIR}" 1

  # Resolve the selection: no args = all; else validate each requested skill.
  local -a selected=()
  if [ "${#requested[@]}" -eq 0 ]; then
    selected=("${ALL[@]}")
  else
    local want found a
    for want in "${requested[@]}"; do
      found=0
      for a in "${ALL[@]}"; do
        [ "$a" = "$want" ] && found=1 && break
      done
      [ "$found" -eq 1 ] || die "unknown skill: '${want}' (not an audit skill under ${SKILLS_DIR})"
      selected+=("$want")
    done
  fi

  local ts outdir skill outfile rc=0
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  outdir="${LOG_ROOT}/${ts}"

  if [ "${dry_run}" -eq 1 ]; then
    bold "audit-sweep (dry-run): ${#selected[@]} skill(s) -> ${outdir}"
    printf '# create the output dir first: mkdir -p %q\n' "${outdir}"
    for skill in "${selected[@]}"; do
      outfile="${outdir}/${skill}.md"
      printf '%s\n' "$(skill_command "${skill}" "${outfile}")"
    done
    printf '# then: %s --consolidate %q\n' "${BASH_SOURCE[0]}" "${outdir}"
    return 0
  fi

  mkdir -p "${outdir}"
  bold "audit-sweep: ${#selected[@]} skill(s) -> ${outdir}"
  for skill in "${selected[@]}"; do
    outfile="${outdir}/${skill}.md"
    printf '==> %s\n' "${skill}"
    # Fail-soft: a failing skill is recorded but does not abort the sweep.
    if run_skill "${skill}" "${outfile}"; then
      green "✓ ${skill}"
    else
      rc=1
      red "✗ ${skill} (see ${outfile})"
      # shellcheck disable=SC2016
      printf '\n> audit-sweep: `%s` FAILED to complete.\n' "${skill}" >> "${outfile}"
    fi
  done

  consolidate "${outdir}"

  if [ "${rc}" -ne 0 ]; then
    red "audit-sweep: one or more skills failed — see ${outdir}/index.md"
  else
    green "audit-sweep: all ${#selected[@]} skill(s) completed — ${outdir}/index.md"
  fi
  return "${rc}"
}

main "$@"
