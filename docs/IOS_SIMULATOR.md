# iOS Simulator quick actions (PR2)

The platform selector switches between the existing Android panel and a separate iOS Simulator panel. Android SDK installation is **not** required to use the Simulator panel. Physical iPhones and iPads are not supported in this milestone.

## Setup and everyday workflow

Install full Xcode 26 with an iOS Simulator runtime. In **Xcode → Settings → Locations → Command Line Tools**, select that Xcode installation. The panel finds `simctl` with `/usr/bin/xcrun --find simctl` and captures its executable path for the session. **Reconnect Xcode tools** repeats discovery after changing Xcode.

1. Choose **iOS Simulator** in the platform selector, then explicitly choose a simulator. Boot a shutdown simulator with **Boot Simulator**. **Show Simulator** opens Apple's Simulator application; it does not promise to select a particular window when multiple simulators are running.
2. Choose an installed app, searching by its display name or bundle identifier. Recent choices appear first. Device and app choices are remembered per simulator UDID; returning to an unavailable simulator never falls back to another device.
3. Use **Launch**, **Restart** (Command-Shift-R), or **Stop**. They always address the selected UDID and bundle identifier, not the foreground app. App operations are serialized, and device/platform selection is locked while an operation or reset confirmation is active.
4. Enter a deep link (Command-L focuses the field), then use **Open** or **Stop selected app, then open**. The latter sends the URL without first launching the app's home screen.

Install a new app via Xcode or Apple's Simulator UI, then refresh the picker. The first version does not add a general-purpose IPA installer.

## Deep-link semantics

`simctl openurl <UDID> <URL>` hands the URL to iOS. **System routing is the only routing mode in this panel.** Selecting an app does not force a custom scheme or universal link into that app. A successful command means iOS accepted the open request, not that the selected app displayed the expected screen. Verify the destination in Simulator.

Saved links and the last ten successful open requests are grouped by app. iOS uses an `iosSimulator:` storage-key prefix, preserving existing Android link preferences even when a package and bundle ID are identical. URLs are passed as a single process argument without shell interpolation or re-encoding. Named links only fill the field; **Open** sends them.

History can be disabled or cleared. These preferences are local but **not encrypted**; do not save authentication tokens in URLs.

## Reset means Reinstall, not Android Clear Data

**Reinstall app…** supports user-installed apps only. Choose an **iOS Simulator `.app` build**, such as the output under Xcode's `Debug-iphonesimulator` directory, with the same bundle ID as the selected app. A physical-device build or IPA is not interchangeable with a Simulator build. The previous source path is remembered for convenience but revalidated every time.

Before any uninstall, the implementation:

- Captures the simulator UDID, runtime, and app identity.
- Checks bundle ID, application type, Simulator platform metadata, minimum OS, and the presence of an executable within the bundle.
- Copies the build to a private temporary directory so later changes to DerivedData or uninstalling the app cannot remove the reinstall source.
- Checks the staged executable's architectures against the simulator's architecture.
- Presents the exact app, device, source build, and destructive consequences for confirmation.
- Revalidates the target and staged build immediately before uninstalling.

Cancelling confirmation removes the staged copy without modifying the simulator. A successful reinstall removes its temporary copy. When installation fails after uninstall, the panel reports that partial failure and retains the staged build with **Show recovery build in Finder**. Drag the retained `.app` onto the intended Simulator or install it via Xcode, then refresh. Temporary recovery copies are not durable backups and may be removed by the OS. A crash or force quit can leave an unconfirmed staging directory in the system temporary folder.

Preflight catches common mistakes; it is not a guarantee against all install failures (for example, invalid nested frameworks or simulator service failures). There is no transactional rollback of deleted app data.

Reinstall deletes the app's local container but is **not a guaranteed brand-new-user reset**: keychain items, shared app-group containers, cloud, and server state may remain. The panel never erases an entire simulator, wipes the global keychain, or silently substitutes another reset mechanism. Test destructive actions on disposable debug data.

## Implementation boundaries

- `Core/Companion/AppControlling.swift`: minimal shared launch/action contract. Android's existing runner conforms without changing its commands. Platform-specific reset workflows remain explicit.
- `Core/Apple/SimulatorModels.swift`: stable identities, parsers for device JSON and application JSON/property lists, and the Simulator controller protocol.
- `Core/Apple/SimctlClient.swift`: commands through the existing `ShellRunning` abstraction and structured argument arrays, build staging and validation, partial-failure reporting.
- `State/SimulatorStore.swift`: persisted selection, race-resistant refresh, serial operations, captured reset confirmations, namespaced links.
- `UI/SimulatorPanelView.swift`: capability-specific interface. Android settings, inspectors, and its emulator-window docking are not used while this panel is selected. iOS auto-docking is deferred.

Simulator discovery/app lists refresh when the panel receives attention or the user requests a refresh, not through a new permanent polling loop. The existing Android MCP protocol and Android settings remain unchanged. This PR does not expose iOS operations through MCP.

## Verification

Run the mock-based tests with Swift 6/Xcode 26:

```sh
bash Scripts/test-simulator.sh
bash Scripts/test-quick-actions.sh
xcodegen generate
xcodebuild -project OhMyAndroid.xcodeproj -scheme OhMyAndroid -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
```

The new test suite covers JSON/OpenStep/XML parsing, explicit target addressing, no fallback, stale reads, same-device refresh stability, process ordering, quoted/encoded URLs, Xcode setup failure, opt-out history, and reinstall validation/recovery. Tests exercise the actual Foundation/Observation implementation with a fake process boundary; they do not certify real `simctl` behavior or visual layout.

### Manual acceptance checklist

- Open the Simulator panel without an Android SDK and confirm that it remains usable.
- Check missing Xcode/runtime help, reconnect tools, and boot a shutdown simulator.
- Run two simulators; select a test app, move it into the background, and verify launch/restart/stop still target the selected app on the selected device.
- Shut down or delete the chosen simulator; no action should target the other one. Reopen the companion and verify remembered device/app selection.
- Check custom schemes and HTTPS links with query parameters. Confirm system routing is clearly explained, saved links load without sending, and failed opens do not enter successful history.
- Refresh while a URL is entered; the field should stay intact. Switch to a different app/device; the editor should reset.
- Try an IPA, wrong bundle ID, device-only build, newer minimum OS, and wrong architecture. No uninstall should happen.
- Cancel a valid reinstall confirmation. Confirm the installed app and data remain untouched.
- On disposable data, confirm a valid reinstall and then the reinstall-and-launch variant. Verify local container reset without claiming keychain/server reset.
- Force an install failure only on disposable data; verify the recovery copy and truthful partial-failure message.
- Switch back to Android and rerun PR1's selected-app/clear-data/deep-link smoke tests. Check platform switching and Android-only menu/drop actions cannot execute against an inactive Android target while viewing iOS.
