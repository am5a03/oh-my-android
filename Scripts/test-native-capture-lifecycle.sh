#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/NativeCaptureLifecycle" "$work/Tests/NativeCaptureLifecycleTests"
cp Sources/Core/Support.swift Sources/Core/Shell/ShellRunner.swift Sources/Core/CaptureModels.swift \
  Sources/Core/Capture/*.swift Sources/Core/CaptureServices/*.swift Sources/Core/CaptureLifecycle/*.swift "$work/Sources/NativeCaptureLifecycle/"
cp Tests/NativeCaptureLifecycleTests.swift "$work/Tests/NativeCaptureLifecycleTests/"
cp Tests/CaptureSaveCoordinatorTests.swift "$work/Tests/NativeCaptureLifecycleTests/"
cp Tests/CaptureLogWorkerTests.swift "$work/Tests/NativeCaptureLifecycleTests/"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$work"/Sources/NativeCaptureLifecycle/*.swift Sources/CaptureHost/MobileCaptureHostMain.swift -o "$work/mobile-capture-host"
cat > "$work/fixture-tool.swift" <<'SWIFT'
import Darwin
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let kind = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let arguments = Array(CommandLine.arguments.dropFirst())
func emit(_ value: Any) { FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: value)); FileHandle.standardOutput.write(Data([10])) }
func text(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
func readJSON(_ name: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as? [String: Any]) ?? [:] }
func writeJSON(_ value: [String: Any], _ name: String) { try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: root.appendingPathComponent(name), options: .atomic) }
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2) }
func words(_ command: String) -> [String] {
    var result: [String] = [], word = "", quoted = false, escaped = false, present = false
    for character in command {
        if escaped { word.append(character); escaped = false; present = true }
        else if character == "\\", !quoted { escaped = true }
        else if character == "'" { quoted.toggle(); present = true }
        else if character.isWhitespace, !quoted { if present { result.append(word); word = ""; present = false } }
        else { word.append(character); present = true }
    }
    if present { result.append(word) }
    return result
}
func waitWithSignal(_ finished: @escaping @Sendable () -> Void) -> Never {
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { finished(); exit(0) }; source.activate(); return source
    }
    while true { _ = withExtendedLifetime(sources) { usleep(100_000) } }
}
if kind == "adb" {
    if arguments == ["devices", "-l"] { text("List of devices attached\nfixture-device device model:Fixture_Phone"); exit(0) }
    guard arguments.prefix(2) == ["-s", "fixture-device"] else { fail("Unexpected device selection") }
    let args = Array(arguments.dropFirst(2))
    if args == ["get-state"] { text("device"); exit(0) }
    if args.first == "push", args.count == 3 {
        let source = URL(fileURLWithPath: args[1])
        let bytes = try! Data(contentsOf: source)
        try! bytes.write(to: root.appendingPathComponent("transferred-ca.crt"))
        writeJSON(["destination": args[2]], "certificate-transfer.json")
        text("1 file pushed"); exit(0)
    }
    if let mode = readJSON("faults.json")["app_scope_mode"] as? String {
        let package = "codePath=/data/app/verified\nfirstInstallTime=2026-01-01 00:00:00\nlastUpdateTime=2026-01-01 00:00:00"
        if args == ["shell", "am", "get-current-user"] { text("0"); exit(0) }
        if args.prefix(4) == ["shell", "pm", "list", "packages"] { text("package:dev.mobilecapture.fixture uid:10123"); exit(0) }
        if args == ["shell", "dumpsys", "package", "dev.mobilecapture.fixture"] { text(package); exit(0) }
        if args == ["shell", "logcat", "--help"] { text(mode == "pid" ? "logcat basic" : "logcat --uid UID"); exit(0) }
        if args.first == "logcat", args.contains("-d") { exit(0) }
        if args.count == 2, args[0] == "shell", args[1].contains("__MC_FENCE__") {
            if mode == "identity_denied" { fail("Synthetic identity metadata denied") }
            let now = Date().timeIntervalSince1970
            text("__MC_FENCE__\n\(now)\n__MC_USER__\n0\n__MC_PACKAGES__\npackage:dev.mobilecapture.fixture uid:10123\n__MC_PACKAGE__")
            text(mode == "identity_loss" && FileManager.default.fileExists(atPath: root.appendingPathComponent("app-reinstalled").path) ? package.replacingOccurrences(of: "/verified", with: "/reinstalled") : package)
            if args[1].contains("__MC_CLOCK__") {
                text("__MC_CLOCK__\n\(now)\n100.0 100.0\n\(now + 0.001)\n100\n__MC_PS__\nPID UID NAME\n41 10123 dev.mobilecapture.fixture\n52 10123 dev.mobilecapture.fixture:ads\n__MC_DETAILS__")
                for (pid, name) in [(41, "dev.mobilecapture.fixture"), (52, "dev.mobilecapture.fixture:ads")] {
                    let stat = "\(pid) (\(name)) " + (["S"] + Array(repeating: "0", count: 18) + ["1000"]).joined(separator: " ")
                    text("__MC_PID_\(pid)\n\(stat)\nUid:\t10123 10123 10123 10123\n\(name)")
                }
            }
            text("__MC_END__"); exit(0)
        }
        if args.first == "logcat" {
            let epoch = Date().timeIntervalSince1970
            text("\(epoch) 41 42 D Ads: repeated SDK debug message")
            text("SDK continuation")
            text("\(epoch) 41 42 D Ads: repeated SDK debug message")
            text("\(epoch) 52 53 V Ads: helper after process restart")
            if mode == "pid" { text("\(epoch) 99 99 I Other: must never persist") }
            if mode == "unverified_tail" { text("\(epoch + 3600) 41 42 D Ads: outside verified time fence") }
            if mode == "identity_loss" {
                usleep(700_000)
                try! Data("changed".utf8).write(to: root.appendingPathComponent("app-reinstalled"))
                text("\(Date().timeIntervalSince1970 + 3600) 41 42 D Ads: unverified after reinstall")
            }
            waitWithSignal { try! Data("logs stopped".utf8).write(to: root.appendingPathComponent("logs-stopped")) }
        }
    }
    if args.prefix(1) == ["logcat"] {
        text("\(Date().timeIntervalSince1970) 1 2 I Fixture: native device log")
        waitWithSignal { try! Data("logs stopped".utf8).write(to: root.appendingPathComponent("logs-stopped")) }
    }
    var state = readJSON("routing.json")
    var proxy = state["proxy"] as? [String: String] ?? [:]
    var reverse = state["reverse"] as? [String: String] ?? [:]
    if args.prefix(1) == ["reverse"] {
        if args == ["reverse", "--list"] { for key in reverse.keys.sorted() { text("fixture-device \(key) \(reverse[key]!)") }; exit(0) }
        if args.count == 4, args[1] == "--no-rebind" { if reverse[args[2]] != nil { fail("Already mapped") }; reverse[args[2]] = args[3] }
        else if args.count == 3, args[1] == "--remove" { reverse.removeValue(forKey: args[2]) }
        else { fail("Unexpected reverse command") }
        state["reverse"] = reverse; writeJSON(state, "routing.json"); exit(0)
    }
    if args == ["shell", "date", "+%s"] { text(String(Int(Date().timeIntervalSince1970))); exit(0) }
    guard args.first == "shell" else { fail("Unexpected ADB command") }
    let command = args.count == 2 ? words(args[1]) : Array(args.dropFirst())
    if command == ["settings", "list", "global"] { for key in proxy.keys.sorted() { text("\(key)=\(proxy[key]!)") }; exit(0) }
    guard command.count >= 4, command[0] == "settings", command[2] == "global" else { fail("Unexpected settings command") }
    let key = command[3]
    if command[1] == "delete" { proxy.removeValue(forKey: key) }
    else if command[1] == "put", command.count == 5 {
        proxy[key] = command[4]
        if key == "http_proxy", command[4] == ":0", readJSON("faults.json")["clear_ack"] as? Bool != false {
            proxy["global_http_proxy_host"] = ""; proxy["global_http_proxy_port"] = "0"
            proxy["global_http_proxy_exclusion_list"] = ""; proxy["global_proxy_pac_url"] = ""
            state["cache_cleared"] = true
            state["clear_engine_alive"] = FileManager.default.fileExists(atPath: root.appendingPathComponent("engine-running").path)
        }
    } else { fail("Unexpected settings mutation") }
    state["proxy"] = proxy; writeJSON(state, "routing.json"); exit(0)
}
if kind == "simctl" {
    if arguments == ["list", "devices", "available", "--json"] { emit(["devices": ["fixture-runtime": [["udid": "fixture-simulator", "name": "Fixture Simulator", "state": "Booted", "isAvailable": true]]]]); exit(0) }
    if arguments == ["listapps", "fixture-simulator"] { emit(["dev.mobilecapture.fixture": ["CFBundleIdentifier": "dev.mobilecapture.fixture", "CFBundleExecutable": "Fixture App"]]); exit(0) }
    if arguments.first == "spawn" {
        emit(["timestamp": Date().ISO8601Format(), "eventMessage": "native simulator log", "processImagePath": "/Fixture App"])
        waitWithSignal { try! Data("logs stopped".utf8).write(to: root.appendingPathComponent("logs-stopped")) }
    }
    if arguments.first == "keychain" { exit(0) }
    fail("Unexpected simctl command")
}
if kind == "devicectl" {
    guard arguments.prefix(2) == ["list", "devices"], let outputOption = arguments.firstIndex(of: "--json-output"),
          arguments.indices.contains(outputOption + 1) else { fail("Unexpected devicectl command") }
    let value: [String: Any] = ["result": ["devices": [[
        "identifier": "core-device-identifier-is-not-hardware-udid",
        "hardwareProperties": ["deviceType": "iPhone", "platform": "iOS", "reality": "physical", "udid": "fixture-iphone", "marketingName": "Fixture iPhone"],
        "deviceProperties": ["name": "Fixture iPhone"],
        "connectionProperties": ["pairingState": "paired", "tunnelState": "connected"]
    ]]]]
    try! JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: arguments[outputOption + 1]))
    exit(0)
}
if kind == "ideviceinfo" {
    guard arguments == ["--udid", "fixture-iphone", "--key", "TimeIntervalSince1970"] else { fail("Unexpected iPhone clock command") }
    text(String(Date().timeIntervalSince1970)); exit(0)
}
if kind == "idevicesyslog" {
    guard arguments == ["--udid", "fixture-iphone", "--exit", "--no-colors"] else { fail("Unexpected iPhone USB log selection") }
    guard ProcessInfo.processInfo.environment["TZ"] == "UTC", ProcessInfo.processInfo.environment["LC_ALL"] == "C" else { fail("iPhone log clock must use UTC and C locale") }
    text("[connected:fixture-iphone]")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "MMM dd HH:mm:ss"
    if readJSON("faults.json")["iphone_status_only"] as? Bool != true {
        text("\(formatter.string(from: Date())).123456 FixturePhone(AdsSDK)[321] <Info>: native USB iPhone request")
    }
    if readJSON("faults.json")["iphone_logs_disconnect"] as? Bool == true {
        usleep(2_000_000); text("[disconnected:fixture-iphone]")
        try! Data("disconnected".utf8).write(to: root.appendingPathComponent("logs-disconnected"))
        exit(0)
    }
    waitWithSignal { try! Data("logs stopped".utf8).write(to: root.appendingPathComponent("logs-stopped")) }
}
if kind == "mitmdump" {
    if readJSON("faults.json")["engine_start_fails"] as? Bool == true { fail("Synthetic engine startup failure") }
    let session = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAPTURE_SESSION_DIR"]!)
    let network = session.appendingPathComponent("network")
    if let modeOption = arguments.firstIndex(of: "--mode"), arguments.indices.contains(modeOption + 1), arguments[modeOption + 1].hasPrefix("wireguard:") {
        guard arguments.contains("--quiet"), let bindOption = arguments.firstIndex(of: "--listen-host"),
              arguments.indices.contains(bindOption + 1), arguments[bindOption + 1] == "0.0.0.0" else { fail("iPhone network engine must bind the reachable endpoint quietly") }
        let mode = arguments[modeOption + 1]
        guard mode.hasSuffix("@51820") else { fail("Unexpected iPhone tunnel port") }
        let keyPath = String(mode.dropFirst("wireguard:".count).dropLast("@51820".count))
        let keys = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: keyPath))) as! [String: Any]
        guard keys["server_key"] is String, keys["client_key"] is String else { fail("Missing private WireGuard keys") }
        writeJSON(["arguments": arguments, "key_path": keyPath], "iphone-network-invocation.json")
    }
    let ca = arguments.first(where: { $0.hasPrefix("confdir=") })!.dropFirst(8)
    try! Data("-----BEGIN CERTIFICATE-----\nPUBLIC FIXTURE CERTIFICATE\n-----END CERTIFICATE-----\n".utf8).write(to: URL(fileURLWithPath: String(ca)).appendingPathComponent("mitmproxy-ca-cert.pem"))
    try! Data([0, 1, 2, 255]).write(to: network.appendingPathComponent("capture.mitm"))
    try! Data(#"{"log":{"entries":[]}}"#.utf8).write(to: network.appendingPathComponent("capture.har"))
    try! Data(#"{"flow_ids":[],"count":0,"missing_bodies":[]}"#.utf8).write(to: network.appendingPathComponent("incomplete.json"))
    let now = Date().ISO8601Format()
    let events: [[String: Any]] = [
        ["timestamp": now, "kind": "request", "summary": "POST https://example.invalid/fixture", "detail": ["flow_id": "fixture-flow", "request_body": ["text": "full request"]]],
        ["timestamp": now, "kind": "response", "summary": "200 POST https://example.invalid/fixture", "detail": ["flow_id": "fixture-flow", "response_body": ["text": "full response"]]]]
    var bytes = Data(); for event in events { bytes.append(try! JSONSerialization.data(withJSONObject: event)); bytes.append(10) }
    try! bytes.write(to: network.appendingPathComponent("events.jsonl"))
    try! Data("running".utf8).write(to: root.appendingPathComponent("engine-running"))
    try! Data("{}".utf8).write(to: network.appendingPathComponent("ready.json"))
    if readJSON("faults.json")["engine_ignore_stop"] as? Bool == true {
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        while true { usleep(100_000) }
    }
    waitWithSignal {
        try! Data("flushed".utf8).write(to: root.appendingPathComponent("engine-stopped"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("engine-running"))
    }
}
if kind == "mobile-capture-proxy" {
    let defaults: [String: Any] = ["service_id": "fixture-service", "service_name": "Fixture Wi-Fi", "enabled": false, "configuration_present": false, "configuration": [:]]
    let state = readJSON("mac-proxy.json")
    if arguments == ["snapshot", "Fixture Wi-Fi"] { emit(state.isEmpty ? defaults : state); exit(0) }
    let journal = try! JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
    if arguments == ["apply"] {
        if readJSON("faults.json")["apply_denied"] as? Bool == true { fail("Synthetic apply denied") }
        writeJSON(journal["applied"] as! [String: Any], "mac-proxy.json"); emit(["applied": true]); exit(0)
    }
    if arguments == ["restore"] {
        writeJSON(["invoked": true], "restore-invoked.json")
        if readJSON("faults.json")["restore_fails"] as? Bool == true { fail("Synthetic restore blocked") }
        let original = journal["before"] as! [String: Any]
        let applied = journal["applied"] as! [String: Any]
        let current = readJSON("mac-proxy.json")
        var config = current["configuration"] as! [String: Any]
        let beforeConfig = original["configuration"] as! [String: Any]
        let appliedConfig = applied["configuration"] as! [String: Any]
        for key in ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort"] {
            let value = config[key] as? NSObject
            guard value == appliedConfig[key] as? NSObject || value == beforeConfig[key] as? NSObject else { fail("Externally changed proxy preserved") }
            config[key] = beforeConfig[key]
        }
        var restored = original; restored["configuration"] = config
        if !NSDictionary(dictionary: config).isEqual(to: beforeConfig) { restored["configuration_present"] = true }
        writeJSON(restored, "mac-proxy.json")
        writeJSON(["engine_alive": FileManager.default.fileExists(atPath: root.appendingPathComponent("engine-running").path)], "restore-result.json")
        emit(["restored": true]); exit(0)
    }
    fail("Unexpected proxy helper command")
}
if kind == "legacy-controller" {
    let directory = URL(fileURLWithPath: arguments[0])
    let controlURL = directory.appendingPathComponent("runtime/control.json")
    let control = try! JSONSerialization.jsonObject(with: Data(contentsOf: controlURL)) as! [String: String]
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
        _ = control["socket"]!.withCString { strlcpy(bytes, $0, capacity) }
    } }
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard bound == 0, chmod(control["socket"]!, 0o600) == 0, listen(descriptor, 4) == 0 else { fail("Cannot bind legacy fixture socket") }
    defer { close(descriptor); unlink(control["socket"]!) }
    while true {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { fail("Legacy fixture accept failed") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while !data.contains(10), data.count < 8192 {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        let message = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        if message["token"] != control["token"] {
            _ = "{\"error\":\"Unauthorized session control\"}\n".withCString { send(client, $0, strlen($0), 0) }; close(client); continue
        }
        if message["action"] == "stop" {
            let stateURL = directory.appendingPathComponent("session.json")
            var state = try! JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            state["phase"] = "saved"; state["routing_restored"] = true; state["package_path"] = directory.appendingPathComponent("capture-package.zip").path
            try! JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
        }
        _ = "{\"ok\":true}\n".withCString { send(client, $0, strlen($0), 0) }; close(client)
        if message["action"] == "stop" { exit(0) }
    }
}
fail("Unexpected fixture executable")
SWIFT
swiftc -swift-version 6 -warnings-as-errors "$work/fixture-tool.swift" -o "$work/fixture-tool"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "NativeCaptureLifecycle", platforms: [.macOS(.v26)], targets: [
    .target(name: "NativeCaptureLifecycle", linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "NativeCaptureLifecycleTests", dependencies: ["NativeCaptureLifecycle"])
])
SWIFT
# These paths point only to compiled synthetic tools; no connected devices or real proxies.
CAPTURE_TEST_HOST="$work/mobile-capture-host" CAPTURE_TEST_TOOL="$work/fixture-tool" \
  swift test --package-path "$work" --scratch-path "$work/build" --disable-sandbox "$@"
