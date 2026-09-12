#!/usr/bin/env bash
#
# Rebuild-and-relaunch loop for Handoff.
#
# Polls the Swift sources and, on change, builds *before* stopping the running
# app — so a syntax error leaves the previous build on screen instead of
# dropping you to a blank menu bar.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Absolute, so the stale-instance sweep below can't match another checkout.
readonly BINARY="$PWD/.build/debug/Handoff"
readonly APP_BUNDLE="$PWD/.build/debug/Handoff.app"
readonly APP_CONTENTS="$APP_BUNDLE/Contents"
readonly APP_MACOS="$APP_CONTENTS/MacOS"
readonly APP_RESOURCES="$APP_CONTENTS/Resources"
readonly APP_PLIST_SOURCE="$PWD/Resources/Handoff-Info.plist"
readonly APP_PLIST_DEST="$APP_CONTENTS/Info.plist"
readonly APP_EXECUTABLE="$APP_MACOS/Handoff"
readonly POLL_INTERVAL=0.3
readonly DEBOUNCE=0.15

app_pid=""

log() {
  printf '\033[2m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$1"
}

fingerprint() {
  find Sources Package.swift -type f -name '*.swift' -exec stat -f '%N %m' {} + 2>/dev/null | sort
}

stop_app() {
  [ -n "$app_pid" ] || return 0
  kill "$app_pid" 2>/dev/null
  wait "$app_pid" 2>/dev/null
  app_pid=""
}

package_app_bundle() {
  if [ ! -f "$APP_PLIST_SOURCE" ]; then
    log "missing Info.plist template at $APP_PLIST_SOURCE"
    return 1
  fi

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$BINARY" "$APP_EXECUTABLE"
  chmod +x "$APP_EXECUTABLE"
  cp "$APP_PLIST_SOURCE" "$APP_PLIST_DEST"
}

codesign_app_bundle() {
  if ! codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
    log "codesign failed for app bundle"
    return 1
  fi
}

start_app() {
  "$APP_EXECUTABLE" &
  app_pid=$!
  log "running (pid $app_pid)"
}

rebuild_and_restart() {
  log "building..."
  if ! swift build; then
    log "build failed — leaving the previous build running"
    return
  fi

  if ! package_app_bundle; then
    log "bundle packaging failed — leaving the previous build running"
    return
  fi

  if ! codesign_app_bundle; then
    log "codesign failed — leaving the previous build running"
    return
  fi

  stop_app
  start_app
}

cleanup() {
  trap - INT TERM EXIT
  stop_app
  log "stopped"
  exit 0
}
trap cleanup INT TERM EXIT

# A previous session killed hard enough to skip its trap leaves the app behind,
# which would stack a second notch overlay on this run.
if pkill -f "$APP_EXECUTABLE" 2>/dev/null || pkill -f "$BINARY" 2>/dev/null; then
  log "reaped an orphaned instance from a previous session"
  sleep 0.5
fi

log "watching Sources/ — press Ctrl-C to stop"
last_seen="$(fingerprint)"
rebuild_and_restart

while true; do
  sleep "$POLL_INTERVAL"
  current="$(fingerprint)"
  [ "$current" = "$last_seen" ] && continue

  # Let a burst of saves settle before spending a build on them.
  sleep "$DEBOUNCE"
  last_seen="$(fingerprint)"
  rebuild_and_restart
done
