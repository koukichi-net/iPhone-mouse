import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let usage = """
usage:
  mac-connect connect [--timeout seconds] [--name substring]
      Connect to a phone advertising the HID service (0x1812) and wait until macOS
      creates a Bluetooth LE HID device for it. Exit 0 on success, 1 on timeout,
      2 if Bluetooth is unavailable. Default timeout 30 s.
  mac-connect status
      List HID devices whose Transport is "Bluetooth Low Energy", with their
      collections, elements and report descriptor.
  mac-connect monitor [seconds] [--no-open] [--per-device] [--seize [--ack-f13]] [--kbd-type N]
      Print hot-plug events and input values of Bluetooth LE HID devices, the cursor
      position at 4 Hz, and every key event reaching the system (event tap). Default 60 s.
      --no-open only watches hot-plug. --per-device opens each device separately.
      --seize opens HIDPad devices exclusively (their input reaches only this tool) and
      shows what macOS would type for each key; released on exit/SIGINT/SIGTERM.
      --ack-f13 (with --seize) writes the seize token to the phone after a proven F13.
      --kbd-type overrides the keyboard type used for KEY lines (40 ANSI, 41 ISO, 42 JIS).
  mac-connect translate [--layout us|jis] [--host macos|windows]
      For every printable ASCII character: the key HIDPad sends and what this Mac types
      for it with the current layout under keyboard types ANSI/ISO/JIS. Sends nothing.
  mac-connect inputsource [--list] [--watch seconds] [--select ID]
      Print the current keyboard input source (TIS); --list also the enabled ones;
      --watch prints every change for that long; --select selects one (to restore it).
"""

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
let code: Int32
switch args.first {
case "connect":
    let timeout = option("--timeout", in: args).flatMap(Double.init) ?? 30
    let connector = Connector(timeout: timeout, nameFilter: option("--name", in: args))
    Connector.shared = connector
    code = await connector.run()
case "status":
    code = runStatus()
case "monitor":
    let seconds = args.dropFirst().first.flatMap(Double.init) ?? 60
    var o = Monitor.Options()
    o.openDevices = !args.contains("--no-open")
    o.perDevice = args.contains("--per-device")
    o.seize = args.contains("--seize")
    o.ackF13 = args.contains("--ack-f13")
    o.keyboardTypeOverride = option("--kbd-type", in: args).flatMap(Int.init)
    if o.ackF13 && !o.seize {
        print("--ack-f13 needs --seize")
        exit(64)
    }
    let monitor = Monitor(options: o)
    Monitor.shared = monitor
    // Stop cleanly (releasing any seize) on SIGINT/SIGTERM/SIGHUP. If the process dies
    // anyway, the kernel closes its IOHID user clients, which also ends the seize.
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { Monitor.shared?.stop("signal \(sig)") } }
        src.resume()
        signalSources.append(src)
    }
    code = await monitor.run(seconds: seconds)
    signalSources.forEach { $0.cancel() }
case "translate":
    code = runTranslate(args: args)
case "inputsource":
    code = runInputSource(args: args)
default:
    print(usage)
    code = args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 64
}
exit(code)
