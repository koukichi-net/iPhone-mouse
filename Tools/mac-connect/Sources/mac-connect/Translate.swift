import Foundation
import HIDCore

/// `mac-connect translate [--layout us|jis] [--host macos|windows]`
///
/// Offline check of a HIDCore KeyMap against this Mac: for every printable ASCII character,
/// the key stroke the map sends and what macOS would type for it with the current keyboard
/// layout under each keyboard type (ANSI 40, ISO 41, JIS 42). Lists the mismatches.
/// Reads only; sends nothing.
func runTranslate(args: [String]) -> Int32 {
    guard let layout = KeyTranslate.currentLayout() else {
        emit("TRANSLATE cannot read the current keyboard layout")
        return 1
    }
    let host: HostOS = (option("--host", in: args)?.lowercased() == "windows") ? .windows : .macOS
    let layouts: [KeyboardLayout] = option("--layout", in: args).flatMap { KeyboardLayout(rawValue: $0.lowercased()) }.map { [$0] } ?? [.us, .jis]
    let types = [KeyTranslate.ansi, KeyTranslate.iso, KeyTranslate.jis]
    emit("TRANSLATE current keyboard layout: \(layout.id); host OS of the map: \(host.rawValue)")
    for kl in layouts {
        let map = KeyMap(layout: kl, host: host)
        emit("TRANSLATE map=\(kl.rawValue)/\(host.rawValue)  columns: char | usage mods | typed with type 40 ANSI | 41 ISO | 42 JIS")
        var mismatches: [Int: [String]] = [:]
        for v in 0x20...0x7E {
            let ch = Character(Unicode.Scalar(UInt8(v)))
            guard let s = map.keyStroke(for: ch) else {
                emit("TRANSLATE   \(KeyTranslate.show(String(ch)))  (not in map)")
                continue
            }
            var cols: [String] = []
            for t in types {
                let got = KeyTranslate.characters(layout: layout, usage: s.usage.rawValue, modifiers: s.modifiers, keyboardType: t)
                let ok = got == String(ch)
                if !ok { mismatches[t, default: []].append("\(KeyTranslate.show(String(ch)))→\(KeyTranslate.show(got))") }
                cols.append("\(KeyTranslate.show(got))\(ok ? "" : " ✗")")
            }
            emit(String(format: "TRANSLATE   %@  usage=0x%02X mods=0x%02X  | %@", KeyTranslate.show(String(ch)), s.usage.rawValue, s.modifiers.rawValue,
                        cols.joined(separator: " | ")))
        }
        for t in types {
            let m = mismatches[t] ?? []
            emit("TRANSLATE SUMMARY map=\(kl.rawValue)/\(host.rawValue) type=\(t) \(KeyTranslate.typeName(t)): \(95 - m.count)/95 match; mismatches(\(m.count)): \(m.joined(separator: " "))")
        }
    }
    let types0 = KeyboardTypeStore.all()
    emit("TRANSLATE \(KeyboardTypeStore.path): \(types0.isEmpty ? "(unreadable or empty)" : types0.sorted { $0.key < $1.key }.map { "\"\($0.key)\"=\($0.value) (\(KeyTranslate.typeName($0.value)))" }.joined(separator: ", "))")
    return 0
}
