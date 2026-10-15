"""Offline Safari proof validation; synthetic bytes only, no listeners or devices."""
import base64
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("iphone_capture_proof", ROOT / "Scripts/serve-iphone-capture-proof.py")
proof = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proof)


def encoded(data):
    return base64.b64encode(data).decode("ascii")


def json_line(value):
    return json.dumps(value, ensure_ascii=False).encode("utf-8") + b"\n"


def captured_body(data):
    return {"encoding": "base64", "text": encoded(data), "bytes": len(data)}


class IPhoneSafariProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="iphone-proof-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # An accidental live listener or outbound request is a test failure.
        sockets = patch.object(socket, "socket", side_effect=AssertionError("Offline test attempted socket access"))
        sockets.start()
        self.addCleanup(sockets.stop)
        self.nonce = "iphone-safari-neutral-fixture"
        payload = {"capture_proof": self.nonce, "proof_kind": "physical-iphone-safari",
                   "message": "Neutral café e\u0301 中文 🧭", "padding": "abcdef0123456789" * 320}
        self.request = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.response = json.dumps({"json": payload, "data": self.request.decode("utf-8")}, ensure_ascii=False).encode("utf-8")
        self.receipt = {"schema_version": 1, "proof_nonce": self.nonce, "method": "POST", "url": proof.TARGET,
                        "http_status": 200, "request_body_base64": encoded(self.request), "response_body_base64": encoded(self.response)}
        self.receipt_path = self.root / "receipt.json"
        proof.private_write(self.receipt_path, self.receipt)
        self.flow_id = "neutral-fixture-flow"
        self.raw_log = "Oct 15 06:00:00.123456 SpringBoard[321] <Info>: neutral USB log"
        self.raw_marker = {"summary": "Safari proof " + self.nonce}
        details = {"flow_id": self.flow_id, "client_address": ["10.0.0.1", 12345], "request_body": captured_body(self.request)}
        self.raw_network = [{"kind": "request", "detail": details},
                            {"kind": "response", "detail": dict(details, response_body=captured_body(self.response))}]
        self.events = [{"source": "logs", "kind": "log", "raw_ref": "logs/device.log#L1",
                        "detail": {"format": "iphone_idevicesyslog_utc", "timestamp_basis": "source_timestamp", "raw_line": self.raw_log}}]
        for number, event in enumerate(self.raw_network, 1):
            self.events.append(dict(event, source="network", raw_ref=f"network/events.jsonl#L{number}",
                                    detail=dict(event["detail"], native_ref="network/capture.mitm#" + self.flow_id)))
        self.events.append({"source": "marker", "kind": "marker", "summary": self.raw_marker["summary"],
                            "raw_ref": "timeline/markers.jsonl#L1", "detail": {}})
        self.har_entry = {"_flow_id": self.flow_id,
                          "request": {"method": "POST", "url": proof.TARGET, "postData": captured_body(self.request)},
                          "response": {"status": 200, "content": captured_body(self.response)}}
        self.files = {
            "manifest.json": json.dumps({"platform": "iphone", "id": "neutral-fixture", "routing_restored": True,
                                         "sources": {"logs": "observed", "network": "observed"}}).encode(),
            "logs/device.log": self.raw_log.encode() + b"\n",
            "timeline/markers.jsonl": json_line(self.raw_marker),
            "network/events.jsonl": b"".join(map(json_line, self.raw_network)),
            "timeline/events.jsonl": b"".join(map(json_line, self.events)),
            "network/capture.mitm": b"synthetic placeholder; native decoder is optional in this offline test",
            "network/capture.har": json.dumps({"log": {"entries": [self.har_entry]}}, ensure_ascii=False).encode(),
        }

    def package(self, files=None):
        files = dict(self.files if files is None else files)
        files["SHA256SUMS"] = "".join(hashlib.sha256(data).hexdigest() + "  " + name + "\n"
                                      for name, data in files.items()).encode()
        destination = self.root / "capture.zip"
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        return destination

    def verify(self, package=None, receipt=None, nonce=None, address="10.0.0.1", network_only=False):
        return proof.verify(package or self.package(), receipt or self.receipt_path, nonce or self.nonce, False, address, network_only)

    def network_only_files(self):
        files = dict(self.files)
        del files["logs/device.log"]
        manifest = json.loads(files["manifest.json"])
        manifest["sources"]["logs"] = "not_selected"
        files["manifest.json"] = json.dumps(manifest).encode()
        files["timeline/events.jsonl"] = b"".join(json_line(event) for event in self.events if event["source"] != "logs")
        return files

    def test_utf8_long_body_receipt_keeps_exact_bytes_and_private_permissions(self):
        receipt = proof.validate_receipt(self.receipt, self.nonce)
        self.assertEqual(proof.decode_base64(receipt["request_body_base64"]), self.request)
        self.assertEqual(proof.decode_base64(receipt["response_body_base64"]), self.response)
        self.assertGreater(len(self.request), 4096)
        self.assertIn("中文 🧭".encode(), self.request)
        self.assertEqual(receipt["request_sha256"], hashlib.sha256(self.request).hexdigest())
        self.assertEqual(receipt["response_bytes"], len(self.response))
        self.assertEqual(self.receipt_path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            proof.private_write(self.receipt_path, {"replace": "forbidden"})

    def test_raw_lines_match_mixed_and_chunk_split_crlf_numbering(self):
        class TinyChunks(io.BytesIO):
            def read(self, count=-1):
                return super().read(min(3, count))
        self.assertEqual(list(proof.raw_lines(TinyChunks(b"a\r\nb\rc\n\nlast\r"))),
                         [b"a", b"b", b"c", b"", b"last"])
        self.assertEqual(list(proof.raw_lines(io.BytesIO(b""))), [])

    def test_combined_package_matches_safari_receipt_without_network_access(self):
        result = self.verify()
        self.assertEqual(result["platform"], "iphone")
        self.assertEqual(result["proof_mode"], "safari")
        self.assertEqual(result["proof_scope"], "combined")
        self.assertEqual(result["request_bytes"], len(self.request))
        self.assertEqual(result["response_sha256"], hashlib.sha256(self.response).hexdigest())
        self.assertEqual(result["parsed_usb_log_events"], 1)
        self.assertEqual(result["timeline_events"], 4)
        self.assertIn("no custom app/request log marker", result["device_log_correlation"])

    def test_network_only_proof_requires_explicit_scope_and_makes_no_usb_claim(self):
        package = self.package(self.network_only_files())
        result = self.verify(package=package, network_only=True)
        self.assertEqual(result["proof_scope"], "network_only")
        self.assertEqual(result["parsed_usb_log_events"], 0)
        self.assertEqual(result["sources"]["logs"], "not_selected")
        self.assertEqual(result["timeline_events"], 3)
        self.assertIn("Device logs not selected", result["device_log_correlation"])
        with self.assertRaisesRegex(AssertionError, "missing an evidence source"):
            self.verify(package=package)  # Default verification remains a combined-source proof.

    def test_network_only_flag_rejects_session_that_selected_logs(self):
        files = self.network_only_files()
        manifest = json.loads(files["manifest.json"])
        manifest["sources"]["logs"] = "observed"
        files["manifest.json"] = json.dumps(manifest).encode()
        with self.assertRaisesRegex(AssertionError, "logs not selected"):
            self.verify(package=self.package(files), network_only=True)

    def test_network_only_scope_keeps_body_marker_and_client_checks(self):
        files = self.network_only_files()
        with self.assertRaisesRegex(AssertionError, "phone tunnel address"):
            self.verify(package=self.package(files), network_only=True, address="10.0.0.2")
        files["timeline/events.jsonl"] = b"".join(json_line(event) for event in self.events if event["source"] == "network")
        with self.assertRaisesRegex(AssertionError, "Nonce user marker missing"):
            self.verify(package=self.package(files), network_only=True)

    def test_modified_response_and_saved_digest_are_rejected(self):
        changed = dict(self.receipt, response_body_base64=encoded(json.dumps({"json": json.loads(self.request), "changed": True}).encode()))
        other = self.root / "changed.json"
        proof.private_write(other, changed)
        with self.assertRaisesRegex(AssertionError, "response bytes differ"):
            self.verify(receipt=other)
        changed = dict(self.receipt, response_sha256="0" * 64)
        with self.assertRaisesRegex(ValueError, "digest/size mismatch"):
            proof.validate_receipt(changed, self.nonce)

    def test_receipt_nonce_mismatch_and_wrong_tunnel_address_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "nonce/schema mismatch"):
            self.verify(nonce="iphone-safari-another-nonce")
        with self.assertRaisesRegex(AssertionError, "phone tunnel address"):
            self.verify(address="10.0.0.2")

    def test_private_key_or_client_profile_in_export_is_rejected(self):
        for name, value in [("setup/server.json", b'{"server_key":"synthetic-secret"}'),
                            ("MobileCapture.conf", b"[Interface]\nPrivateKey = synthetic-secret\n")]:
            with self.subTest(name=name):
                with self.assertRaisesRegex(AssertionError, "evidence allowlist"):
                    self.verify(package=self.package(dict(self.files, **{name: value})))

    def test_duplicate_nonce_flow_and_invalid_raw_line_are_rejected(self):
        har = json.dumps({"log": {"entries": [self.har_entry, self.har_entry]}}).encode()
        with self.assertRaisesRegex(AssertionError, "one fresh POST"):
            self.verify(package=self.package(dict(self.files, **{"network/capture.har": har})))
        events = copy.deepcopy(self.events)
        events[-1]["raw_ref"] = "timeline/markers.jsonl#L99"
        with self.assertRaisesRegex(AssertionError, "reference"):
            self.verify(package=self.package(dict(self.files, **{"timeline/events.jsonl": b"".join(map(json_line, events))})))

    def test_missing_timestamped_phone_log_and_marker_are_rejected(self):
        for source in ("logs", "marker"):
            with self.subTest(source=source):
                events = [event for event in self.events if event["source"] != source]
                with self.assertRaises(AssertionError):
                    self.verify(package=self.package(dict(self.files, **{"timeline/events.jsonl": b"".join(map(json_line, events))})))

    def test_receipt_limits_and_invalid_base64_are_rejected(self):
        oversized = dict(self.receipt, response_body_base64=encoded(b"x" * (proof.MAX_RECEIPT_BYTES + 1)))
        with self.assertRaisesRegex(ValueError, "receipt limit"):
            proof.validate_receipt(oversized, self.nonce)
        with self.assertRaises(ValueError):
            proof.validate_receipt(dict(self.receipt, request_body_base64="invalid!"), self.nonce)


if __name__ == "__main__":
    unittest.main()
