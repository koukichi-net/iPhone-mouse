# mac-connect

Mac-side helper for HIDPad (design §7.1, §11.2). The iPhone app is a standard Bluetooth LE HID
device; macOS's own HID driver does all the work. This tool never reads or relays input.

## Build

```
swift build -c release
# binary: .build/release/mac-connect
```

The Info.plist in `Support/` is linked into the binary (`__TEXT,__info_plist`) so that macOS allows a
bare command-line tool to use CoreBluetooth. Bluetooth permission is attributed to the terminal app.

## Commands

| Command | What it does |
|---|---|
| `mac-connect connect [--timeout s] [--name substr]` | If a Bluetooth LE HID device already exists, prints it and exits 0 without touching Bluetooth. Otherwise looks for a system-connected peripheral with the HID service, else scans for a connectable peripheral advertising `0x1812`, connects, discovers the HID service, and waits until macOS creates a HID device with Transport "Bluetooth Low Energy". Exit 0 on success, 1 on timeout (default 30 s), 2 if Bluetooth is unavailable. It exits without cancelling the connection. |
| `mac-connect status` | Lists HID devices with Transport "Bluetooth Low Energy": product, VendorID/ProductID, primary usage, `DeviceUsagePairs`, the report descriptor macOS holds, the application collections, and per usage page the input/output elements. Uses IOKit only. |
| `mac-connect monitor [seconds] [--no-open] [--per-device] [--seize [--ack-f13]] [--kbd-type N]` | Test oracle. Prints `DEVICE+`/`DEVICE-` when a BLE HID device appears or goes away (with its registry IDs and `KBDTYPE`, the keyboard type macOS stored for it), `VALUE` lines for every new input value from BLE HID devices (page, usage, report ID, value, with the HID timestamp), `CURSOR` lines at 4 Hz, `SYS` lines when the system-wide modifier flags or F13 change (polled), and `SYSKEY` lines for every key event that reaches the window server (listen-only event tap: keyboard type, and `src=BLE(...)` when the event can be attributed to a BLE device; key codes of other keyboards are hidden). Ends with a summary. `--no-open` watches hot-plug and cursor only. `--per-device` opens each device separately instead of through the manager. Uses IOKit, CoreGraphics and Carbon (UCKeyTranslate), never CoreBluetooth. |
| `… monitor --seize` | Opens HIDPad devices (manufacturer "Apple Inc." and no VendorID — never another BLE keyboard or mouse) with `kIOHIDOptionsTypeSeizeDevice`: their input reaches only this tool, not the system or any app. Prints `SEIZE OK` / `SEIZE FAILED` / `SEIZE SKIPPED` per device, `KEY` lines with what macOS would type for each key down (current layout; the device's keyboard type and ANSI/ISO/JIS), `TYPED` per keyboard type at the end, and `SEIZE RELEASED` + `SEIZE none active` on exit (time up, SIGINT, SIGTERM, SIGHUP). If the process dies otherwise, the kernel closes its HID clients, which ends the seize too. **While seized, the phone's mouse and keyboard do nothing on the Mac.** |
| `… monitor --seize --ack-f13` | After F13 down+up arrives on a seized device and the event tap saw no F13 (and no BLE key event) in the system, writes the seize token (LED output report value `0x1D`) to the device. HIDPad's `--selftest=text` types only after receiving this token. |
| `mac-connect inputsource [--list] [--watch s] [--select ID]` | Prints the Mac's current keyboard input source (Text Input Source Services: ID, name, type, ASCII-capable); `--list` also the enabled ones; `--watch s` polls for `s` seconds (running the run loop) and prints every change; `--select ID` selects an enabled source (used to restore the starting one after the かな/英数 check). Sends no input. |
| `mac-connect translate [--layout us\|jis] [--host macos\|windows]` | Offline: for every printable ASCII character, the key stroke HIDPad's KeyMap sends and what this Mac types for it with the current keyboard layout under keyboard types 40 (ANSI), 41 (ISO), 42 (JIS); lists mismatches. Sends nothing. |

### Keyboard type

macOS decides which character a key position types from the *keyboard type* it assigned to the
device. loginwindow looks it up in `/Library/Preferences/com.apple.keyboardtype.plist` under
`"<productID>-<vendorID>-<countryCode>"` (HIDPad: `"0-0-0"`) and starts Keyboard Setup Assistant
for an unknown keyboard. Change it with System Settings > Keyboard > キーボードの種類を変更….

All lines start with a local wall-clock timestamp (`HH:mm:ss.SSS`) so they can be lined up with the
iPhone app's log.

## Permissions

- `connect` needs Bluetooth permission for the terminal app (System Settings > Privacy & Security > Bluetooth).
- `monitor` (without `--no-open`) opens the devices, which needs Input Monitoring for the terminal
  app when a keyboard collection is present. The tool checks with `IOHIDCheckAccess` and never
  requests access itself; if the open fails it says so and keeps reporting hot-plug and cursor.
- `status` and `translate` need no permission.
- The event tap (`SYSKEY` lines) also uses Input Monitoring; without it the monitor says `TAP FAILED`.
