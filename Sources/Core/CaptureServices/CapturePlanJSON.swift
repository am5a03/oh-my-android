import Foundation

/// A size/depth-bounded JSON syntax pass preserves duplicate-key errors before Foundation decoding.
nonisolated struct CapturePlanJSON {
    indirect enum Value {
        case object([String: Value]), array([Value]), scalar
        func object(allowed: Set<String>) throws -> [String: Value] {
            guard case .object(let fields) = self else { throw CapturePlanError.invalid("The capture plan contains an unsupported object value.") }
            guard Set(fields.keys).isSubset(of: allowed) else { throw CapturePlanError.invalid("The capture plan contains an unknown field. Ask the engineer to remove unsupported actions or update the plan.") }
            return fields
        }
    }
    private let bytes: [UInt8]
    private var offset = 0
    static func parse(_ data: Data) throws -> Value {
        guard data.count <= CapturePlan.maximumFileBytes else { throw CapturePlanError.invalid("Choose a capture plan smaller than 64 KiB.") }
        var parser = Self(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw parser.invalid }
        return result
    }
    private var invalid: CapturePlanError { .invalid("The capture plan is not valid JSON. Ask the engineer for a fresh copy.") }
    private mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
    private mutating func value(depth: Int) throws -> Value {
        guard depth <= 8 else { throw invalid }
        whitespace()
        guard offset < bytes.count else { throw invalid }
        if consume(123) {
            var fields: [String: Value] = [:]
            if consume(125) { return .object(fields) }
            repeat {
                let key = try string()
                guard fields[key] == nil else { throw CapturePlanError.invalid("The capture plan repeats a field. Ask the engineer for an unambiguous plan.") }
                guard consume(58) else { throw invalid }
                fields[key] = try value(depth: depth + 1)
                if consume(125) { return .object(fields) }
                guard consume(44) else { throw invalid }
            } while true
        }
        if consume(91) {
            var values: [Value] = []
            if consume(93) { return .array(values) }
            repeat {
                values.append(try value(depth: depth + 1))
                if consume(93) { return .array(values) }
                guard consume(44) else { throw invalid }
            } while true
        }
        if bytes[offset] == 34 { _ = try string(); return .scalar }
        let start = offset
        while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
        guard offset > start else { throw invalid }
        // Foundation validates number grammar, literals and Unicode syntax after our duplicate pass.
        guard (try? JSONSerialization.jsonObject(with: Data(bytes[start..<offset]), options: .fragmentsAllowed)) != nil else { throw invalid }
        return .scalar
    }
    private mutating func string() throws -> String {
        whitespace()
        let start = offset
        guard consume(34) else { throw invalid }
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 92 {
                guard offset < bytes.count else { throw invalid }
                offset += 1
            } else if byte == 34 {
                guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else { throw invalid }
                return result
            }
        }
        throw invalid
    }
}
