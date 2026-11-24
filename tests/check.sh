#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bundle=$(cd "${1:?Pass the built app path}" && pwd -P)
app="$bundle/Contents/MacOS/ARSENQuota"
work=$(mktemp -d /private/tmp/arsen-quota-check.XXXXXX)
target=''
cleanup() {
  if [[ -n "$target" ]]; then kill "$target" 2>/dev/null || true; wait "$target" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
xcrun swiftc Quota.swift SelectedQuota.swift tests/Fixtures.swift tests/SelectedFixtures.swift -o "$work/fixtures"
xcrun swiftc tests/MenuCheck.swift -o "$work/menu"
policy='(version 1)(allow default)(deny network*)(deny process-fork)(deny file-read* (regex #"/(auth[.]json|[.]credentials[.]json)$"))'
sandbox-exec -p "$policy" "$work/fixtures" "$work"
mkdir "$work/bin"
for cli in codex claude agy curl; do
  printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$work/child-ran" > "$work/bin/$cli"
  chmod +x "$work/bin/$cli"
done
for sample in one persisted empty; do
  home="$work/$sample"
  if [[ "$sample" == persisted ]]; then home="$work/one"; fi
  mkdir -p "$home/.codex" "$home/.claude"
  for file in "$home/.codex/auth.json" "$home/.claude/.credentials.json"; do
    printf '%s\n' 'fixture-private-marker' > "$file"
  done
  /usr/bin/env -i HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$work" PATH="$work/bin" \
    /usr/bin/sandbox-exec -p "$policy" "$app" >"$work/app.log" 2>&1 &
  target=$!
  sleep 1
  "$work/menu" "$target" "$app" "$sample"
  kill "$target"
  wait "$target" 2>/dev/null || true
  target=''
  test ! -e "$work/child-ran"
  if /usr/bin/grep -Fq fixture-private-marker "$work/app.log"; then exit 1; fi
done
