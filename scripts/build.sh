#!/bin/bash
# Generate the Xcode project and build HIDPad for the device.
# Usage: scripts/build.sh [--udid UDID] [--release]
#   default: Debug build (self-tests, probes, log) in App/build, full log App/build/xcodebuild.log
#   --release: optimised Release build in App/build/release, full log App/build/release/xcodebuild.log
set -euo pipefail
source "$(dirname "$0")/common.sh" "$@"
if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  echo "DEVELOPMENT_TEAM is not set. Copy scripts/local.env.example to scripts/local.env and fill it in." >&2
  exit 2
fi
cd "$APP_DIR"
xcodegen generate --quiet
mkdir -p "$DERIVED_DIR"
set +e
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination "id=$UDID" -derivedDataPath "$DERIVED_DIR" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$DERIVED_DIR/xcodebuild.log" 2>&1
status=$?
set -e
grep -E "error:|App/Sources/.*warning:|\*\* BUILD" "$DERIVED_DIR/xcodebuild.log" | sort -u | tail -40
[[ $status -eq 0 ]] && echo "app: $APP_PATH"
exit $status
