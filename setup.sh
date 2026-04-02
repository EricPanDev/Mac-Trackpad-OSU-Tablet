#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_SLUG="EricPanDev/Mac-Trackpad-OSU-Tablet"
COMMIT_API_URL="https://api.github.com/repos/$REPO_SLUG/commits/main"
APP_NAME="TrackpadOSU"
INSTALL_HOME="${INSTALL_HOME:-$HOME}"
APP_DIR="$INSTALL_HOME/Applications/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SUPPORT_DIR="$INSTALL_HOME/Library/Application Support/$APP_NAME"
OLD_PLIST_PATH="$INSTALL_HOME/Library/LaunchAgents/com.eric.trackpadosu.monitor.plist"
EXECUTABLE_PATH="$MACOS_DIR/$APP_NAME"
SKIP_LAUNCHCTL="${SKIP_LAUNCHCTL:-0}"
SKIP_PERMISSION_REQUEST="${SKIP_PERMISSION_REQUEST:-$SKIP_LAUNCHCTL}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl was not found. Install Xcode Command Line Tools first." >&2
  echo "Run: xcode-select --install" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun was not found. Install Xcode Command Line Tools first." >&2
  echo "Run: xcode-select --install" >&2
  exit 1
fi

if ! xcrun swiftc -version >/dev/null 2>&1; then
  echo "swiftc was not found. Install Xcode Command Line Tools first." >&2
  echo "Run: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$SUPPORT_DIR" "$INSTALL_HOME/Applications"
mkdir -p "$(dirname "$OLD_PLIST_PATH")"

SOURCE_TEMP_DIR="$(mktemp -d "$SUPPORT_DIR/source.XXXXXX")"
SOURCE_FILE="$SOURCE_TEMP_DIR/app.swift"
PERMISSION_STATUS_FILE="$(mktemp "$SUPPORT_DIR/permission-status.XXXXXX")"
trap 'rm -rf "$SOURCE_TEMP_DIR"; rm -f "$PERMISSION_STATUS_FILE"' EXIT

LATEST_SHA="$(curl -fsSL "$COMMIT_API_URL" | sed -n 's/^  \"sha\": \"\\([^\"]*\\)\",$/\\1/p' | head -n1)"
if [[ -z "$LATEST_SHA" ]]; then
  echo "Failed to determine the latest commit for $REPO_SLUG." >&2
  exit 1
fi

SOURCE_URL="https://raw.githubusercontent.com/$REPO_SLUG/$LATEST_SHA/app.swift"

echo "Downloading latest app.swift..."
curl -fsSL "$SOURCE_URL" -o "$SOURCE_FILE"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>TrackpadOSU</string>
  <key>CFBundleDisplayName</key>
  <string>Mac Trackpad Tablet for OSU!</string>
  <key>CFBundleIdentifier</key>
  <string>com.eric.TrackpadOSU</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Mac Trackpad Tablet for OSU!</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

xcrun swiftc \
  -swift-version 5 \
  -O \
  "$SOURCE_FILE" \
  -o "$EXECUTABLE_PATH"

chmod +x "$EXECUTABLE_PATH"
rm -rf "$CONTENTS_DIR/Library"

cat > "$OLD_PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.eric.trackpadosu.monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EXECUTABLE_PATH</string>
    <string>--monitor</string>
  </array>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$SUPPORT_DIR/monitor.log</string>
  <key>StandardErrorPath</key>
  <string>$SUPPORT_DIR/monitor.log</string>
</dict>
</plist>
PLIST

PERMISSION_EXIT_CODE=0
if [[ "$SKIP_PERMISSION_REQUEST" == "1" ]]; then
  echo "Skipping permission request because SKIP_PERMISSION_REQUEST=1"
else
  run_permission_helper() {
    rm -f "$PERMISSION_STATUS_FILE"

    set +e
    open -n "$APP_DIR" --args --request-permissions "--permission-status-file=$PERMISSION_STATUS_FILE" "$@"
    local open_exit_code=$?
    set -e

    if [[ "$open_exit_code" -ne 0 ]]; then
      echo "Failed to launch the permission helper (open exit code $open_exit_code)." >&2
      PERMISSION_EXIT_CODE="$open_exit_code"
      return
    fi

    local attempts=0
    while [[ ! -f "$PERMISSION_STATUS_FILE" && "$attempts" -lt 150 ]]; do
      sleep 0.2
      attempts=$((attempts + 1))
    done

    if [[ ! -f "$PERMISSION_STATUS_FILE" ]]; then
      echo "Permission helper did not report a result." >&2
      PERMISSION_EXIT_CODE=98
      return
    fi

    local helper_status
    helper_status="$(tr -d '[:space:]' < "$PERMISSION_STATUS_FILE")"
    if [[ ! "$helper_status" =~ ^[0-9]+$ ]]; then
      echo "Permission helper reported an invalid result: $helper_status" >&2
      PERMISSION_EXIT_CODE=99
      return
    fi

    PERMISSION_EXIT_CODE="$helper_status"
  }

  echo "Requesting TrackpadOSU permissions..."
  run_permission_helper

  if [[ "$PERMISSION_EXIT_CODE" -eq 3 ]]; then
    echo
    echo "Please provide TrackpadOSU the requested permission in System Settings."
    echo "Installation will not continue until a fresh TrackpadOSU process detects that the permission has been granted."
  fi

  while [[ "$PERMISSION_EXIT_CODE" -eq 3 ]]; do
    sleep 2
    run_permission_helper --no-permission-prompt
  done
fi

if [[ "$PERMISSION_EXIT_CODE" -ne 0 ]]; then
  echo "Permission setup failed with exit code $PERMISSION_EXIT_CODE."
  exit "$PERMISSION_EXIT_CODE"
fi

if [[ "$SKIP_PERMISSION_REQUEST" != "1" ]]; then
  echo "Detected necessary permissions, continuing with install..."
fi

OSU_ALREADY_RUNNING=0
if "$EXECUTABLE_PATH" --osu-running; then
  OSU_ALREADY_RUNNING=1
fi

if [[ "$SKIP_LAUNCHCTL" == "1" ]]; then
  echo "Skipping background monitor registration because SKIP_LAUNCHCTL=1"
else
  launchctl bootout "gui/$UID" "$OLD_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl enable "gui/$UID/com.eric.trackpadosu.monitor" >/dev/null 2>&1 || true
  launchctl enable "gui/$UID/com.eric.TrackpadOSUHelper" >/dev/null 2>&1 || true
  "$EXECUTABLE_PATH" --unregister-helper >/dev/null 2>&1 || true
  pkill -x "TrackpadOSUHelper" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$OLD_PLIST_PATH"
  launchctl enable "gui/$UID/com.eric.trackpadosu.monitor"
  launchctl kickstart -k "gui/$UID/com.eric.trackpadosu.monitor"
fi

if [[ "$OSU_ALREADY_RUNNING" == "1" ]]; then
  open -n "$APP_DIR" --args --overlay
fi

echo "TrackpadOSU installed, it will launch automatically when you open osu."
