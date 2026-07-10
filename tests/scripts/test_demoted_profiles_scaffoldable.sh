#!/usr/bin/env bash
# Regression sensor (issue #274, feature remove-demoted-profiles): go/java/ruby
# are demoted from shipped profiles to generator-supported. The shipped repo must
# NOT carry their descriptors, and scaffold-language.sh must remain the single,
# tested way to (re)create a working profile on demand.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "${TMP_DIR}"; rm -f "${OUT}"' EXIT

fail=0
note() { echo "✗ $*"; fail=1; }

# --- 1. The demoted descriptors must be gone from the shipped repo. -----------
for lang in go java ruby; do
  [ -e "${ROOT}/profiles/${lang}.profile.sh" ] \
    && note "profiles/${lang}.profile.sh must be deleted (demoted to generator-supported)"
done

# --- 2. The shipped set stays. ------------------------------------------------
for lang in python node; do
  [ -f "${ROOT}/profiles/${lang}.profile.sh" ] \
    || note "profiles/${lang}.profile.sh (shipped) must remain"
done

# --- 3. scaffold-language.sh regenerates each demoted profile on demand. ------
# Seed a hermetic repo copy (which no longer carries go/java/ruby) and prove the
# generator recreates a working Profile Interface for each.
seed_repo() {
  local d="$1"
  mkdir -p "$d"
  cp -R "${ROOT}/scripts" "$d/scripts"
  cp -R "${ROOT}/profiles" "$d/profiles"
  cp -R "${ROOT}/.copilot" "$d/.copilot"
}

for lang in go java ruby; do
  d="${TMP_DIR}/${lang}"
  seed_repo "$d"
  if ! ( cd "$d" && ./scripts/scaffold-language.sh "$lang" --write >"$OUT" 2>&1 ); then
    cat "$OUT"; note "scaffold-language.sh $lang --write failed"; continue
  fi
  desc="$d/profiles/${lang}.profile.sh"
  [ -f "$desc" ] || { note "$lang: descriptor not regenerated"; continue; }
  bash -n "$desc" || { note "$lang: regenerated descriptor not valid bash"; continue; }
  ( set -e; cd "$d"
    # shellcheck disable=SC1090  # descriptor is generated at runtime by the generator under test
    . "profiles/${lang}.profile.sh"
    [ "${PROFILE_ID:-}" = "$lang" ] || { echo "PROFILE_ID != $lang"; exit 1; }
    [ "${#PROFILE_GATES[@]}" -gt 0 ] || { echo "empty PROFILE_GATES"; exit 1; }
    declare -F profile_detect >/dev/null || { echo "no profile_detect"; exit 1; }
    declare -F profile_sync   >/dev/null || { echo "no profile_sync"; exit 1; }
    for g in "${PROFILE_GATES[@]}"; do
      declare -F "profile_gate_${g}" >/dev/null || { echo "no profile_gate_${g}"; exit 1; }
    done
  ) || note "$lang: regenerated descriptor has an incomplete Profile Interface"
done

# --- 4. init.sh degrades gracefully when a demoted surface is present but its --
# descriptor is NOT installed: it must warn + point at the generator and NOT
# crash (the demoted descriptors are hard-sourced by init.sh's gate branch).
g="${TMP_DIR}/graceful"
mkdir -p "$g/scripts" "$g/fakebin"
cp "${ROOT}/scripts/init.sh" "$g/scripts/init.sh"
cp -R "${ROOT}/profiles" "$g/profiles"   # ships python+node only (go/java/ruby demoted)
cat > "$g/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) exit 0 ;;
	api) printf 'fixture-user\n' ;;
esac
SH
cat > "$g/fakebin/uv" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$g/fakebin/go" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$g/fakebin"/*
( cd "$g" && git init -q -b main \
    && git config commit.gpgsign false \
    && git config user.email f@example.com \
    && git config user.name fixture \
    && printf 'module fixture\n' > go.mod \
    && printf '[project]\nname="f"\nversion="0.1.0"\n' > pyproject.toml )
if ! ( cd "$g" && PATH="$g/fakebin:$PATH" ./scripts/init.sh >"$OUT" 2>&1 ); then
  cat "$OUT"; note "init.sh crashed on a go.mod repo whose go profile is demoted (must degrade, not fail)"
fi
grep -Fq 'scaffold-language.sh go --write' "$OUT" \
  || { cat "$OUT"; note "init.sh must point at the generator when a demoted surface's profile is absent"; }

if [ "$fail" -ne 0 ]; then
  echo "demoted-profiles scaffoldable sensor FAILED"
  exit 1
fi
echo "demoted-profiles scaffoldable sensor passed"
