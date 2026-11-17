#!/bin/bash
# Stop the HIDPad console process on the Mac (the app on the phone exits with it).
# Usage: scripts/stop.sh
set -euo pipefail
source "$(dirname "$0")/common.sh" "$@"
pkill -f "devicectl device process launch .*$BUNDLE_ID" && echo "stopped" || echo "no HIDPad console process"
