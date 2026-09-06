#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/macos-build-common.sh"

# Never overwrite Xcode's runnable, signed app with an unsigned build.
# Xcode registers macOS apps even for unsigned builds. Remove that temporary
# registration on exit so it cannot compete with the installed app.
app="$repo_root/tmp/macos-verification/Build/Products/Debug/WeatherOdds.app"
cleanup() {
  if [[ -d "$app" ]]; then
    unregister_build_app "$app"
  fi
}
trap cleanup EXIT

xcodebuild \
  -project "$repo_root/macos/WeatherOdds.xcodeproj" \
  -scheme WeatherOdds \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$repo_root/tmp/macos-verification" \
  CODE_SIGNING_ALLOWED=NO \
  build
