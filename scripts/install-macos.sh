#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/macos-build-common.sh"
build_root="$repo_root/tmp/macos-install"
destination="$HOME/Applications/WeatherOdds.app"
built_app="$build_root/Build/Products/Debug/WeatherOdds.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Debug enables the host's existing reload-on-launch behavior. This is still
# a fully signed build; unsigned verification uses a different directory.
xcodebuild \
  -project "$repo_root/macos/WeatherOdds.xcodeproj" \
  -scheme WeatherOdds \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$build_root" \
  CODE_SIGNING_ALLOWED=YES \
  build

# Xcode automatically registers its build product; only the installed copy
# should remain registered after this command.
unregister_build_app "$built_app"

mkdir -p "$HOME/Applications"
stage="$(mktemp -d "$HOME/Applications/.weatherodds-install.XXXXXX")"
replacement_complete=false
cleanup() {
  if [[ "$replacement_complete" = false && -e "$stage/previous.app" ]]; then
    if [[ ! -e "$destination" ]]; then
      mv "$stage/previous.app" "$destination" || {
        printf 'Previous installation preserved at %s\n' "$stage/previous.app" >&2
        return
      }
    else
      printf 'Previous installation preserved at %s\n' "$stage/previous.app" >&2
      return
    fi
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
app="$stage/WeatherOdds.app"
ditto "$built_app" "$app"

# Require an Apple signing identity, a valid resource seal, and the actual
# signed entitlements. Merely having an entitlements file in source is not enough.
for bundle in "$app" "$app/Contents/PlugIns/WeatherOddsWidget.appex"; do
  codesign --verify --deep --strict -R='anchor apple generic' "$bundle"
  codesign --display --entitlements - --xml "$bundle" > "$stage/entitlements.plist"
  test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$stage/entitlements.plist")" = true
done
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$stage/entitlements.plist")" = true

# Preserve an existing installation until its replacement is in place.
if [[ -e "$destination" ]]; then
  mv "$destination" "$stage/previous.app"
fi
mv "$app" "$destination"

"$lsregister" -f "$destination"
pluginkit -a "$destination/Contents/PlugIns/WeatherOddsWidget.appex"
# A previous host process may still be running; a new instance executes the
# reload-on-launch hook against the newly installed widget.
open -n "$destination"
replacement_complete=true
printf 'Installed signed widget: %s\n' "$destination"
