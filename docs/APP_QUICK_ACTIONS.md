# Selected-app quick actions (PR1)

Android-only first milestone. iOS Simulator and physical iPhone adapters are intentionally not included.

## Daily workflow

Choose a device, then use **Selected app** above the existing grid. Search by package identifier or a locally assigned friendly name. Recent selections appear first. Selection is remembered per device and Android user. AVD names, when available, are used instead of reusable emulator ports. **Use foreground** is a one-time selection shortcut, not a mode that follows whichever app is on screen.

App names are optional local aliases. This version does not download APKs or install a helper to discover localized Android application labels. System packages are hidden by default; **Show system apps** exposes them. Only the current Android user is inventoried; this is not a work-profile/user-switching UI.

- **Launch** starts the selected package's launcher activity.
- **Restart** stops it, then starts its launcher; it does not clear data.
- **Clear... > Clear data** deletes that app's local data for the captured Android user and leaves it stopped.
- **Clear... > Clear data and launch** clears it and then launches it. A launch failure after a successful clear is reported as partial completion, not as a rollback.

All destructive actions confirm the app identifier, device and Android user. Existing confirmation-suppression preferences do not bypass the new confirmations. Remaining App grid controls (Force stop, App info, Uninstall, Permissions) use the same selected target; Permissions revokes granted runtime permissions, excluding policy/system-fixed permissions. It does not use a global permission reset. The read-only Data Inspector and APK installer retain their existing workflows.

A disconnected selected device remains selected and offline, even when another phone is ready. Choose another target explicitly. Each operation revalidates the device identity, current Android user and exact installed package. An operation already accepted keeps its captured target; it never retargets itself to a newly selected app/device.

## Deep links

Paste a full URI. **Open** (or Return in the field) delivers it directly. Open's menu offers **Stop app, then open**, which stops the selected app and sends the link without first launching its home screen. This does not erase data.

**Selected app** adds a package restriction. **System routing** lets Android resolve the URL normally (which may open a browser or a chooser). This is not proof that a domain association is verified. In System routing, Stop app first still stops only the selected app, not whatever other handler Android ultimately chooses.

**Saved...** stores named links per package, including their routing mode. Saving the same URL and mode updates its name. Choosing a saved/recent item fills the field; Open sends it. Recent history contains up to ten successful opens per app and can be disabled or cleared. Failed opens are not recorded as successful.

Shortcuts are panel-local: **Command-L** focuses the URI field, **Command-Shift-R** restarts the selected app. Destructive operations have no unconfirmed shortcut.

Preferences are local and **not encrypted**. Do not save links containing credentials, one-time login tokens or other sensitive values. Disable/clear history when testing such URLs. URLs are shell-quoted without rewriting their queries or escaping.

## Implementation boundaries

`Core/Android/AppTarget.swift` holds immutable target and input models. `AppCommandRunner.swift` owns validated, user-scoped command sequences behind injected I/O. The `Features/AppQuickActions.swift` adapter delegates to the existing `ADBClient`/`ShellRunning` infrastructure; no new process launcher or dependency is introduced.

`AppSelectionStore` owns inventory, persistence, stale-response rejection, confirmation snapshots and operation serialization. `DeepLinkStore` owns saved/recent URLs. SwiftUI calls these stores, not ADB directly. Existing foreground-based feature implementations remain unchanged for MCP compatibility; desktop `FeatureCell` routes its app controls through the selected-app store instead.

## Automated checks

Run `bash Scripts/test-quick-actions.sh` with Swift 6. The standalone mock-based suite compiles the actual Foundation/Observation sources with warnings as errors; no Android device or package download is required. CI runs it before the existing macOS app build and MCP protocol check.

The suite covers command scoping and ordering, quoting, device disconnection/AVD identity, user changes, missing packages, failure/partial-completion reporting, stale asynchronous inventory, confirmation invalidation, duplicate-operation locking, selection/alias persistence, and saved/recent link storage. It is not an emulator, hardware or SwiftUI integration test.

## Manual validation before merging

1. Build using the existing CONTRIBUTING instructions on macOS 26/Xcode 26. Verify the compact panel, scrolling, app picker and link popovers at the default panel size. For a fork-specific build, avoid applying upstream in-app updates while testing.
2. Using disposable debug builds, connect two Android targets. Choose app A on target A, move the phone to Settings, then restart and clear app A. Check that Settings, app B and target B are unchanged. Confirm both clear variants and cancellation.
3. Disconnect target A while target B stays online: A remains selected/offline, and no commands are sent to B. Reconnect A and confirm restoration. Repeat after restarting the Mac app; switch AVD ports where possible.
4. Switch the Android user, uninstall the selected package externally, and test a package without a launcher. Expect an explicit disabled state/error rather than a fallback or false success.
5. Try a registered custom scheme, an HTTPS link, a missing handler, and a URL containing multiple query parameters, an apostrophe and percent-encoding. Compare Selected app/System routing and stopped/running-app delivery.
6. Save, rename, delete and reopen presets; restart the Mac app. Check per-app history isolation, the ten-entry limit, history disable/clear, Command-L and Command-Shift-R.
7. Scroll down to Uninstall/Permissions: confirm the selected target is named even when the Quick Actions section is offscreen. Verify existing appearance, capture, install, inspectors and MCP protocol behaviour still work.
