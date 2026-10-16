#!/usr/bin/env python3
"""Synthetic fixture generation and independent ZIP verification, outside Swift timing.

The deliberately compressible 250k-line fixture measures a complete component save.
It never discovers devices, starts a listener or sends a request. capture.mitm is
intentionally absent; the package must honestly report that missing artifact.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import sys
import time
import zipfile


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def stream_hash(stream):
    digest = hashlib.sha256()
    length = 0
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
        length += len(block)
    return digest.hexdigest(), length


def file_hash(path):
    with path.open("rb") as stream:
        return stream_hash(stream)


def prepare(root):
    started = time.monotonic()
    session = root / "Session"
    for name in ("logs", "network", "timeline"):
        (session / name).mkdir(parents=True, mode=0o700)
    with (session / "logs/device.log").open("xb") as output:
        for batch in range(250):
            data = bytearray()
            for item in range(1000):
                number = batch * 1000 + item
                prefix = f"1792035999.000001  1  2 I Bench: event {number} ".encode()
                data += prefix + b"x" * (419 - len(prefix)) + b"\n"
            output.write(data)
    request = ("Synthetic request café 🧭 " + "ad_request_fixture=benchmark&" * 170).encode()[:4776].decode()
    response = ("Synthetic response café 🧭 " + "complete_response_body=benchmark&" * 350).encode()[:10880].decode()

    def body(text):
        raw = text.encode()
        return {"encoding": "utf-8", "text": text, "bytes": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest()}

    url = "https://example.invalid/mobile-capture-benchmark"
    flow = "synthetic-benchmark-flow"
    events = [
        {"timestamp": "2026-10-15T03:45:00Z", "kind": "request", "summary": "POST " + url,
         "detail": {"flow_id": flow, "method": "POST", "url": url, "request_body": body(request)}},
        {"timestamp": "2026-10-15T03:45:01Z", "kind": "response", "summary": "200 synthetic response",
         "detail": {"flow_id": flow, "status": 200, "request_body": body(request), "response_body": body(response)}},
    ]
    marker = {"id": "synthetic-marker", "timestamp": "2026-10-15T03:45:02Z", "kind": "marker",
              "summary": "Synthetic benchmark action", "detail": {"text": "Synthetic benchmark action", "origin": "user"},
              "clock_uncertainty_ms": 1}
    for path, rows in [(session / "network/events.jsonl", events), (session / "timeline/markers.jsonl", [marker])]:
        path.write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows))
    entry = {
        "_flow_id": flow, "startedDateTime": "2026-10-15T03:45:00Z", "time": 1000,
        "request": {"method": "POST", "url": url, "httpVersion": "HTTP/1.1", "headers": [], "queryString": [],
                    "cookies": [], "headersSize": -1, "bodySize": len(request.encode()),
                    "postData": {"mimeType": "text/plain; charset=utf-8", "text": request}},
        "response": {"status": 200, "statusText": "OK", "httpVersion": "HTTP/1.1", "headers": [], "cookies": [],
                     "content": {"size": len(response.encode()), "mimeType": "text/plain; charset=utf-8", "text": response},
                     "redirectURL": "", "headersSize": -1, "bodySize": len(response.encode())},
        "cache": {}, "timings": {"send": 0, "wait": 1000, "receive": 0},
    }
    write_json(session / "network/capture.har", {"log": {"version": "1.2", "creator": {"name": "Synthetic fixture", "version": "1"}, "entries": [entry]}})
    write_json(session / "network/incomplete.json", {"flow_ids": []})
    write_json(session / "session.json", {
        "id": "synthetic-save-benchmark", "platform": "android", "device_id": "synthetic",
        "device_name": "Synthetic fixture", "phase": "saved", "started_at": "2026-10-15T03:45:00Z",
        "stopped_at": "2026-10-15T03:46:00Z", "sources": {"logs": "observed", "network": "observed"},
        "warnings": [], "routing_restored": True, "capture_logs": True, "capture_network": True,
        "clock_calibration": {source: {"offset_ms": 0, "uncertainty_ms": 1, "method": "synthetic"} for source in ("logs", "network")},
        "context": {"benchmark": "synthetic, highly compressible fixture"},
    })
    write_json(root / "expected.json", {"log_lines": 250000, "log_bytes": 105000000, "request": request,
               "response": response, "flow_id": flow, "marker": marker["summary"],
               "generation_seconds": time.monotonic() - started})


def verify(root, mode):
    started = time.monotonic()
    session = root / "Session"
    expected = json.loads((root / "expected.json").read_text())
    metrics = json.loads((root / f"metrics-{mode}.json").read_text())
    archive = Path(metrics["archive_path"])
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        raw_paths = {"logs/device.log", "network/events.jsonl", "network/capture.har",
                     "network/incomplete.json", "timeline/markers.jsonl"}
        assert len(names) == len(set(names))
        assert set(names) == raw_paths | {"timeline/events.jsonl", "manifest.json", "context.json", "README.txt", "SHA256SUMS"}
        sums = dict((line.split("  ", 1)[1], line.split("  ", 1)[0]) for line in package.read("SHA256SUMS").decode().splitlines())
        assert set(sums) == set(names) - {"SHA256SUMS"}
        measured = {}
        for name, digest in sums.items():
            with package.open(name) as stream:
                actual, length = stream_hash(stream)  # ZipFile validates CRC during reads too.
            assert actual == digest, (name, "checksum mismatch")
            measured[name] = (actual, length)
        manifest = json.loads(package.read("manifest.json"))
        assert {artifact["path"] for artifact in manifest["artifacts"]} == raw_paths
        for artifact in manifest["artifacts"]:
            name = artifact["path"]
            assert measured[name] == (artifact["sha256"], artifact["bytes"]) == file_hash(session / name)
        assert file_hash(root / f"normalized-{mode}.jsonl") == measured["timeline/events.jsonl"]
        assert measured["logs/device.log"][1] == expected["log_bytes"]
        network = package.read("network/events.jsonl").splitlines()
        markers = package.read("timeline/markers.jsonl").splitlines()
        counts = {"logs": 0, "network": 0, "marker": 0}
        identifiers = set()
        bodies = {}
        with package.open("logs/device.log") as logs, package.open("timeline/events.jsonl") as timeline:
            for encoded in timeline:
                event = json.loads(encoded)
                source = event["source"]
                counts[source] += 1
                line = counts[source]
                if source == "logs":
                    path = "logs/device.log"
                    raw = logs.readline().rstrip(b"\n")
                    assert len(raw) == 419 and event["kind"] == "log"
                    assert event["summary"] == raw.decode().split(" I ", 1)[1]
                elif source == "network":
                    path = "network/events.jsonl"
                    raw = network[line - 1]
                    original = json.loads(raw)
                    assert event["kind"] == original["kind"]
                    assert event["detail"]["flow_id"] == expected["flow_id"]
                    for key in ("request_body", "response_body"):
                        if key in original["detail"]:
                            body = event["detail"][key]
                            text = body["text"]
                            assert body == original["detail"][key]
                            assert text == expected["request" if key == "request_body" else "response"]
                            assert len(text.encode()) == body["bytes"]
                            assert hashlib.sha256(text.encode()).hexdigest() == body["sha256"]
                            bodies[key] = body["sha256"]
                else:
                    path = "timeline/markers.jsonl"
                    raw = markers[line - 1]
                    assert event["kind"] == "marker" and event["summary"] == expected["marker"]
                assert event["raw_ref"] == f"{path}#L{line}"
                prefix = f"{source}\0{path}\0{line}\0".encode()
                assert event["id"] == "event-" + hashlib.sha256(prefix + raw).hexdigest()[:24]
                assert event["id"] not in identifiers
                identifiers.add(event["id"])
            assert not logs.read(1), "unreferenced raw log bytes"
        assert counts == {"logs": expected["log_lines"], "network": 2, "marker": 1}
        assert manifest["counts"] == {"logs": expected["log_lines"], "network": 2, "markers": 1}
        assert manifest["package_state"] == "partial"
        assert manifest["completeness"]["missing_artifacts"] == ["network/capture.mitm"]
        entry = json.loads(package.read("network/capture.har"))["log"]["entries"][0]
        assert entry["request"]["postData"]["text"] == expected["request"]
        assert entry["response"]["content"]["text"] == expected["response"]
        assert entry["request"]["bodySize"] == len(expected["request"].encode())
        assert entry["response"]["content"]["size"] == len(expected["response"].encode())
        assert set(bodies) == {"request_body", "response_body"}
    preserved = root / f"{mode}-capture-package.zip"
    shutil.copyfile(archive, preserved)
    result = {"verified": True, "elapsed_seconds": time.monotonic() - started,
              "checksum_files": len(sums), "counts": counts, "event_ids_and_raw_refs_verified": len(identifiers),
              "byte_exact_raw_artifacts": len(raw_paths), "timeline_byte_exact_copy": True,
              "request_bytes": len(expected["request"].encode()), "response_bytes": len(expected["response"].encode()),
              "HAR_timeline_body_parity": True, "cache_excluded": True, "package_state": "partial",
              "native_flow_decoder_proof": False, "archive_copy": str(preserved), "zip_sha256": file_hash(preserved)[0]}
    write_json(root / f"verification-{mode}.json", result)
    print(json.dumps(result, indent=2))


def report(root):
    result = {"machine": {"architecture": platform.machine(), "macos": platform.mac_ver()[0]},
              "runs": {mode: {"measurement": json.loads((root / f"metrics-{mode}.json").read_text()),
                              "verification": json.loads((root / f"verification-{mode}.json").read_text())}
                       for mode in ("cold", "warm")},
              "limits": ["One sample per mode; hardware and competing work affect timings",
                         "Cold means fresh compact cache, not cold filesystem pages",
                         "Highly compressible synthetic logs; no native-flow decoder proof",
                         "Component pipeline excludes routing/collector shutdown, UI and IPC",
                         "RSS is the Swift harness high-water before report serialization; ZIP subprocess memory is separate"]}
    write_json(root / "report.json", result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    os.umask(0o077)
    if not __debug__:
        raise SystemExit("Run without Python -O; integrity assertions must remain enabled.")
    if len(sys.argv) < 3 or sys.argv[1] not in ("prepare", "verify", "report"):
        raise SystemExit("Usage: CaptureSaveBenchmarkFixture.py prepare|report <private-root> OR verify <private-root> cold|warm")
    root = Path(sys.argv[2])
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise SystemExit("The fixture root must be a private directory owned by this user.")
    if sys.argv[1] == "prepare":
        prepare(root)
    elif sys.argv[1] == "verify":
        if len(sys.argv) != 4 or sys.argv[3] not in ("cold", "warm"):
            raise SystemExit("Verify requires cold or warm.")
        verify(root, sys.argv[3])
    else:
        report(root)
