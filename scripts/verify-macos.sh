#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/macos-build-common.sh"

# Never overwrite Xcode's runnable, signed app with an unsigned build.
# Xcode registers macOS apps even for unsigned builds. The build gets its own
# bundle ID because unregistering a copy that shares the installed app's ID
# also drops the installed app's App Intents metadata, and the widget can then
# no longer decode its configuration. Remove the temporary registration on
# exit so the verification copy does not linger in Launch Services.
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
  WEATHERODDS_BUNDLE_ID=com.polarsky.weatherodds.verification \
  build
