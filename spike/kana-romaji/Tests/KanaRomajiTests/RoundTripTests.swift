import Testing
@testable import KanaRomaji

/// Replays a conversion through a host IME model: `.ime` runs are decoded by the oracle,
/// `.direct` runs are typed literally, `.space` becomes U+3000 (empty composition).
/// Returns nil (and records an issue) if a run cannot be decoded or leaves keys pending.
func replay(_ conversion: KanaRomaji.Conversion, on ime: RomajiIME,
            sourceLocation: SourceLocation = #_sourceLocation) -> String? {
    var host = ""
    for segment in conversion.segments {
        switch segment.kind {
        case .direct: host += segment.keys
        case .space: host += "\u{3000}"
        case .ime:
            let r = ime.decode(segment.keys)
            guard r.ok, r.pending.isEmpty else {
                Issue.record("\(ime.name): cannot decode \"\(segment.keys)\" (got \(r))",
                             sourceLocation: sourceLocation)
                return nil
            }
            host += r.output
        }
    }
    return host
}

/// What the host should end up showing for `input`: the input minus dropped characters, with
/// direct-mode approximations replaced by their ASCII.
func expectedHostText(_ input: String, _ conversion: KanaRomaji.Conversion) -> String {
    let dropped = Set(conversion.unconvertible.map(\.characterOffset))
    var directApprox: [Int: String] = [:]
    for a in conversion.approximations where a.kind == .direct { directApprox[a.characterOffset] = a.keys }
    var out = ""
    for (i, c) in input.enumerated() where !dropped.contains(i) {
        out += directApprox[i] ?? String(c)
    }
    return out
}

func expectRoundTrip(_ input: String, mode: KanaRomaji.Mode,
                     sourceLocation: SourceLocation = #_sourceLocation) {
    let conversion = KanaRomaji.convert(input, mode: mode)
    let expected = hostFold(expectedHostText(input, conversion))
    for ime in bothIMEs {
        guard let host = replay(conversion, on: ime, sourceLocation: sourceLocation) else { continue }
        #expect(hostFold(host) == expected,
                "\(ime.name) \(mode): \(input) -> \(conversion.keys) -> \(host)",
                sourceLocation: sourceLocation)
    }
}

/// Every character the library types with the IME on.
let allIMECharacters: [Character] = {
    var cs: [Character] = []
    for v in Array(0x3041...0x3096) + Array(0x30A1...0x30FC) + Array(0xFF61...0xFF9F)
        + Array(0x3000...0x303F) + Array(0xFF01...0xFF5E) {
        let c = Character(Unicode.Scalar(v)!)
        switch KanaRomaji.mapping(for: c) {
        case .ime: cs.append(c)
        case .approximate(_, .ime, _): cs.append(c)
        default: break
        }
    }
    for s in ["ｶﾞ", "ｷﾞ", "ｸﾞ", "ｹﾞ", "ｺﾞ", "ｻﾞ", "ｼﾞ", "ｽﾞ", "ｾﾞ", "ｿﾞ", "ﾀﾞ", "ﾁﾞ", "ﾂﾞ", "ﾃﾞ", "ﾄﾞ",
              "ﾊﾞ", "ﾋﾞ", "ﾌﾞ", "ﾍﾞ", "ﾎﾞ", "ﾊﾟ", "ﾋﾟ", "ﾌﾟ", "ﾍﾟ", "ﾎﾟ", "ｳﾞ"] {
        cs.append(Character(s))
    }
    return cs
}()

struct RoundTripTests {

    @Test func oracleTablesLoaded() {
        #expect(appleIME.table.count > 250)
        #expect(microsoftIME.table.count > 250)
        #expect(allIMECharacters.count > 200)
    }

    /// The core per-kana contract: each spelling typed alone yields exactly that one kana in BOTH
    /// IMEs and leaves nothing pending in the romaji buffer.
    @Test func perKanaEachCharacterAlone() {
        for c in allIMECharacters {
            let keys = KanaRomaji.convert(String(c)).keys
            for ime in bothIMEs {
                let r = ime.decode(keys)
                #expect(r.ok && r.pending.isEmpty, "\(ime.name): \(c) -> \(keys) leaves \(r)")
                #expect(hostFold(r.output) == hostFold(String(c)), "\(ime.name): \(c) -> \(keys) -> \(r.output)")
            }
        }
    }

    /// No table key strictly extends a per-kana spelling, so the host never waits for more keys
    /// after one (which would break one-Backspace-per-character).
    @Test func noOracleKeyExtendsAPerKanaSpelling() {
        let spellings = Set(allIMECharacters.compactMap { c -> String? in
            KanaRomaji.convert(String(c)).segments.first?.keys
        })
        for ime in bothIMEs {
            for s in spellings {
                #expect(!ime.strictPrefixes.contains(s), "\(ime.name): \(s) is a prefix of a longer key")
            }
        }
    }

    /// Any two per-kana spellings typed back to back decode to the two characters
    /// (e.g. ん + な = "nn"+"na", っ + か = "xtu"+"ka").
    @Test func perKanaAllPairs() {
        let chars = allIMECharacters.filter { $0.unicodeScalars.count == 1 && (0x3041...0x3096).contains($0.unicodeScalars.first!.value) }
            + Array("ー、。・「」？！０")
        for a in chars {
            for b in chars {
                let input = String([a, b])
                let keys = KanaRomaji.convert(input).keys
                for ime in bothIMEs {
                    let r = ime.decode(keys)
                    if !(r.ok && r.pending.isEmpty && hostFold(r.output) == hostFold(input)) {
                        Issue.record("\(ime.name): \(input) -> \(keys) -> \(r)")
                    }
                }
            }
        }
    }

    /// Every digraph the natural mode can emit decodes to its two kana in both IMEs.
    @Test func naturalDigraphsDecodeInBothIMEs() {
        for (pair, keys) in KanaRomaji.digraphTable {
            #expect(KanaRomaji.convert(pair, mode: .natural).keys == keys)
            for ime in bothIMEs {
                let r = ime.decode(keys)
                #expect(r.ok && r.pending.isEmpty && hostFold(r.output) == hostFold(pair),
                        "\(ime.name): \(pair) -> \(keys) -> \(r)")
            }
        }
    }

    @Test func naturalModeEachCharacterAlone() {
        for c in allIMECharacters { expectRoundTrip(String(c), mode: .natural) }
    }

    @Test func naturalSokuonBeforeEveryKana() {
        for c in allIMECharacters { expectRoundTrip("っ" + String(c), mode: .natural) }
        for c in allIMECharacters { expectRoundTrip("あっ" + String(c) + "ゃ", mode: .natural) }
    }
}
