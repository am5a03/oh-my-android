import Foundation

/// Parses idevicesyslog output launched with TZ=UTC and LC_ALL=C.
/// The raw evidence remains authoritative: the tool omits the year and time zone.
enum IPhoneLogFormat {
    private static let pattern = try! NSRegularExpression(pattern: #"^((Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,6}))?) (.+)\[([0-9]+)\] <([^>\r\n]+)>: ?([^\r\n]*)(?:\r?\n)?$"#)
    private static let statusPattern = try! NSRegularExpression(pattern: #"^\[(?:connected|disconnected):[^\]\r\n]+\](?:\r?\n)?$"#)
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Connection notices prove the transport started, not that a device log was observed.
    static func isStatusLine(_ raw: Data) -> Bool {
        guard let text = String(data: raw, encoding: .utf8) else { return false }
        return statusPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func parse(_ raw: Data, sessionStartedAt: String) -> [String: Any]? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        guard let anchor = (try? fractional.parse(sessionStartedAt)) ?? (try? whole.parse(sessionStartedAt)) else { return nil }
        return parse(raw, sessionStartedAt: anchor)
    }

    /// A pre-parsed session date avoids repeatedly parsing session metadata during ingestion.
    static func parse(_ raw: Data, sessionStartedAt: Date) -> [String: Any]? {
        guard let text = String(data: raw, encoding: .utf8),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        guard let monthIndex = months.firstIndex(of: group(2)), let day = Int(group(3)),
              let hour = Int(group(4)), hour < 24, let minute = Int(group(5)), minute < 60,
              let second = Int(group(6)), second < 60, let pid = Int64(group(9)) else { return nil }
        let month = monthIndex + 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchorYear = calendar.component(.year, from: sessionStartedAt)
        let candidates = (-1...1).compactMap { delta -> (year: Int, date: Date)? in
            let year = anchorYear + delta
            guard (1...9999).contains(year), let date = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                                                        hour: hour, minute: minute, second: second)) else { return nil }
            // Calendar normalizes impossible dates; reject them instead of manufacturing a timestamp.
            let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            guard checked.year == year, checked.month == month, checked.day == day,
                  checked.hour == hour, checked.minute == minute, checked.second == second else { return nil }
            return (year, date)
        }
        guard let selected = candidates.min(by: { abs($0.date.timeIntervalSince(sessionStartedAt)) < abs($1.date.timeIntervalSince(sessionStartedAt)) }) else { return nil }
        let fraction = group(7)
        let timestamp = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", selected.year, month, day, hour, minute, second)
            + (fraction.isEmpty ? "" : "." + fraction) + "Z"
        let processAndImage = group(8)
        let process: String
        let image: String?
        if processAndImage.hasSuffix(")"), let open = processAndImage.lastIndex(of: "("), open != processAndImage.startIndex {
            process = String(processAndImage[..<open])
            image = String(processAndImage[processAndImage.index(after: open)..<processAndImage.index(before: processAndImage.endIndex)])
        } else {
            process = processAndImage
            image = nil
        }
        var detail: [String: Any] = ["format": "iphone_idevicesyslog_utc", "pid": pid, "process": process,
                                    "level": group(10), "message": group(11), "raw_line": text,
                                    "timestamp_zone": "UTC", "timestamp_year": selected.year,
                                    "timestamp_year_basis": "nearest_session_start", "timestamp_fraction_digits": fraction.count]
        if let image { detail["image"] = image }
        return ["timestamp": timestamp, "original_timestamp": group(1), "kind": "log",
                "summary": "\(process): \(group(11))", "detail": detail]
    }
}
