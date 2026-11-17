import Foundation
import Carbon

/// `mac-connect inputsource [--list] [--watch seconds] [--select ID]`
///
/// Reads (and, with `--select`, sets) the Mac's current keyboard input source with the Text
/// Input Source Services API. Used for the one-off check of whether かな (LANG1) / 英数 (LANG2)
/// from HIDPad switch the input source (design §8.4). Sends no input.
/// - default: one line with the current input source (ID, name, whether it is ASCII-capable).
/// - `--list`: also every enabled, selectable keyboard input source / input mode.
/// - `--watch s`: poll every 50 ms for `s` seconds (running the run loop so TIS notifications
///   are delivered) and print a line on every change.
/// - `--select ID`: select that input source (to restore the starting one), then print the
///   current one.
func runInputSource(args: [String]) -> Int32 {
    if let id = option("--select", in: args) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let src = list.first else {
            emit("INPUTSOURCE select \(id): not found among enabled input sources")
            return 1
        }
        let status = TISSelectInputSource(src)
        emit("INPUTSOURCE select \(id) -> OSStatus \(status)")
        CFRunLoopRunInMode(.defaultMode, 0.3, false)
    }
    emit("INPUTSOURCE current \(describe(currentSource()))")
    if args.contains("--list") {
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let list = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        for s in list where stringProp(s, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String) {
            emit("INPUTSOURCE enabled \(describe(s))")
        }
    }
    if let w = option("--watch", in: args).flatMap(Double.init) {
        var last = stringProp(currentSource(), kTISPropertyInputSourceID)
        let end = Date().addingTimeInterval(w)
        emit("INPUTSOURCE watch \(w) s start: \(last ?? "nil")")
        while Date() < end {
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            let now = stringProp(currentSource(), kTISPropertyInputSourceID)
            if now != last {
                emit("INPUTSOURCE changed \(last ?? "nil") -> \(now ?? "nil")")
                last = now
            }
        }
        emit("INPUTSOURCE watch end: \(last ?? "nil")")
    }
    return 0
}

private func currentSource() -> TISInputSource {
    TISCopyCurrentKeyboardInputSource().takeRetainedValue()
}

private func stringProp(_ s: TISInputSource, _ key: CFString) -> String? {
    guard let p = TISGetInputSourceProperty(s, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

private func boolProp(_ s: TISInputSource, _ key: CFString) -> Bool? {
    guard let p = TISGetInputSourceProperty(s, key) else { return nil }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}

private func describe(_ s: TISInputSource) -> String {
    let id = stringProp(s, kTISPropertyInputSourceID) ?? "nil"
    let name = stringProp(s, kTISPropertyLocalizedName) ?? "nil"
    let type = stringProp(s, kTISPropertyInputSourceType) ?? "nil"
    let ascii = boolProp(s, kTISPropertyInputSourceIsASCIICapable).map { "\($0)" } ?? "nil"
    return "id=\(id) name=\"\(name)\" type=\(type) asciiCapable=\(ascii)"
}
