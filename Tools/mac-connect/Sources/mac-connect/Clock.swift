import Foundation

/// Wall-clock timestamps (`HH:mm:ss.SSS`, local time) so Mac and iPhone logs can be lined up.
enum Clock {
    static func wall(_ t: Double = Date().timeIntervalSince1970) -> String {
        var secs = time_t(t)
        var parts = tm()
        localtime_r(&secs, &parts)
        let ms = min(999, Int((t - floor(t)) * 1000))
        return String(format: "%02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min, parts.tm_sec, ms)
    }

    /// Converts a mach absolute time (as in `IOHIDValueGetTimeStamp`) to seconds since 1970.
    static func epoch(machTime: UInt64) -> Double {
        epochOffset + Double(machTime) * machTicksToSeconds
    }

    private static let machTicksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static let epochOffset: Double = {
        Date().timeIntervalSince1970 - Double(mach_absolute_time()) * machTicksToSeconds
    }()
}

/// Prints one line prefixed with the wall-clock time. stdout is unbuffered (set in main).
func emit(_ line: String, at t: Double = Date().timeIntervalSince1970) {
    print("[\(Clock.wall(t))] \(line)")
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}
