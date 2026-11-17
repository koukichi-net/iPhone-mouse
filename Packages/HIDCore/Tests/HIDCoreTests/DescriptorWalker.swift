import Foundation

// A minimal, independent HID report descriptor parser used only by the tests.
// It decodes item sizes from the prefix bytes, carries global state across main items,
// and totals the bits of each (report type, report ID).

struct WalkedField: Equatable {
    enum Kind: Equatable { case input, output, feature }
    var kind: Kind
    var reportID: UInt8
    var usagePage: UInt32
    var usages: [UInt32]
    var usageMinimum: UInt32?
    var usageMaximum: UInt32?
    var reportSize: UInt32
    var reportCount: UInt32
    var logicalMinimum: Int64
    var logicalMaximum: Int64
    var flags: UInt32

    var bits: UInt32 { reportSize * reportCount }
    var isConstant: Bool { flags & 1 != 0 }
    var isVariable: Bool { flags & 2 != 0 }
    var isRelative: Bool { flags & 4 != 0 }
}

struct WalkResult {
    var fields: [WalkedField] = []
    var maxDepth = 0
    var finalDepth = 0
    var usesReportIDs = false
    /// A main item appeared before any Report ID in a descriptor that uses report IDs.
    var mainItemWithoutIDInIDDescriptor = false
    var errors: [String] = []

    func bits(_ kind: WalkedField.Kind, id: UInt8) -> UInt32 {
        fields.filter { $0.kind == kind && $0.reportID == id }.reduce(0) { $0 + $1.bits }
    }

    /// (kind, id) pairs that have at least one field.
    var reports: Set<String> {
        Set(fields.map { "\($0.kind)-\($0.reportID)" })
    }
}

enum DescriptorWalker {
    static func walk(_ bytes: [UInt8]) -> WalkResult {
        var r = WalkResult()
        var i = 0
        // Global state
        var usagePage: UInt32 = 0, logMin: Int64 = 0, logMax: Int64 = 0
        var size: UInt32 = 0, count: UInt32 = 0, reportID: UInt8 = 0
        // Local state
        var usages: [UInt32] = [], uMin: UInt32?, uMax: UInt32?
        var depth = 0
        var sawMainBeforeID = false

        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE { r.errors.append("long item at \(i)"); break }
            let size4 = [0, 1, 2, 4][Int(prefix & 0x03)]
            let type = (prefix >> 2) & 0x03
            let tag = prefix >> 4
            guard i + 1 + size4 <= bytes.count else { r.errors.append("truncated item at \(i)"); break }
            let data = Array(bytes[(i + 1)..<(i + 1 + size4)])
            i += 1 + size4
            var u: UInt32 = 0
            for (k, b) in data.enumerated() { u |= UInt32(b) << (8 * UInt32(k)) }
            let s: Int64 = {
                switch size4 {
                case 1: return Int64(Int8(bitPattern: UInt8(u)))
                case 2: return Int64(Int16(bitPattern: UInt16(u)))
                case 4: return Int64(Int32(bitPattern: u))
                default: return 0
                }
            }()

            switch (type, tag) {
            case (0, 0x8), (0, 0x9), (0, 0xB):   // Input, Output, Feature
                let kind: WalkedField.Kind = tag == 0x8 ? .input : (tag == 0x9 ? .output : .feature)
                if reportID == 0 { sawMainBeforeID = true }
                r.fields.append(WalkedField(kind: kind, reportID: reportID, usagePage: usagePage, usages: usages,
                                            usageMinimum: uMin, usageMaximum: uMax, reportSize: size,
                                            reportCount: count, logicalMinimum: logMin, logicalMaximum: logMax,
                                            flags: u))
                usages = []; uMin = nil; uMax = nil
            case (0, 0xA):                         // Collection
                depth += 1; r.maxDepth = max(r.maxDepth, depth)
                usages = []; uMin = nil; uMax = nil
            case (0, 0xC):                         // End Collection
                depth -= 1
                if depth < 0 { r.errors.append("unbalanced End Collection") }
            case (1, 0x0): usagePage = u
            case (1, 0x1): logMin = s
            case (1, 0x2): logMax = s
            case (1, 0x7): size = u
            case (1, 0x8):
                reportID = UInt8(u); r.usesReportIDs = true
                if u == 0 { r.errors.append("report ID 0 is reserved") }
            case (1, 0x9): count = u
            case (2, 0x0): usages.append(u)
            case (2, 0x1): uMin = u
            case (2, 0x2): uMax = u
            default:
                r.errors.append(String(format: "unexpected item 0x%02X", prefix))
            }
        }
        r.finalDepth = depth
        r.mainItemWithoutIDInIDDescriptor = r.usesReportIDs && sawMainBeforeID
        return r
    }
}
