#!/bin/zsh
# U3 trial: terminate the probe app, keep it off for <off> seconds, relaunch it, and watch the Mac.
# The Mac side only runs `mac-connect monitor --no-open` (IOKit hot-plug + cursor; no CoreBluetooth).
# usage: ./measure-restart.sh <name> <off-seconds> <layout A|B> [observe-seconds=45] [repeat=30]
set -u
cd "${0:A:h}"
UDID=${UDID:?set UDID to the iPhone's identifier}
BUNDLE=dev.koukichi.hogm0
MC=../../Tools/mac-connect/.build/release/mac-connect
name=$1; off=$2; layout=$3; observe=${4:-45}; rep=${5:-30}
dir=build/runs; mkdir -p $dir
ts() { python3 -c 'import datetime; print(datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3])'; }
note() { print -r -- "[$(ts)] TRIAL $*" | tee -a $dir/$name-trial.log; }

logstart=$(date "+%Y-%m-%d %H:%M:%S")
$MC monitor $(( off + observe + 12 )) --no-open > $dir/$name-mac.log 2>&1 &
mpid=$!
sleep 3

pid=$(xcrun devicectl device info processes --device $UDID 2>/dev/null | awk '/HOGM0\.app\/HOGM0 *$/ {print $1}')
if [[ -n "$pid" ]]; then
  note "terminate app pid=$pid"
  xcrun devicectl device process terminate --device $UDID --pid $pid > /dev/null 2>&1
  note "terminate returned"
else
  note "app not running"
fi
sleep 2
left=$(xcrun devicectl device info processes --device $UDID 2>/dev/null | awk '/HOGM0\.app\/HOGM0 *$/ {print $1}')
note "app process after terminate: ${left:-none}"
sleep $(( off > 4 ? off - 4 : 0 ))
note "Mac BLE HID devices before relaunch: $($MC status | grep -c ' device 0x')"
note "launch layout=$layout repeat=$rep"
xcrun devicectl device process launch --console --terminate-existing --device $UDID $BUNDLE -- --layout=$layout --repeat=$rep > $dir/$name-phone.log 2>&1 &
sleep $observe
note "end of observation; Mac BLE HID devices: $($MC status | grep -c ' device 0x')"
wait $mpid
logend=$(date "+%Y-%m-%d %H:%M:%S")
/usr/bin/log show --start "$logstart" --end "$logend" --predicate 'process == "bluetoothd" OR process == "BTLEServer"' --style compact > $dir/$name-bt-raw.log 2>&1
grep -E 'BTLEServer|Server\.GATT\] (Received "service changed"|Finding all)|LE Connection|isconnect|onnection complete|ncrypt' $dir/$name-bt-raw.log \
  | grep -v 'statedump\|Received XPC message' > $dir/$name-bt.log
note "logs: $dir/$name-{trial,mac,phone,bt,bt-raw}.log"
