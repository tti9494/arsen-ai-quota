#!/bin/bash
set -euo pipefail
umask 022
cd "$(dirname "$0")"
out=${1:-build}
mkdir -p "$(dirname "$out")"
mkdir "$out" || { echo "Choose a new output directory." >&2; exit 1; }
out=$(cd "$out" && pwd -P)
name='ARSEN AI Quota.app'
app="$out/$name/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
plutil -lint Info.plist
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -file-prefix-map "$(pwd -P)=." -debug-prefix-map "$(pwd -P)=." \
  -framework AppKit Quota.swift SelectedQuota.swift ARSENQuota.swift -o "$app/MacOS/ARSENQuota"
/usr/bin/strip -S -x "$app/MacOS/ARSENQuota"
install -m 644 Info.plist "$app/Info.plist"
install -m 644 LICENSE "$app/Resources/LICENSE"
/usr/bin/codesign --force --sign - --timestamp=none "$out/$name"
/usr/bin/codesign --verify --strict --deep "$out/$name"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
archive="ARSEN-AI-Quota-$version-b$build-arm64.zip"
cd "$out"
export TZ=UTC
find "$name" -exec touch -t 200101010000 {} +
find "$name" -type f | LC_ALL=C sort | /usr/bin/zip -Xq "$archive" -@
shasum -a 256 "$archive" > "$archive.sha256"
