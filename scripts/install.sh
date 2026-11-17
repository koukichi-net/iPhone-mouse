#!/bin/bash
# Install the built HIDPad.app on the device (replaces the installed one; settings are kept).
# Usage: scripts/install.sh [--udid UDID] [--release]
#   --release: the Release build from `scripts/build.sh --release` (default: the Debug build)
set -euo pipefail
source "$(dirname "$0")/common.sh" "$@"
[[ -d "$APP_PATH" ]] || { echo "not built: $APP_PATH (run scripts/build.sh $*)"; exit 1; }
xcrun devicectl device install app --device "$UDID" "$APP_PATH"
