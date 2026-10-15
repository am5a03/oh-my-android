# Standalone Mobile Capture implementation

This work follows [the standalone plan](CAPTURE-STANDALONE-PLAN.md). It does not
implement the separate capture MCP or guided setup, and it does not change device
routing, certificates, saved sessions or private iPhone profiles during validation.

## Checkpoint 1: service boundary and handoff

- Extracted the compiled-host client and request/response types from the observable
  UI store into a Foundation-only capture service file. The UI still owns its own
  presentation state; collectors remain owned by the existing host.
- Added a versioned launch-only handoff model with open/prefill/session actions.
  It rejects unknown actions/versions/fields, repeated fields, paths, credentials,
  ports, fragments, missing targets and oversized/control-character input.
- `local.mobilecapture.development` is a provisional local-development identity.
  It is not an owner-controlled public release identity; publishing requires a
  deliberate release identity decision. Automatic updates remain disabled.

Validation: handoff fixture checks passed (three encoded round trips and nineteen
invalid inputs). The existing capture-store fixture suite passed, including
full-session filters, markers, paging, held view and lazy body details. All compile
with Swift 6 and warnings as errors. The embedded Oh My Android app and helpers
also built successfully in an isolated DerivedData directory. No connected-device
or UI test was run.
