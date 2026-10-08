#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release --disable-sandbox
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/AgentTrail.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/AgentTrail" "$app_dir/Contents/MacOS/AgentTrail"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/"
cp LICENSE THIRD_PARTY.md PRIVACY.md "$app_dir/Contents/Resources/"
codesign --force --sign "${AGENTTRAIL_SIGN_IDENTITY:--}" "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built %s\n' "$app_dir"
