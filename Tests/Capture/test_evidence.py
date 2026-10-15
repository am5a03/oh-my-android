"""Evidence-only fixtures: no device, proxy, certificate, or network mutations."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


MODULE = Path(__file__).resolve().parents[2] / "CaptureRuntime" / "evidence.py"
SPEC = importlib.util.spec_from_file_location("capture_evidence", MODULE)
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "session"
        self.root.mkdir()

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode() if isinstance(content, str) else content)
        return path

    def state(self, **changes):
        state = {"id": "neutral-session", "platform": "android", "device_id": "fixture-device",
                 "device_name": "Neutral test device", "started_at": "2026-10-15T00:00:00Z",
                 "stopped_at": "2026-10-15T00:01:00Z", "phase": "saved",
                 "sources": {"logs": "observed", "network": "not_selected"},
                 "routing_restored": True}
        state.update(changes)
        self.write("session.json", json.dumps(state))
        return state

    def line(self, **changes):
        value = {"id": "flow-a-request", "timestamp": "2026-10-15T00:00:01.250000Z",
                 "original_timestamp": "2026-10-15T00:00:01.250000Z",
                 "received_at": "2026-10-15T00:00:01.260000Z", "source": "network", "kind": "request",
                 "summary": "POST https://example.test/ad", "raw_ref": "network/capture.mitm#flow-a",
                 "detail": {"method": "POST", "url": "https://example.test/ad", "flow_id": "flow-a"},
                 "clock_uncertainty_ms": 1}
        value.update(changes)
        return json.dumps(value)

    def test_android_epoch_calibration_merges_log_network_and_marker(self):
        self.state(clock_calibration={"logs": {"offset_ms": 250, "uncertainty_ms": 12.5, "method": "midpoint_probe"},
                                      "network": {"offset_ms": 0, "uncertainty_ms": 1, "method": "host_clock"}})
        self.write("logs/device.log", "1792022401.000  123  456 I NeutralAds: attempt=start\n")
        self.write("network/events.jsonl", self.line() + "\n")
        self.write("timeline/markers.jsonl", json.dumps({"timestamp": "2026-10-15T00:00:01.500Z", "text": "Tapped test ad"}) + "\n")
        events = evidence.read_events(self.root)
        self.assertEqual([item["source"] for item in events], ["logs", "network", "marker"])
        self.assertEqual(events[0]["timestamp"], "2026-10-15T00:00:01.250000Z")
        self.assertEqual(events[0]["original_timestamp"], "1792022401.000")
        self.assertEqual(events[0]["clock_uncertainty_ms"], 12.5)
        self.assertEqual(events[0]["detail"]["pid"], 123)
        self.assertEqual(events[1]["raw_ref"], "network/events.jsonl#L1")
        self.assertEqual(events[1]["detail"]["native_ref"], "network/capture.mitm#flow-a")
        self.assertEqual(events[1]["detail"]["method"], "POST")
        self.assertTrue(all(item["detail"]["temporal_matching"] == "inferred" for item in events))

    def test_simulator_ndjson_preserves_offset_timestamp_and_native_fields(self):
        self.state(platform="simulator", clock_calibration={"logs": {"offset_ms": -50, "uncertainty_ms": 8}})
        self.write("logs/device.log", json.dumps({"timestamp": "2026-10-14 17:00:02.150000-0700",
                                                   "eventMessage": "Neutral sample loaded ✓", "processID": 42,
                                                   "subsystem": "org.example.neutral", "category": "capture",
                                                   "machTimestamp": 123456789}) + "\n")
        event = evidence.read_events(self.root)[0]
        self.assertEqual(event["timestamp"], "2026-10-15T00:00:02.100000Z")
        self.assertEqual(event["original_timestamp"], "2026-10-14 17:00:02.150000-0700")
        self.assertEqual(event["summary"], "Neutral sample loaded ✓")
        self.assertEqual(event["detail"]["log"]["machTimestamp"], 123456789)
        self.assertEqual(event["clock_uncertainty_ms"], 8)

    def test_real_logcat_padding_preserves_time_order_headers_and_original_bytes(self):
        state = self.state(clock_calibration={"logs": {"offset_ms": 250, "uncertainty_ms": 12.5},
                                             "network": {"offset_ms": 0, "uncertainty_ms": 1}})
        original = ("--------- beginning of main\n\n"
                    "         1792027091.129   541   657 D ProxyTracker: update proxy: neutral\n"
                    "\t 1792027091.500   541   657 I SampleAds: request finished\n")
        self.write("logs/device.log", original)
        self.write("network/events.jsonl", self.line(timestamp="2026-10-15T01:18:11.300000Z") + "\n")
        events = evidence.read_events(self.root)
        header, network, first_log, second_log = events
        self.assertEqual(header["kind"], "unparsed_log")
        self.assertEqual(header["raw_ref"], "logs/device.log#L1")
        self.assertEqual(header["detail"]["timestamp_basis"], "session_start_fallback")
        self.assertIsNone(header["clock_uncertainty_ms"])
        self.assertEqual(network["source"], "network")
        self.assertEqual(first_log["timestamp"], "2026-10-15T01:18:11.379000Z")
        self.assertEqual(first_log["original_timestamp"], "1792027091.129")
        self.assertEqual(first_log["raw_ref"], "logs/device.log#L3")
        self.assertEqual(first_log["kind"], "log")
        self.assertEqual(first_log["detail"]["format"], "android_logcat_epoch")
        self.assertEqual(first_log["detail"]["pid"], 541)
        self.assertEqual(first_log["detail"]["tid"], 657)
        self.assertEqual(first_log["detail"]["tag"], "ProxyTracker")
        self.assertEqual(first_log["detail"]["message"], "update proxy: neutral")
        self.assertEqual(first_log["clock_uncertainty_ms"], 12.5)
        self.assertEqual(second_log["timestamp"], "2026-10-15T01:18:11.750000Z")
        self.assertEqual(second_log["raw_ref"], "logs/device.log#L4")
        with zipfile.ZipFile(evidence.finalize_package(self.root, state)) as archive:
            self.assertEqual(archive.read("logs/device.log"), original.encode())
            exported = [json.loads(line) for line in archive.read("timeline/events.jsonl").splitlines()]
            self.assertEqual(exported, events)

    def test_unknown_clock_is_not_zero_uncertainty_and_missing_time_is_explicit(self):
        self.state()
        self.write("logs/device.log", "1792022401.001  1  2 D Sample: no clock probe\n--------- beginning of main\n")
        self.write("network/events.jsonl", json.dumps({"received_at": "2026-10-15T00:00:03Z", "kind": "tls_error", "summary": "TLS failed"}) + "\n")
        events = evidence.read_events(self.root)
        by_summary = {event["summary"]: event for event in events}
        device = by_summary["Sample: no clock probe"]
        self.assertEqual(device["timestamp"], "2026-10-15T00:00:01.001000Z")
        self.assertIsNone(device["clock_uncertainty_ms"])
        self.assertFalse(device["detail"]["clock_calibrated"])
        self.assertEqual(by_summary["--------- beginning of main"]["detail"]["timestamp_basis"], "session_start_fallback")
        self.assertEqual(by_summary["TLS failed"]["detail"]["timestamp_basis"], "received_at_fallback")
        self.assertIsNone(by_summary["TLS failed"]["clock_uncertainty_ms"])

    def test_naive_or_invalid_timestamps_never_use_the_host_timezone(self):
        self.state()
        self.write("logs/device.log", '\n'.join(json.dumps({"timestamp": value, "eventMessage": "invalid"}) for value in ("2026-10-14 17:00:00", "not-a-time", "99999999999999999999999999")))
        for event in evidence.read_events(self.root):
            self.assertEqual(event["timestamp"], "2026-10-15T00:00:00.000000Z")
            self.assertEqual(event["detail"]["timestamp_basis"], "session_start_fallback")
            self.assertIsNone(event["clock_uncertainty_ms"])

    def test_display_limit_retains_newest_without_truncating_export(self):
        state = self.state()
        original = "".join(f"179202240{i}.000  1  2 I Sample: line {i}\n" for i in range(5))
        self.write("logs/device.log", original)
        limited = evidence.read_events(self.root, limit=2)
        self.assertEqual([event["summary"] for event in limited], ["Sample: line 3", "Sample: line 4"])
        self.assertEqual(evidence.read_events(self.root, 0), [])
        for invalid in (-1, True, 1.5):
            with self.assertRaises(ValueError):
                evidence.read_events(self.root, invalid)
        package = evidence.finalize_package(self.root, state)
        with zipfile.ZipFile(package) as archive:
            self.assertEqual(archive.read("logs/device.log"), original.encode())
            self.assertEqual(len(archive.read("timeline/events.jsonl").splitlines()), 5)

    def test_marker_round_trip_handles_shell_characters_unicode_and_newlines(self):
        self.state(sources={"logs": "not_selected", "network": "not_selected"})
        text = 'User tapped "test"\n$(touch should-never-execute); café 🔍'
        marker = evidence.append_marker(self.root, text)
        self.assertEqual(marker["summary"], text)
        self.assertEqual(marker["source"], "marker")
        self.assertEqual(marker["raw_ref"], "timeline/markers.jsonl#L1")
        self.assertEqual(marker["clock_uncertainty_ms"], 1)
        self.assertEqual(evidence.read_events(self.root), [marker])
        self.assertEqual(len((self.root / "timeline/markers.jsonl").read_bytes().splitlines()), 1)
        with self.assertRaises(ValueError):
            evidence.append_marker(self.root, "  ")

    def test_network_filter_searches_full_session_despite_device_log_flood(self):
        self.state()
        self.write("network/events.jsonl", self.line(detail={"response_body": {"text": "OLDER CAFÉ evidence"}}) + "\n")
        self.write("logs/device.log", "".join(f"1792022402.000  1  2 I Noise: line {i}\n" for i in range(900)))
        self.assertTrue(all(event["source"] == "logs" for event in evidence.read_events(self.root, 400)))
        page = evidence.read_event_page(self.root, source="network", search="café")
        self.assertEqual(len(page["events"]), 1)
        self.assertEqual(page["timeline"], {"source": "network", "search": "café", "total_count": 901,
                                            "matching_count": 1, "has_older": False})
        self.assertEqual(page["events"][0]["detail"]["response_body"]["text"], "OLDER CAFÉ evidence")
        self.write("logs/device.log", "".join(f"1792022403.000  1  2 I Noise: line {i}\n" for i in range(1800)))
        self.assertEqual(evidence.read_event_page(self.root, source="network", search="CAFÉ")["events"], page["events"])
        self.assertEqual(evidence.read_event_page(self.root, source="network", search="cafe\u0301")["events"], page["events"])
        empty = evidence.read_event_page(self.root, source="network", search="absent")
        self.assertEqual(empty["events"], [])
        self.assertEqual(empty["timeline"]["total_count"], 1801)

    def test_timeline_refresh_retains_history_and_loads_older_during_capture(self):
        state = self.state(sources={"logs": "not_selected", "network": "observed"})
        def network_lines(count):
            return "".join(self.line(id=f"flow-{i}", timestamp=f"2026-10-15T00:{i // 60:02d}:{i % 60:02d}Z",
                                     summary=f"Request {i}") + "\n" for i in range(count))
        self.write("network/events.jsonl", network_lines(900))
        first = evidence.read_event_page(self.root, source="network")
        self.assertEqual(len(first["events"]), 400)
        self.assertEqual(first["events"][0]["summary"], "Request 500")
        self.assertTrue(first["timeline"]["has_older"])
        anchor = first["events"][0]["id"]
        self.write("network/events.jsonl", network_lines(1500))
        refreshed = evidence.read_event_page(self.root, source="network", retain_from=anchor)
        self.assertEqual(len(refreshed["events"]), 1000)
        self.assertEqual(refreshed["events"][:400], first["events"])
        older = evidence.read_event_page(self.root, source="network", retain_from=anchor, older=400)
        self.assertEqual(older["events"][0]["summary"], "Request 100")
        all_events = evidence.read_event_page(self.root, source="network", retain_from=older["events"][0]["id"], older=400)
        self.assertEqual(len(all_events["events"]), 1500)
        self.assertFalse(all_events["timeline"]["has_older"])
        package = evidence.finalize_package(self.root, state)
        with zipfile.ZipFile(package) as archive:
            self.assertEqual(len(archive.read("timeline/events.jsonl").splitlines()), 1500)

    def test_timeline_page_validates_options_and_keeps_source_order_on_timestamp_ties(self):
        self.state()
        self.write("network/events.jsonl", self.line() + "\n")
        self.write("timeline/markers.jsonl", json.dumps({"timestamp": "2026-10-15T00:00:01.250000Z", "text": "tap"}) + "\n")
        page = evidence.read_event_page(self.root, retain_from="missing-anchor")
        self.assertEqual([event["source"] for event in page["events"]], ["network", "marker"])
        self.assertEqual(evidence.read_event_page(self.root, source="marker")["events"][0]["summary"], "tap")
        self.assertEqual(evidence.read_event_page(self.root, limit=0)["events"], [])
        for options in ({"limit": -1}, {"older": -1}, {"limit": True}, {"source": "unknown"}):
            with self.assertRaises(ValueError):
                evidence.read_event_page(self.root, **options)

    def test_network_bodies_and_native_bytes_are_byte_exact(self):
        state = self.state(sources={"logs": "not_selected", "network": "observed"})
        request = self.line()
        response = self.line(id="flow-a-response", kind="response", timestamp="2026-10-15T00:00:02Z",
                             detail={"method": "POST", "url": "https://example.test/ad", "status": 200, "flow_id": "flow-a"})
        self.write("network/events.jsonl", request + "\n" + response + "\n")
        body = "x" * 200_000 + "🚀\u0000\r\ntrailing-body"
        har = json.dumps({"log": {"entries": [{"request": {"method": "POST", "url": "https://example.test/ad", "postData": {"text": body}},
                                                "response": {"status": 200, "content": {"text": "AAECA//+", "encoding": "base64"}}}]}}, ensure_ascii=False).encode()
        native = bytes(range(256)) * 500 + b"\x00native-complete-body\xff"
        self.write("network/capture.har", har)
        self.write("network/capture.mitm", native)
        with zipfile.ZipFile(evidence.finalize_package(self.root, state)) as archive:
            self.assertEqual(archive.read("network/capture.har"), har)
            self.assertEqual(archive.read("network/capture.mitm"), native)
            manifest = json.loads(archive.read("manifest.json"))
            self.assertFalse(manifest["completeness"]["partial"])
            self.assertEqual(manifest["counts"]["network"], 2)
            self.assertEqual(manifest["completeness"]["pending_flow_ids"], [])

    def test_partial_package_records_failures_pending_missing_and_original_state(self):
        state = self.state(phase="partial", sources={"logs": "observed", "network": "interrupted"},
                           errors=["Simulator log collector exited", "Network collector interrupted"], routing_restored=False,
                           completeness={"collector_exit_code": 9})
        self.write("network/events.jsonl", self.line() + "\n{incomplete-json\n")
        self.write("network/incomplete.json", json.dumps({"pending_flow_ids": ["flow-b"]}))
        with zipfile.ZipFile(evidence.finalize_package(self.root, state)) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["phase"], "partial")
            self.assertEqual(manifest["package_state"], "partial")
            self.assertEqual(manifest["sources"]["logs"], "failed")
            self.assertFalse(manifest["completeness"]["sources"]["logs"]["observed"])
            self.assertIn("logs/device.log", manifest["completeness"]["missing_artifacts"])
            self.assertIn("network/capture.har", manifest["completeness"]["missing_artifacts"])
            self.assertEqual(manifest["completeness"]["pending_flow_ids"], ["flow-a", "flow-b"])
            self.assertEqual(manifest["completeness"]["collector_exit_code"], 9)
            self.assertEqual(manifest["completeness"]["unparsed_event_refs"], ["network/events.jsonl#L2"])
            self.assertEqual(manifest["errors"], state["errors"])
            self.assertFalse(manifest["routing_restored"])
        self.assertEqual(state["sources"]["logs"], "observed", "caller state must not be mutated")

    def test_empty_partial_capture_still_exports_actionable_manifest(self):
        state = self.state(phase="failed", sources={"logs": "failed", "network": "not_selected"}, errors=["ADB unavailable"])
        with zipfile.ZipFile(evidence.finalize_package(self.root, state)) as archive:
            self.assertEqual(archive.read("timeline/events.jsonl"), b"")
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["artifacts"], [])
            self.assertEqual(manifest["errors"], ["ADB unavailable"])
            self.assertEqual(manifest["completeness"]["unknown_clock_events"], 0)
            self.assertFalse(manifest["completeness"]["sources"]["logs"]["observed"])

    def test_tls_only_is_not_observed_http_and_native_pending_ids_are_preserved(self):
        state = self.state(sources={"logs": "not_selected", "network": "observed"})
        self.write("network/events.jsonl", self.line(kind="tls_error", summary="Client TLS handshake failed", detail={"error": "untrusted CA"}) + "\n")
        self.write("network/capture.har", '{"log":{"entries":[]}}')
        self.write("network/capture.mitm", b"")
        self.write("network/incomplete.json", '{"flow_ids":["pending-from-native"],"count":1}')
        with zipfile.ZipFile(evidence.finalize_package(self.root, state)) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["counts"]["network"], 1)
            self.assertEqual(manifest["sources"]["network"], "started")
            self.assertFalse(manifest["completeness"]["sources"]["network"]["observed"])
            self.assertEqual(manifest["completeness"]["sources"]["network"]["decoded_http_events"], 0)
            self.assertEqual(manifest["completeness"]["pending_flow_ids"], ["pending-from-native"])
            self.assertEqual(manifest["completeness"]["network_error_refs"], ["network/events.jsonl#L1"])
            self.assertTrue(manifest["completeness"]["partial"])

    def test_deterministic_zip_and_every_checksum_verifies(self):
        state = self.state()
        self.write("logs/device.log", "1792022401.001  1  2 I Sample: stable\n")
        first = evidence.finalize_package(self.root, state).read_bytes()
        package = evidence.finalize_package(self.root, state)
        self.assertEqual(first, package.read_bytes())
        with zipfile.ZipFile(package) as archive:
            sums = archive.read("SHA256SUMS").decode().splitlines()
            covered = []
            for line in sums:
                digest, path = line.split("  ", 1)
                self.assertEqual(hashlib.sha256(archive.read(path)).hexdigest(), digest)
                covered.append(path)
            self.assertEqual(set(covered), set(archive.namelist()) - {"SHA256SUMS"})
            self.assertEqual(archive.namelist(), sorted(archive.namelist()))
            for info in archive.infolist():
                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
            for artifact in json.loads(archive.read("manifest.json"))["artifacts"]:
                self.assertEqual(artifact["bytes"], len(archive.read(artifact["path"])))
                self.assertEqual(artifact["sha256"], hashlib.sha256(archive.read(artifact["path"])).hexdigest())

    def test_exact_allowlist_excludes_control_material_but_preserves_evidence(self):
        state = self.state(control_token="top-level-control-secret", directory="private-session-path",
                           context={"purpose": "neutral sample", "auth_token": "nested-control-secret", "private_key": "private-secret"})
        self.write("logs/device.log", "1792022401.001  1  2 I Sample: preserved\n")
        for path in ("runtime/control.json", "runtime/recovery.json", "request.json", "mitmproxy/mitmproxy-ca.pem",
                     "network/private-key.pem", "logs/unrequested.log", "timeline/extraneous.json", "arbitrary.txt"):
            self.write(path, "never-export-this-secret")
        with zipfile.ZipFile(evidence.finalize_package(self.root, state)) as archive:
            self.assertEqual(set(archive.namelist()), {"logs/device.log", "manifest.json", "context.json", "timeline/events.jsonl", "README.txt", "SHA256SUMS"})
            exported = b"\n".join(archive.read(name) for name in archive.namelist())
            for secret in (b"never-export-this-secret", b"top-level-control-secret", b"nested-control-secret", b"private-secret", b"private-session-path"):
                self.assertNotIn(secret, exported)
            self.assertIn(b"neutral sample", exported)

    def test_symlink_file_directory_state_and_destination_are_rejected(self):
        state = self.state()
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        (outside / "device.log").write_text("outside-secret")
        (self.root / "logs").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            evidence.finalize_package(self.root, state)
        (self.root / "logs").unlink()
        (self.root / "logs").mkdir()
        (self.root / "logs/device.log").symlink_to(outside / "device.log")
        with self.assertRaises(ValueError):
            evidence.read_events(self.root)
        (self.root / "logs/device.log").unlink()
        (self.root / "capture-package.zip").symlink_to(outside / "device.log")
        with self.assertRaises(ValueError):
            evidence.finalize_package(self.root, state)
        self.assertEqual((outside / "device.log").read_text(), "outside-secret")
        (self.root / "capture-package.zip").unlink()
        (self.root / "session.json").unlink()
        (self.root / "session.json").symlink_to(outside / "device.log")
        with self.assertRaises(ValueError):
            evidence.read_events(self.root)

    def test_marker_cannot_write_through_symlink(self):
        self.state()
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        (self.root / "timeline").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            evidence.append_marker(self.root, "must not escape")
        self.assertFalse((outside / "markers.jsonl").exists())

    def test_invalid_utf8_and_malformed_json_keep_original_evidence(self):
        state = self.state()
        original = b"1792022401.000  1  2 W Sample: invalid \xff\n{not json\n"
        self.write("logs/device.log", original)
        with zipfile.ZipFile(evidence.finalize_package(self.root, state)) as archive:
            self.assertEqual(archive.read("logs/device.log"), original)
            events = [json.loads(line) for line in archive.read("timeline/events.jsonl").splitlines()]
            self.assertEqual(len(events), 2)
            self.assertEqual({event["raw_ref"] for event in events}, {"logs/device.log#L1", "logs/device.log#L2"})


if __name__ == "__main__":
    unittest.main()
