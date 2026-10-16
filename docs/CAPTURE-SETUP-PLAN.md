# First-run device setup plan

Revised 2026-10-15 following the user's clarification. This replaces the previous
task-oriented UX direction. The software implementation is documented in
[the implementation report](CAPTURE-SETUP-IMPLEMENTATION.md); hardware/fresh-Mac
acceptance and public release gates remain separate.

## Goal and scope

A nontechnical person installs **Mobile Capture.app**, completes phone setup once,
then records from the timeline. The Mac app includes its dependencies. No separate
Python, mitmproxy, Homebrew, ADB or IDE installation, engineer-authored task file,
or reproduction checklist is part of ordinary physical-phone use.

- **First use / new phone:** connect → prepare phone → check connection → timeline.
- **Repeat use:** timeline → choose device and sources → Start → Stop & Save → Export ZIP.

Remember setup per phone and capture-certificate identity. Routine recording does
not reopen the assistant or require another test recording. Existing sessions
remain accessible without connecting or setting up a phone.

## First-run experience

Offer a compact native **Set Up Your Device** assistant on first use, with an
explicit way to continue to the timeline or open saved evidence. After completion
or dismissal, later launches open the timeline. Relevant unfinished setup appears
as an inline **Finish Setup** action, rather than a repeated launch interruption.

### 1. Connect Your Device

Detect the phone/platform automatically. If several phones are connected, ask
which one to prepare; never change devices during a capture. Check embedded tools
automatically through Doctor and explain any broken installation with a
repair/reinstall action.

Show only the current unresolved phone instruction: Android USB debugging and
computer authorization, or iPhone unlock/computer trust. Recheck connection
automatically, with **Check Again** as a fallback. No app selection, task files,
runtime paths, process names or recording options are needed in this step.

### 2. Prepare Your Phone

Explain: **To capture HTTPS requests, install and trust this app's capture
certificate on your phone.** Guide one action at a time with short instructions,
illustrations, Back and expandable help. Let users take as long as needed in
Settings. Reuse the stable CA and show its recognizable short identity to
distinguish an older certificate with the same display name.

| Platform | Mac app handles | User approves on the phone |
| --- | --- | --- |
| Android | Prepare the bundled engine, copy its public certificate to Downloads, then stop preparation and restore routing before installation help | Install the CA through Settings and approve the phone's confirmation |
| iPhone | Prepare the existing WireGuard profile/QR and public-certificate access path | Install WireGuard using the official store link if needed, import the profile, install the certificate profile, then separately enable full trust |

Automate the surrounding work; guide OS-controlled trust and permission actions.
Do not rotate the CA each session or remove unrelated certificates.

Any iPhone setup connection uses the existing host and routing lease with device
logs off. Keep forwarding available until the phone tunnel is off and cleanup is
confirmed. A timer, cancellation or closing the assistant must not silently kill
forwarding. Expose **Restore Connection** when recovery is necessary.

Offer **Set Up HTTPS Later** for logs-only use or saved-session inspection.
Remember that HTTPS setup remains incomplete and offer the remaining step when
network capture is selected later. Skipping a step does not mark trust verified.

### 3. Check Connection

Use a small network-only check through the current engine and CA. Guide the user
to open its phone link/QR and perform the HTTPS test when ready. This checks the
capture connection; it requires no selected app or emitted app logs. Certificate
installation instructions are not time-boxed.

Use the actual fresh decoded HTTPS response as evidence. An acknowledgment or an
HTTP page alone cannot verify HTTPS. Record phone-origin confirmation as user
reported wherever the transport cannot establish it independently.

On success, show **Device Setup Complete → Open Timeline**. Finish the owned
check and restore routing before leaving; for iPhone, guide tunnel-off
confirmation. On failure, show the unresolved step with **Try Again** or
**Save Setup Report…**. Users may return to the timeline with the relevant
limitation visible.

This verifies the tested phone/browser path, not every app or ad SDK. An Android
test build must still trust the CA, and app-specific TLS behavior may need engineer
attention. Put detailed troubleshooting beside an actual failure or under help.

## Everyday timeline

The timeline is the main workspace, including after relaunch. Keep:

- Device selection and Device Logs / Network Requests & Responses checkboxes.
- App selection when app-scoped logs are enabled.
- Start Capture, Stop & Save, optional markers and Export ZIP.
- Existing filtering, pause/follow/clear, paging and event inspection controls.

Keep safe bounded app logging; whole-device logging remains an explicit advanced
choice. Selecting an app or changing sources does not replay certificate setup.
After Stop, show **Capture Saved** with export and Finder actions. Logs, requests,
full admitted bodies and raw evidence remain in the same timeline and one ZIP.
Package summaries report actual coverage and gaps without requiring a task file.

For physical iPhone, keep a concise tunnel-on/off instruction beside Start/Stop.
Profile import and certificate trust are first-use steps; toggling the tunnel
remains a per-recording action in v1.

## Doctor: check and repair

Add **Doctor…** to the Capture menu and the first-run setup's **Check Setup**
action. It runs the same checks as setup and shows a small list with **Ready**,
**Needs Action** or **Missing / Incompatible**, a short explanation and a relevant
**Fix** or **Show Instructions** action. Keep detailed paths/output in a disclosure
and the local setup report. Ordinary users should not need to interpret commands.

Check the components needed for the selected platform and sources: bundled
capture engine/runtime, ADB or iPhone USB tools, compatible versions/architecture,
writable storage/disk space, phone access and capture configuration. Tools for
an unused platform are not a blocker. Evaluate certificate/profile identity and
connection evidence separately; executable presence alone is not successful
HTTPS capture. A live HTTPS check remains an explicit action through the host.

Checking is read only. **Fix Missing Components** previews the proposed installs
and then performs the selected repairs, with progress, useful failure/retry
messages and a post-install compatibility check. Phone trust, certificate approval
and VPN prompts continue through guided user actions.

Dependency source policy:

1. Prefer the tested tools already bundled in the signed app. Python comes with
   the capture engine; do not add a separate Python installation for this route.
2. For a missing/damaged bundled payload, repair or replace the signed app package.
   Do not patch files inside the sealed app or disable macOS protections.
3. Offer **Install with Homebrew…** as an optional repair/development route for
   supported external components. The app can run approved package installs and
   show progress so users do not type terminal commands. First explain that this
   installs Mac software, then verify the resulting tool versions and capability.
4. If Homebrew is absent, make its installation a separate explicit choice with
   its own guidance. Keep the bundled-app route available. Do not silently turn
   Homebrew into a prerequisite for normal first use.

Limit Homebrew actions to reviewed packages needed for capture; do not run broad
upgrades, add arbitrary taps, or assume the latest installed version is compatible
with the pinned engine. Failed installation leaves Doctor usable and exposes the
next action. Automatic checks never start an installer or alter phone routing.

Homebrew supports unattended installation, but provisioning/permissions and
package requirements still need testing on a fresh Mac. Its documentation notes
that building formulae from source requires Xcode Command Line Tools; binary
bottles/casks can avoid that build requirement. Use the official
[installation documentation](https://github.com/Homebrew/brew/blob/main/docs/Installation.md)
and [Mac administration guidance](https://github.com/Homebrew/brew/blob/main/docs/Homebrew-for-Mac-Admins.md)
when implementing this optional backend. Our Doctor is app-specific and also
covers phone setup, beyond Homebrew package health.

## Remember and repair

Store device identity, CA fingerprint, relevant profile identity, completed setup
steps and the time/basis of the last successful check. Keep saved progress separate
from current connection status; it cannot prove the phone is currently unlocked
or still trusts the certificate.

| Situation | Behavior |
| --- | --- |
| Known phone, unchanged setup | Open timeline; quietly check prerequisites on connection/Start |
| New phone | Inline Set Up This Device action |
| Missing/changed CA or iPhone endpoint/profile | Show only the affected repair step |
| Disconnected/locked phone | Inline reconnect/unlock instruction; preserve sessions |
| HTTPS/trust failure | Offer Check Connection or Repair Device Setup; do not claim remote trust-switch inspection |

Keep **Device Setup…** available from the Capture menu and a Devices area in
Settings. Only show a repair prompt in the timeline when relevant.

## What changes from the current implementation

Remove Open Capture Plan, plan review/apply, task/reproduction screens and
required-task-evidence gates from normal setup. Stop restoring remembered plans
into new sessions. Ordinary capture moves back to the existing timeline.

Reuse bundled dependencies, readiness checks, stable certificates, Android
public-CA preparation, the synthetic HTTPS check and safe recovery ownership.
Network setup must not depend on app-log collection. Preserve older saved
recordings containing plan metadata. Deleting unused parser/model code can be
later cleanup; it must not delay the simpler UX.

## Packaging and release

The supported physical-phone package must include the pinned capture engine,
embedded Python, ADB and supported iPhone USB utilities/libraries, signed and
notarized as one app. Dependency names/commands belong in engineering docs, not
nontechnical setup. Preserve notices/provenance and install no replacement USB
daemon. WireGuard on the iPhone remains a guided store installation in v1.

Android dependencies are bundled today. The optional iPhone USB development
candidate passes local static/signature/version probes; clean-Mac/current-iOS
operation and release distribution still need validation before claiming
one-download iPhone support. Simulator remains an engineer option requiring
Xcode, whose absence must not prompt ordinary phone users to install an IDE.

Resolve the known WireGuard shutdown crash and complete permanent release identity,
Developer ID signing and notarization before an AdOps release.

## Implementation checkpoints

1. **Simplify navigation and add Doctor:** remove task-oriented entry/screens,
   stop remembered-plan restoration, default to timeline, preserve optional setup
   and old evidence. Reuse readiness checks in Doctor and model explicit repair
   actions, with bundled tools preferred and an optional Homebrew backend.
2. **Android first-run setup:** connect, copy public CA and restore routing, guide
   installation, run network-only check and remember device progress.
3. **iPhone first-run setup:** simplify QR/profile/certificate/full-trust guidance,
   retain tunnel recovery, validate the bundled USB path on a clean Mac.
4. **Repeat use and repair:** selective inline guidance, menu/Settings access,
   setup deferral for logs-only use, relaunch behavior and save/export feedback.
5. **Acceptance/release:** test actual installation and both phone flows with a
   nontechnical teammate, including interruption recovery and keyboard/VoiceOver.

Commit each implementation checkpoint with focused validation. Implementation
status and remaining validation are recorded in the implementation report above.

## Acceptance criteria

- Supported fresh Macs need one app download and no separate capture dependencies.
- Doctor checks relevant dependencies, reports versions/problems and provides
  explicit repair actions with progress and post-install verification. Checking
  alone never installs software; optional Homebrew repair does not silently
  upgrade unrelated software or become the default installation prerequisite.
- Phone certificate installation/full-trust guidance is clear and distinguishable
  from an older same-named CA.
- Normal use needs no capture-plan file or reproduction checklist.
- Completed/deferred setup leads to the timeline; repeat use needs no assistant
  or separate test recording.
- New phones and changed setup receive only the relevant remaining instructions.
- Network-only setup never starts device logs or requires selecting an app.
- Cancel/disconnect/quit preserves recovery ownership and dependent forwarding.
- Logs stay bounded; evidence shares the timeline and one local export.
- Private keys/profiles stay excluded; old sessions remain readable.

## Design basis and references

The apple-design references support this scope: onboarding.md › Additional
requests says **“Postpone nonessential setup flows or customization steps.”**
settings.md › Best practices says **“Minimize the number of settings you offer.”**
Use brief, optional onboarding, contextual inline feedback, native controls,
semantic colors, adaptive text/layout, keyboard/VoiceOver labels and untimed phone
instructions, as covered by onboarding, feedback and accessibility guidance.

Reuse [setup foundations](CAPTURE-SETUP-IMPLEMENTATION.md),
[standalone lifecycle](CAPTURE-STANDALONE-IMPLEMENTATION.md),
[distribution](CAPTURE-DISTRIBUTION.md) and
[logging behavior](CAPTURE-LOGGING-VALIDATION.md). The separate
[capture MCP plan](CAPTURE-MCP-PLAN.md) remains independent.
