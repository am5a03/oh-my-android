import CryptoKit
import Foundation

/// Mirrors evidence.py schema 1. No device, subprocess, routing or export policy belongs here.
enum NativeTimelineNormalizer {
    static let sources = [("logs", "logs/device.log"), ("network", "network/events.jsonl"), ("marker", "timeline/markers.jsonl")]
    // These compile-time literals are validated by parity tests; invalid patterns are programmer errors.
    private static let logPattern = try! NSRegularExpression(pattern: #"^[ \t]*(\d{9,}(?:\.\d{1,9})?)\s+(\d+)\s+(\d+)\s+([VDIWEFAS])\s+(.*?):\s?(.*)$"#)
    private static let isoPattern = try! NSRegularExpression(pattern: #"^(\d{4})-?(\d{2})-?(\d{2})[Tt ](\d{2}):?(\d{2})(?::?(\d{2}))?(?:[.,](\d+))?(Z|[+-]\d{2}(?::?\d{2})?(?::?\d{2}(?:[.,]\d+)?)?)$"#)

    static func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func normalize(source: String, path: String, line: Int64, raw: Data, state: [String: Any], iPhoneSessionStartedAt: Date? = nil, incompleteTail: Bool = false) throws -> [String: Any] {
        func iPhoneLogValue() -> [String: Any]? {
            if let iPhoneSessionStartedAt { return IPhoneLogFormat.parse(raw, sessionStartedAt: iPhoneSessionStartedAt) }
            return IPhoneLogFormat.parse(raw, sessionStartedAt: state["started_at"] as? String ?? "")
        }
        let value: [String: Any]
        if source == "logs", state["platform"] as? String == "iphone", IPhoneLogFormat.isStatusLine(raw) {
            value = ["kind": "collector_status", "summary": String(decoding: raw, as: UTF8.self),
                "detail": ["format": "iphone_collector_status", "message": "USB collector connection status; not an observed device log"]]
        } else if source == "logs", state["platform"] as? String == "iphone",
           let parsed = iPhoneLogValue() {
            value = parsed
        } else {
            value = source == "logs" ? logValue(raw) : jsonValue(raw, source: source)
        }
        let rawTime = value["timestamp"] ?? value["time"] ?? value["timestamp_start"]
        let original = value["original_timestamp"] ?? rawTime
        var parsed = timestamp(rawTime)
        let received = timestamp(value["received_at"])
        let calibration = ((state["clock_calibration"] as? [String: Any])?[source] as? [String: Any]) ?? [:]
        let offset = number(calibration["offset_ms"])
        let eventUncertainty = number(value["clock_uncertainty_ms"])
        var uncertainty = number(calibration["uncertainty_ms"]) ?? eventUncertainty
        if let amount = uncertainty, amount < 0 { uncertainty = nil }
        var calibrated = parsed != nil && (offset != nil || eventUncertainty != nil)
        var detail = value["detail"] as? [String: Any] ?? [:]
        let basis: String
        if let date = parsed {
            basis = "source_timestamp"
            if let offset {
                let delta = (offset * 1_000).rounded(.toNearestOrEven)
                guard delta.isFinite, delta > Double(Int64.min), delta < Double(Int64.max) else {
                    throw NativeTimelineError.message("Clock calibration offset is outside the supported timestamp range.")
                }
                let (adjusted, overflow) = date.addingReportingOverflow(Int64(delta))
                guard !overflow, (-62_135_596_800_000_000...253_402_300_799_999_999).contains(adjusted) else {
                    throw NativeTimelineError.message("Clock calibration produced a timestamp outside years 1–9999.")
                }
                parsed = adjusted
            }
        } else if let received {
            parsed = received; basis = "received_at_fallback"; uncertainty = nil; calibrated = false
        } else {
            parsed = timestamp(state["started_at"]) ?? 0
            basis = parsed == 0 ? "unavailable_epoch_sentinel" : "session_start_fallback"
            uncertainty = nil; calibrated = false
        }
        if incompleteTail {
            detail["incomplete"] = true
            detail["incomplete_reason"] = "The collector stopped after retaining part of the final raw record; its admitted bytes are preserved."
        }
        detail["clock_calibrated"] = calibrated
        detail["timestamp_basis"] = basis
        detail["temporal_matching"] = "inferred"
        if let offset { detail["clock_offset_ms"] = offset }
        if let method = calibration["method"], truthy(method) { detail["clock_method"] = string(method) }
        if let native = value["raw_ref"], truthy(native) { detail["native_ref"] = native }
        if let id = value["id"], truthy(id) { detail["source_event_id"] = id }
        var identity = Data("\(source)\0\(path)\0\(line)\0".utf8)
        identity.append(raw)
        let digest = hex(SHA256.hash(data: identity).prefix(12))
        return ["id": "event-" + digest, "timestamp": iso(parsed ?? 0),
                "original_timestamp": original.flatMap { $0 is NSNull ? nil : string($0) } as Any? ?? NSNull(),
                "received_at": received.map(iso) as Any? ?? NSNull(), "source": source,
                "kind": string(value["kind"] ?? (source == "logs" ? "log" : source)),
                "summary": string(value["summary"] ?? ""), "raw_ref": "\(path)#L\(line)",
                "detail": detail, "clock_uncertainty_ms": uncertainty as Any? ?? NSNull()]
    }

    static func logValue(_ raw: Data) -> [String: Any] {
        let text = String(decoding: raw, as: UTF8.self)
        if let match = logPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            func group(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
            let tag = group(5).trimmingCharacters(in: .whitespacesAndNewlines)
            return ["timestamp": group(1), "kind": "log", "summary": "\(tag): \(group(6))",
                    "detail": ["format": "android_logcat_epoch", "pid": Int64(group(2)) ?? 0, "tid": Int64(group(3)) ?? 0,
                               "level": group(4), "tag": tag, "message": group(6)]]
        }
        if let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return ["timestamp": value["timestamp"] ?? value["date"] ?? NSNull(), "received_at": value["received_at"] ?? NSNull(),
                    "kind": "log", "summary": string(value["eventMessage"] ?? value["message"] ?? value["summary"] ?? text),
                    "detail": ["format": "simulator_ndjson", "log": value]]
        }
        return ["kind": "unparsed_log", "summary": text, "detail": ["format": "unparsed", "parse_error": "No supported timestamped log format"]]
    }

    static func jsonValue(_ raw: Data, source: String) -> [String: Any] {
        guard var value = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            // Parser-specific error wording is diagnostic, not an event identity or source-byte transformation.
            return ["kind": "parse_error", "summary": "Unparsed \(source) event", "detail": ["parse_error": "Expected a valid UTF-8 JSON object"]]
        }
        if source == "marker" {
            if value["summary"] == nil { value["summary"] = value["text"] ?? "Marker" }
            if value["kind"] == nil { value["kind"] = "marker" }
        } else {
            let request = value["request"] as? [String: Any] ?? [:]
            let response = value["response"] as? [String: Any] ?? [:]
            var detail = value["detail"] as? [String: Any] ?? [:]
            if let original = value["detail"], !(original is [String: Any]) { detail["original_detail"] = original }
            for (key, fallback) in [("method", request["method"]), ("url", request["url"]),
                                     ("status", response["status"] ?? response["status_code"]), ("flow_id", value["flow_id"])] {
                if let candidate = value[key] ?? fallback, !(candidate is NSNull), detail[key] == nil { detail[key] = candidate }
            }
            if value["summary"] == nil {
                let summary = ["status", "method", "url"].compactMap { detail[$0].flatMap { $0 is NSNull ? nil : string($0) } }.joined(separator: " ")
                value["summary"] = summary.isEmpty ? "Network event" : summary
            }
            if value["kind"] == nil { value["kind"] = !response.isEmpty ? "response" : !request.isEmpty ? "request" : "network" }
            value["detail"] = detail
        }
        return value
    }

    static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        for byte in bytes { result.append(digits[Int(byte >> 4)]); result.append(digits[Int(byte & 15)]) }
        return String(decoding: result, as: UTF8.self)
    }

    static func string(_ value: Any) -> String {
        if value is NSNull { return "None" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "True" : "False" }
            let type = String(cString: number.objCType)
            return type == "d" || type == "f" ? String(number.doubleValue) : number.stringValue
        }
        return String(describing: value)
    }

    private static func truthy(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let text = value as? String { return !text.isEmpty }
        if let values = value as? [Any] { return !values.isEmpty }
        if let values = value as? [String: Any] { return !values.isEmpty }
        return true
    }

    /// Integer microseconds preserve Python's six-digit schema timestamps and avoid formatter precision loss.
    static func timestamp(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return epoch(number.doubleValue)
        }
        guard let original = value as? String else { return nil }
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil, let number = Double(text) { return epoch(number) }
        guard let match = isoPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        let year = Int(group(1)) ?? 0, month = Int(group(2)) ?? 0, day = Int(group(3)) ?? 0
        let hour = Int(group(4)) ?? 0, minute = Int(group(5)) ?? 0, second = Int(group(6)) ?? 0
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...9999).contains(year), (1...12).contains(month), (1...lengths[month - 1]).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }
        let fraction = Int64((group(7) + "000000").prefix(6)) ?? 0
        let zone = group(8)
        var zoneMicros: Int64 = 0
        if zone != "Z" {
            let sign: Int64 = zone.hasPrefix("-") ? -1 : 1
            let digits = String(zone.dropFirst()).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: ",", with: ".")
            let whole = String(digits.split(separator: ".", omittingEmptySubsequences: false)[0])
            guard whole.count == 2 || whole.count == 4 || whole.count == 6 else { return nil }
            let zh = Int(whole.prefix(2)) ?? 99
            let zm = whole.count >= 4 ? Int(whole.dropFirst(2).prefix(2)) ?? 99 : 0
            let zs = whole.count >= 6 ? Int(whole.dropFirst(4)) ?? 99 : 0
            guard zh < 24, zm < 60, zs < 60 else { return nil }
            let subseconds = digits.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
            zoneMicros = sign * (Int64(zh * 3600 + zm * 60 + zs) * 1_000_000 + (Int64((subseconds + "000000").prefix(6)) ?? 0))
        }
        let result = (days(year, month, day) * 86_400 + Int64(hour * 3600 + minute * 60 + second)) * 1_000_000 + fraction - zoneMicros
        return (-62_135_596_800_000_000...253_402_300_799_999_999).contains(result) ? result : nil
    }

    private static func epoch(_ value: Double) -> Int64? {
        guard value.isFinite, value >= -62_135_596_800, value < 253_402_300_800 else { return nil }
        let seconds = floor(value)
        let result = Int64(seconds) * 1_000_000 + Int64(((value - seconds) * 1_000_000).rounded(.toNearestOrEven))
        return (-62_135_596_800_000_000...253_402_300_799_999_999).contains(result) ? result : nil
    }

    private static func days(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400, yo = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        return Int64(era * 146_097 + yo * 365 + yo / 4 - yo / 100 + doy - 719_468)
    }

    static func iso(_ micros: Int64) -> String {
        var seconds = micros / 1_000_000, fraction = micros % 1_000_000
        if fraction < 0 { seconds -= 1; fraction += 1_000_000 }
        var day = seconds / 86_400, time = seconds % 86_400
        if time < 0 { day -= 1; time += 86_400 }
        let z = day + 719_468, era = (z >= 0 ? z : z - 146_096) / 146_097, doe = z - era * 146_097
        let yo = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        var year = yo + era * 400
        let doy = doe - (365 * yo + yo / 4 - yo / 100), mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1, m = mp + (mp < 10 ? 3 : -9)
        year += m <= 2 ? 1 : 0
        return String(format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%06lldZ", year, m, d, time / 3600, time / 60 % 60, time % 60, fraction)
    }
}
