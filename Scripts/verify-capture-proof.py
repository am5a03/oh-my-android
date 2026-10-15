#!/usr/bin/env python3
"""Verify a neutral live proof from its ZIP, without printing captured bodies or unrelated logs."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import tempfile
import zipfile


def body(value: dict) -> bytes:
    text = value.get("text", "")
    if value.get("encoding", value.get("_encoding")) == "base64":
        return base64.b64decode(text, validate=True)
    return text.encode("utf-8")


def verify(package: Path, nonce: str, require_native: bool) -> dict:
    with zipfile.ZipFile(package) as archive:
        names = set(archive.namelist())
        required = {"manifest.json", "SHA256SUMS", "timeline/events.jsonl", "network/capture.har",
                    "network/capture.mitm", "logs/device.log"}
        assert required <= names, "The combined proof package is missing an evidence source"
        assert not any(name.startswith(("runtime/", "setup/")) for name in names), "Private runtime/setup file exported"
        for line in archive.read("SHA256SUMS").decode().splitlines():
            expected, name = line.split("  ", 1)
            assert hashlib.sha256(archive.read(name)).hexdigest() == expected, f"Checksum mismatch: {name}"
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest.get("routing_restored") is True, "Routing restoration is unverified"
        # A recovered/partial session may truthfully mark a source interrupted;
        # this proof verifies the specific request/markers below, not full coverage.
        assert manifest["sources"]["logs"] in ("observed", "interrupted"), "Device log source unavailable"
        assert manifest["sources"]["network"] in ("observed", "interrupted"), "Network source unavailable"
        har = json.loads(archive.read("network/capture.har"))
        matching = []
        for entry in har["log"]["entries"]:
            try:
                request = body(entry["request"].get("postData", {}))
                payload = json.loads(request)
            except (ValueError, TypeError, UnicodeDecodeError):
                continue
            if payload.get("capture_proof") == nonce:
                matching.append((entry, request))
        assert len(matching) == 1, "Expected exactly one POST carrying this proof nonce"
        entry, request = matching[0]
        assert entry["request"]["method"] == "POST"
        assert entry["response"]["status"] == 200, "Proof endpoint did not return HTTP 200"
        received = body(entry["response"]["content"])
        echoed = json.loads(received)
        assert echoed["json"]["capture_proof"] == nonce, "Exported response lost the echoed nonce"
        digest = hashlib.sha256(received).hexdigest()
        logs = archive.read("logs/device.log").decode("utf-8", errors="replace")
        assert "proof-start nonce=" + nonce in logs, "Device start marker missing"
        response_lines = [line for line in logs.splitlines() if "proof-response nonce=" + nonce in line]
        assert response_lines, "Device response marker missing"
        assert any("sha256=" + digest in line for line in response_lines), "Device response bytes differ from exported HAR"
        events = [json.loads(line) for line in archive.read("timeline/events.jsonl").splitlines() if line]
        assert any(event["source"] == "logs" and nonce in event["summary"] for event in events), "Log marker absent from shared timeline"
        flow_id = entry["_flow_id"]
        assert any(event["source"] == "network" and event["detail"].get("flow_id") == flow_id for event in events), "Network flow absent from shared timeline"
        assert any(event["source"] == "marker" and nonce in event["summary"] for event in events), "User marker absent from shared timeline"
        for event in events:
            relative = event["raw_ref"].split("#", 1)[0]
            assert relative in names, f"Timeline reference is not packaged: {relative}"
        native_parity = False
        if require_native:
            from mitmproxy import io
            with tempfile.TemporaryFile() as stream:
                stream.write(archive.read("network/capture.mitm"))
                stream.seek(0)
                for flow in io.FlowReader(stream).stream():
                    if flow.id == flow_id:
                        assert flow.request.content == request, "Native request and HAR body differ"
                        assert flow.response and flow.response.content == received, "Native response and HAR body differ"
                        native_parity = True
                        break
            assert native_parity, "Proof flow absent from native capture"
        return {"platform": manifest["platform"], "session_id": manifest["id"],
                "package": str(package), "proof_nonce": nonce, "http_status": 200,
                "request_bytes": len(request), "response_bytes": len(received),
                "response_sha256": digest, "native_har_body_parity": native_parity,
                "timeline_events": len(events), "package_files": len(names),
                "sources": manifest["sources"], "routing_restored": True,
                "package_state": manifest.get("package_state"),
                "clock_calibration": manifest.get("clock_calibration", {})}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--require-native", action="store_true", help="Run with a Python environment containing mitmproxy")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.nonce):
        parser.error("Use a neutral alphanumeric proof nonce")
    result = verify(args.package, args.nonce, args.require_native)
    rendered = json.dumps(result, indent=2)
    if args.report:
        args.report.write_text(rendered + "\n")
    print(rendered)


if __name__ == "__main__":
    main()
