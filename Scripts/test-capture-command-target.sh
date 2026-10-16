#!/bin/bash
set -euo pipefail
repoRoot=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/capture-command-target.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CaptureCommandTargetKit" "$work/Tests/CaptureCommandTargetKitTests"
cp "$repoRoot/Sources/UI/CaptureCommands.swift" "$work/Sources/CaptureCommandTargetKit/"
cp "$repoRoot/Tests/CaptureCommandTargetTests.swift" "$work/Tests/CaptureCommandTargetKitTests/"
# The bridge tests require store identity only. Stub the collection-facing API so tests cannot start
# capture processes or change device/host routing, and can compile independently of runtime migration.
cat > "$work/Sources/CaptureCommandTargetKit/CaptureStore.swift" <<'SWIFT'
import Observation
@MainActor @Observable final class CaptureStore {
    var isBusy = false
    var hasActiveCapture = false
    var canStart = false
    var hasSetupReport = false
    let doctor = CaptureDoctorStore()
    var isDoctorPresented = false
    var isLoadingTimeline = false
    var isViewPaused = false
    var followLatest = true
    var wrapLines = false
    var hiddenThroughSequence: Int64?
    var hasOlderEvents = false
    var hasNewerEvents = false
    var session: CaptureSession?
    var operationSession: CaptureSession? { session }
    var isOperationBusy: Bool { isBusy }
    func openSession() async {}
    func start() async {}
    func stop() async {}
    func exportPackage() {}
    func revealPackage() {}
    func revealCaptureCertificate() {}
    func showSetup() {}
    func showDoctor() { isDoctorPresented = true }
    func exportSetupReport() async {}
    func togglePauseView() async { isViewPaused.toggle() }
    func setFollowLatest(_ value: Bool) async { followLatest = value }
    func jumpToLatest() async {}
    func clearView() async {}
    func showFullSession() async {}
    func loadOlderEvents() async {}
    func loadNewerEvents() async {}
}
struct CaptureSession {
    var isActive = false
    var canFinalize = false
    var needsRoutingRecovery = false
    var needsPackageRetry = false
    var packagePath: String?
    var caCertificatePath: String?
}
@MainActor final class CaptureDoctorStore { var isRepairing = false }
SWIFT
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CaptureCommandTargetTests", platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CaptureCommandTargetKit", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .testTarget(name: "CaptureCommandTargetKitTests", dependencies: ["CaptureCommandTargetKit"],
                    swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
    ]
)
SWIFT
CLANG_MODULE_CACHE_PATH="$work/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$work/module-cache" \
    swift test --package-path "$work" --scratch-path "$work/build" --cache-path "$work/cache" --disable-sandbox
