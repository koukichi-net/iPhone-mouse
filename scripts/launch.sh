#!/bin/bash
# Launch the Debug build of HIDPad with its stdout captured, detached in the background
# (development and tests). The Release build has no log and ignores arguments: start it
# with scripts/open.sh or from the home screen.
# Usage: scripts/launch.sh [--udid UDID] [--log FILE] [--fg] [-- app arguments...]
#   app arguments: --log-reports  --selftest=pointer[,inertia][,burst][,keys][,lang][,text][,kana][,compose]  --repeat=<s>
#                  --active-central=<uuid>  --text-layout=us|jis  --show=keys|function|text|media|settings|settings-scroll|settings-cursorpad|hosts|hostdetail|speed
#                  --reading-probe (log on-device readings of fixed examples)  --textcap-probe (no-send field probe:
#                  marked text, then cursor-pad caret moves logged as "would send ↓×2", nothing sent)
#                  --cursorpad-visible (show the invisible text field and its cursor pad, for screenshots)
#                  --show=clicker (clicker screen for screenshots; the saved クリッカーモード setting is not changed)
#                  --clicker-probe (no-send clicker probe: the BLE layer hands no input report to CoreBluetooth,
#                  logs WOULD_SEND instead; drives next/previous taps, pointer holds with a synthetic rotation for
#                  each laser method, a forced release, then 4 s of the real gyro at rest; shows the clicker screen)
#   compose = marked-text growth sequences on the real text field through the composition mirror
#   (seize required like text/kana; also needs --show=text and the phone unlocked)
#   pointer = one-finger drag, two-finger scroll, scroll-strip scroll (net zero); inertia = strip flick
#   up and down with inertia (≈2 notches each way, net zero); lang = かな then 英数 alone, unseized
#   (one-off input-source check); text / kana type only after `mac-connect monitor --seize --ack-f13`
#   acknowledges a proven seize (F13 probes repeat every 4 s for 30 s).
#   default log: App/build/run.log. A previous console process for HIDPad is stopped first
#   (devicectl --terminate-existing also restarts the app itself).
set -euo pipefail
source "$(dirname "$0")/common.sh" "$@"
[[ "${1:-}" == "--udid" ]] && shift 2
LOG="$BUILD_DIR/run.log"
FG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) LOG="$2"; shift 2 ;;
    --fg) FG=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
mkdir -p "$(dirname "$LOG")"
pkill -f "devicectl device process launch .*$BUNDLE_ID" 2>/dev/null && sleep 1 || true
CMD=(xcrun devicectl device process launch --console --terminate-existing --device "$UDID" "$BUNDLE_ID")
[[ $# -gt 0 ]] && CMD+=(-- "$@")
if [[ $FG -eq 1 ]]; then
  exec "${CMD[@]}"
fi
nohup "${CMD[@]}" > "$LOG" 2>&1 < /dev/null &
pid=$!
disown $pid 2>/dev/null || true
echo "launched: pid=$pid log=$LOG args=[$*]"
