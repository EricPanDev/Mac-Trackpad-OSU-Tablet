#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_FILE="$ROOT_DIR/app.swift"
APP_NAME="TrackpadOSU"
INSTALL_HOME="${INSTALL_HOME:-$HOME}"
APP_DIR="$INSTALL_HOME/Applications/$APP_NAME.app"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$APP_NAME"
SUPPORT_DIR="$INSTALL_HOME/Library/Application Support/$APP_NAME"
AGENT_PATH="$INSTALL_HOME/Library/LaunchAgents/com.eric.trackpadosu.monitor.plist"
PREFS_MAIN="$INSTALL_HOME/Library/Preferences/com.eric.TrackpadOSU.plist"
PREFS_MONITOR="$INSTALL_HOME/Library/Preferences/com.eric.trackpadosu.monitor.plist"
OLD_SUPPORT_DIR="$INSTALL_HOME/Library/Application Support/MacbookTrackpadOSU"
OLD_LOG_DIR="$INSTALL_HOME/Library/Logs/MacbookTrackpadOSU"
TEMP_HELPER_BINARY=""

cleanup() {
  if [[ -n "$TEMP_HELPER_BINARY" ]]; then
    rm -f "$TEMP_HELPER_BINARY"
  fi
}
trap cleanup EXIT

run_unregister_helper() {
  if [[ -x "$EXECUTABLE_PATH" ]]; then
    "$EXECUTABLE_PATH" --unregister-helper >/dev/null 2>&1 || true
    return
  fi

  if [[ -f "$SOURCE_FILE" ]] && command -v xcrun >/dev/null 2>&1 && xcrun swiftc -version >/dev/null 2>&1; then
    TEMP_HELPER_BINARY="$(mktemp "${TMPDIR:-/tmp}/TrackpadOSU-uninstall.XXXXXX")"
    xcrun swiftc -swift-version 5 -O "$SOURCE_FILE" -o "$TEMP_HELPER_BINARY" >/dev/null 2>&1 || true
    if [[ -x "$TEMP_HELPER_BINARY" ]]; then
      "$TEMP_HELPER_BINARY" --unregister-helper >/dev/null 2>&1 || true
    fi
  fi
}

run_unregister_helper

launchctl bootout "gui/$UID" "$AGENT_PATH" >/dev/null 2>&1 || true
launchctl disable "gui/$UID/com.eric.trackpadosu.monitor" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID/com.eric.TrackpadOSUHelper" >/dev/null 2>&1 || true
launchctl disable "gui/$UID/com.eric.TrackpadOSUHelper" >/dev/null 2>&1 || true
launchctl remove com.eric.TrackpadOSUHelper >/dev/null 2>&1 || true

pkill -x "TrackpadOSU" >/dev/null 2>&1 || true
pkill -x "TrackpadOSUHelper" >/dev/null 2>&1 || true
pkill -f "$OLD_SUPPORT_DIR/osu_autolaunch_watcher" >/dev/null 2>&1 || true
sleep 1
pkill -9 -x "TrackpadOSU" >/dev/null 2>&1 || true
pkill -9 -x "TrackpadOSUHelper" >/dev/null 2>&1 || true
pkill -9 -f "$OLD_SUPPORT_DIR/osu_autolaunch_watcher" >/dev/null 2>&1 || true

tccutil reset All com.eric.TrackpadOSU >/dev/null 2>&1 || true
tccutil reset All com.eric.TrackpadOSUHelper >/dev/null 2>&1 || true

rm -rf "$APP_DIR"
rm -f "$AGENT_PATH"
rm -rf "$SUPPORT_DIR"
rm -f "$PREFS_MAIN" "$PREFS_MONITOR"
rm -rf "$OLD_SUPPORT_DIR" "$OLD_LOG_DIR"

echo "TrackpadOSU uninstalled."
