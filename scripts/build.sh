#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/glassbridge-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --package-path "$project_root" --cache-path "${TMPDIR:-/tmp}/glassbridge-spm-cache" --disable-sandbox -c release
app_bundle="$project_root/dist/GlassBridge.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$project_root/.build/release/GlassBridge" "$app_bundle/Contents/MacOS/GlassBridge"
adb_binary="${GLASSBRIDGE_ADB_PATH:-$HOME/Library/Android/sdk/platform-tools/adb}"
if [ -x "$adb_binary" ]; then
  cp "$adb_binary" "$app_bundle/Contents/Resources/adb"
  chmod +x "$app_bundle/Contents/Resources/adb"
  notice_path="$(dirname "$adb_binary")/NOTICE.txt"
  if [ -f "$notice_path" ]; then cp "$notice_path" "$app_bundle/Contents/Resources/ADB-NOTICE.txt"; fi
fi
cp "$project_root/Info.plist" "$app_bundle/Contents/Info.plist"
swift "$project_root/scripts/make-icon.swift" "$app_bundle/Contents/Resources"
if [ -x "$app_bundle/Contents/Resources/adb" ]; then
  codesign --force --sign - "$app_bundle/Contents/Resources/adb"
fi
codesign --force --sign - "$app_bundle"
printf 'Built %s\n' "$app_bundle"
