import CoreFoundation
import Foundation

/// Shared admission checks for observed coverage; stored raw bodies are never changed.
nonisolated enum CaptureBodyEvidence {
    static func isAvailable(_ value: Any?) -> Bool {
        guard let body = value as? [String: Any], body["unavailable"] as? Bool != true,
              body["truncated"] as? Bool != true, body["reason"] == nil,
              let text = body["text"] as? String, let number = body["bytes"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), let count = body["bytes"] as? Int, count >= 0,
              let encoding = body["encoding"] as? String else { return false }
        if encoding == "utf-8" { return text.utf8.count == count }
        if encoding == "base64", let data = Data(base64Encoded: text) { return data.count == count }
        return false
    }

    static func isSetupProbe(_ detail: [String: Any]) -> Bool {
        if detail["setup_probe"] as? Bool == true { return true }
        guard let text = detail["url"] as? String, let url = URLComponents(string: text) else { return false }
        return url.host?.lowercased() == "mitm.it" && url.path.hasPrefix("/mobile-capture-check/")
    }

    static func isCompleteHTTPSResponse(kind: String, detail: [String: Any]) -> Bool {
        guard kind == "response", let text = detail["url"] as? String,
              let url = URLComponents(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              let status = detail["status"] as? Int, (200...599).contains(status) else { return false }
        return isAvailable(detail["request_body"]) && isAvailable(detail["response_body"])
    }
}
