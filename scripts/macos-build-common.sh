#!/bin/bash

unregister_build_app() {
  local output
  if ! output=$(/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$1" 2>&1); then
    # Incremental builds may skip registration. -10814 is
    # kLSApplicationNotFoundErr: the desired unregistered state already holds.
    case "$output" in
      *": -10814"*) ;;
      *) printf '%s\n' "$output" >&2; return 1 ;;
    esac
  fi
}
