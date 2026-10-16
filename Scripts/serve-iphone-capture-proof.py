#!/usr/bin/env python3
"""Serve a neutral iPhone Safari proof, or verify its receipt against a saved capture.

No listener or outbound request starts unless the explicit `serve` command is used.
Only the phone's Run Capture Proof button sends the public HTTPS request.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit
import zipfile


TARGET = "https://httpbingo.org/anything"
MAX_RECEIPT_BYTES = 128 * 1024
NONCE = re.compile(r"[A-Za-z0-9._-]{8,128}\Z")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def private_write(path: Path, value: dict) -> None:
    data = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def decode_base64(value: object) -> bytes:
    if not isinstance(value, str):
        raise ValueError("Expected a base64 string")
    return base64.b64decode(value, validate=True)


def body(value: dict) -> bytes:
    text = value.get("text", "")
    if value.get("encoding", value.get("_encoding")) == "base64":
        return decode_base64(text)
    if not isinstance(text, str) or value.get("unavailable"):
        raise ValueError("Captured body unavailable")
    return text.encode("utf-8")


def raw_lines(stream):
    """Match the capture index's LF, CRLF and bare-CR line numbering in chunks."""
    pending = b""
    while True:
        chunk = stream.read(1024 * 1024)
        pending += chunk
        start = 0
        for ending in re.finditer(br"\r\n|\r|\n", pending):
            if chunk and ending.group() == b"\r" and ending.end() == len(pending):
                break  # The following chunk may supply the LF of this CRLF.
            yield pending[start:ending.start()]
            start = ending.end()
        pending = pending[start:]
        if not chunk:
            if pending:
                yield pending
            return


def validate_receipt(value: dict, nonce: str) -> dict:
    if value.get("schema_version") != 1 or value.get("proof_nonce") != nonce:
        raise ValueError("Receipt nonce/schema mismatch")
    if value.get("method") != "POST" or value.get("url") != TARGET:
        raise ValueError("Unexpected proof request")
    request = decode_base64(value.get("request_body_base64"))
    payload = json.loads(request)
    if not isinstance(payload, dict) or payload.get("capture_proof") != nonce or payload.get("proof_kind") != "physical-iphone-safari":
        raise ValueError("Request does not contain this neutral Safari proof")
    if len(request) > 32 * 1024:
        raise ValueError("Proof request is larger than the neutral fixture")
    response = decode_base64(value.get("response_body_base64"))
    if len(response) > MAX_RECEIPT_BYTES:
        raise ValueError("Proof response exceeds receipt limit")
    result = dict(value)
    result.update(request_bytes=len(request), response_bytes=len(response),
                  request_sha256=hashlib.sha256(request).hexdigest(),
                  response_sha256=hashlib.sha256(response).hexdigest())
    for key in ("request_sha256", "response_sha256", "request_bytes", "response_bytes"):
        if key in value and value[key] != result[key]:
            raise ValueError("Saved receipt digest/size mismatch")
    return result


PAGE = r'''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mobile Capture · iPhone Proof</title>
<style>
:root{color-scheme:light dark;font:17px -apple-system,BlinkMacSystemFont,sans-serif}body{max-width:38rem;margin:3rem auto;padding:0 1.25rem;line-height:1.5}h1{font-size:1.8rem;line-height:1.15}button{font:inherit;font-weight:600;padding:.9rem 1.2rem;border:0;border-radius:.8rem;background:#007aff;color:white}button:disabled{opacity:.55}#status{padding:1rem 0;font-weight:600}small{display:block;opacity:.7;overflow-wrap:anywhere}code{overflow-wrap:anywhere}p{margin:1rem 0}
</style>
<h1>iPhone Capture Proof</h1>
<p>Keep Mobile Capture recording with the phone tunnel on. Run this proof once to send a neutral HTTPS request with Unicode and a long body.</p>
<button id="run" type="button">Run Capture Proof</button>
<div id="status" role="status" aria-live="polite">Ready.</div>
<small>Proof: <code id="nonce"></code></small>
<p>This page sends synthetic text to httpbingo.org. It sends no cookies or personal app data. The response is saved privately on your Mac for a byte-for-byte comparison.</p>
<small>Device logs are captured only when selected in Mobile Capture. Safari does not add a custom application log marker.</small>
<script>
'use strict';
const nonce = __NONCE__;
const target = __TARGET__;
const run = document.getElementById('run');
const status = document.getElementById('status');
document.getElementById('nonce').textContent = nonce;
function asBase64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}
async function localPost(path, value) {
  const response = await fetch(path, {method:'POST', headers:{'Content-Type':'application/json'},
    body:JSON.stringify(value), credentials:'omit', cache:'no-store'});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'The Mac could not save the proof.');
  return result;
}
run.addEventListener('click', async () => {
  run.disabled = true;
  status.textContent = 'Preparing the one-time proof…';
  let receipt;
  try {
    await localPost('/begin', {proof_nonce:nonce});
    const payload = {capture_proof:nonce, proof_kind:'physical-iphone-safari',
      message:'Neutral capture proof · café · e\u0301 · 中文 · 🧭',
      padding:'abcdefghijklmnopqrstuvwxyz0123456789'.repeat(128)};
    // JSON.stringify plus TextEncoder provides the exact UTF-8 request bytes.
    const requestText = JSON.stringify(payload);
    receipt = {schema_version:1, proof_nonce:nonce, method:'POST', url:target,
      started_at:new Date().toISOString(), request_headers:{'Content-Type':'application/json'},
      request_body_base64:asBase64(new TextEncoder().encode(requestText))};
    status.textContent = 'Sending the neutral HTTPS request…';
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000);
    try {
      const response = await fetch(target, {method:'POST', headers:receipt.request_headers,
        body:requestText, credentials:'omit', referrerPolicy:'no-referrer', cache:'no-store', signal:controller.signal});
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.length > __MAX__) throw new Error('Response exceeds the proof receipt limit.');
      receipt.http_status = response.status;
      receipt.response_body_base64 = asBase64(bytes);
      receipt.completed_at = new Date().toISOString();
    } finally { clearTimeout(timeout); }
    status.textContent = 'Saving the full response on your Mac…';
    await localPost('/receipt', receipt);
    if (receipt.http_status !== 200) throw new Error('The endpoint returned HTTP ' + receipt.http_status + '. The receipt was saved for diagnosis.');
    status.textContent = 'Proof saved. Turn the phone tunnel off, then finish Stop & Save in Mobile Capture.';
  } catch (error) {
    if (receipt && receipt.response_body_base64 === undefined) {
      receipt.http_status = null; receipt.response_body_base64 = '';
      receipt.completed_at = new Date().toISOString(); receipt.browser_error = String(error);
      try { await localPost('/receipt', receipt); } catch (_) {}
    }
    status.textContent = 'Proof failed: ' + String(error.message || error) + ' Check certificate trust and the tunnel. Use a fresh proof link for another attempt.';
  }
});
</script></html>'''


class ProofServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, host: str, port: int, directory: Path, nonce: str):
        self.directory = directory
        self.nonce = nonce
        self.origin = f"http://{host}:{port}"
        self.receipt_path = directory / f"receipt-{nonce}.json"
        self.attempt_path = directory / f"attempt-{nonce}.json"
        self.state_lock = threading.Lock()
        if self.receipt_path.exists() or self.attempt_path.exists():
            raise ValueError("This nonce was already used. Start with a fresh proof nonce.")
        super().__init__((host, port), ProofHandler)


class ProofHandler(BaseHTTPRequestHandler):
    server: ProofServer

    def log_message(self, _format: str, *_args: object) -> None:
        pass  # Browser receipts and payloads stay private; readiness/result summaries are explicit.

    def send(self, status: int, data: bytes, content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self' https://httpbingo.org")
        self.end_headers()
        self.wfile.write(data)

    def reply(self, status: int, value: dict) -> None:
        self.send(status, json.dumps(value).encode("utf-8"))

    def do_GET(self) -> None:
        url = urlsplit(self.path)
        if url.path != "/" or parse_qs(url.query).get("nonce") != [self.server.nonce]:
            self.reply(404, {"error": "Open the explicit proof URL from your Mac."})
            return
        page = PAGE.replace("__NONCE__", json.dumps(self.server.nonce)).replace("__TARGET__", json.dumps(TARGET)).replace("__MAX__", str(MAX_RECEIPT_BYTES))
        self.send(200, page.encode("utf-8"), "text/html; charset=utf-8")

    def do_POST(self) -> None:
        if self.path not in ("/begin", "/receipt"):
            self.reply(404, {"error": "Unknown proof route"})
            return
        if self.headers.get("Origin") not in (None, self.server.origin):
            self.reply(403, {"error": "Use the proof page served by this Mac."})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_RECEIPT_BYTES:
                raise ValueError("Receipt must be no larger than 128 KiB")
            if self.headers.get_content_type() != "application/json":
                raise ValueError("Expected a JSON proof receipt")
            value = json.loads(self.rfile.read(length))
            if not isinstance(value, dict) or value.get("proof_nonce") != self.server.nonce:
                raise ValueError("Proof nonce mismatch")
            with self.server.state_lock:
                if self.path == "/begin":
                    private_write(self.server.attempt_path, {"proof_nonce": self.server.nonce, "started_at": utc_now()})
                else:
                    if not self.server.attempt_path.is_file():
                        raise ValueError("Start the proof from its page first")
                    receipt = validate_receipt(value, self.server.nonce)
                    receipt.update(saved_at=utc_now(), receipt_client_address=self.client_address[0])
                    if len(json.dumps(receipt, ensure_ascii=False, indent=2).encode("utf-8")) + 1 > MAX_RECEIPT_BYTES:
                        raise ValueError("Saved receipt would exceed 128 KiB")
                    private_write(self.server.receipt_path, receipt)
                    print(json.dumps({"receipt_saved": str(self.server.receipt_path), "http_status": receipt.get("http_status"),
                                      "request_bytes": receipt["request_bytes"], "response_bytes": receipt["response_bytes"],
                                      "response_sha256": receipt["response_sha256"]}), flush=True)
            self.reply(200, {"saved": True})
        except FileExistsError:
            self.reply(409, {"error": "This proof was already attempted. Use a fresh proof link."})
        except (ValueError, TypeError, KeyError) as error:
            self.reply(400, {"error": str(error)})


def verify(package: Path, receipt_path: Path, nonce: str, require_native: bool, tunnel_ip: str, network_only: bool = False) -> dict:
    receipt_data = receipt_path.read_bytes()
    assert len(receipt_data) <= MAX_RECEIPT_BYTES, "Receipt exceeds the bounded proof size"
    receipt = validate_receipt(json.loads(receipt_data), nonce)
    assert receipt.get("http_status") == 200 and not receipt.get("browser_error"), "Safari did not obtain a successful response"
    expected_request = decode_base64(receipt["request_body_base64"])
    expected_response = decode_base64(receipt["response_body_base64"])
    payload = json.loads(expected_request)
    assert len(payload.get("padding", "")) >= 4096, "Long request proof missing"
    assert any(ord(character) > 127 for character in payload.get("message", "")), "Unicode request proof missing"
    assert json.loads(expected_response)["json"]["capture_proof"] == nonce, "Safari response did not echo this nonce"
    with zipfile.ZipFile(package) as archive:
        names = archive.namelist()
        assert len(names) == len(set(names)), "Duplicate ZIP names"
        names = set(names)
        assert all(not PurePosixPath(name).is_absolute() and ".." not in PurePosixPath(name).parts for name in names), "Unsafe ZIP path"
        required = {"manifest.json", "SHA256SUMS", "timeline/events.jsonl", "timeline/markers.jsonl", "network/events.jsonl",
                    "network/capture.har", "network/capture.mitm"}
        if not network_only:
            required.add("logs/device.log")
        assert required <= names, "The proof package is missing an evidence source"
        allowed = required | {"context.json", "README.txt", "network/incomplete.json"}
        assert names <= allowed, "Unexpected/private file outside the evidence allowlist"
        checked = set()
        for line in archive.read("SHA256SUMS").decode("utf-8").splitlines():
            expected, name = line.split("  ", 1)
            assert re.fullmatch(r"[a-fA-F0-9]{64}", expected) and name not in checked, "Invalid checksum listing"
            digest = hashlib.sha256()
            with archive.open(name) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            assert digest.hexdigest() == expected.lower(), f"Checksum mismatch: {name}"
            checked.add(name)
        assert checked == {name for name in names if not name.endswith("/")} - {"SHA256SUMS"}, "Checksums do not cover the complete package"
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["platform"] == "iphone", "Expected physical iPhone capture"
        assert manifest.get("routing_restored") is True, "Phone tunnel-off confirmation/restoration unverified"
        if network_only:
            assert manifest["sources"].get("logs") == "not_selected", "Network-only verification requires device logs not selected during recording"
        else:
            assert manifest["sources"]["logs"] in ("observed", "interrupted"), "USB device logs unavailable"
        assert manifest["sources"]["network"] in ("observed", "interrupted"), "Network evidence unavailable"
        entries = []
        for entry in json.loads(archive.read("network/capture.har"))["log"]["entries"]:
            try:
                candidate = json.loads(body(entry["request"].get("postData", {})))
                if isinstance(candidate, dict) and candidate.get("capture_proof") == nonce:
                    entries.append(entry)
            except (ValueError, TypeError, UnicodeDecodeError):
                continue
        assert len(entries) == 1, "Expected one fresh POST flow with this proof nonce"
        entry = entries[0]
        assert entry["request"]["method"] == "POST" and entry["request"]["url"] == TARGET, "Unexpected proof endpoint/method"
        assert entry["response"]["status"] == 200, "HAR proof response is not HTTP 200"
        assert body(entry["request"]["postData"]) == expected_request, "Safari and HAR request bytes differ"
        assert body(entry["response"]["content"]) == expected_response, "Safari and HAR response bytes differ"
        flow_id = entry["_flow_id"]
        # Phone OS logs can be hundreds of megabytes. Retain line-number sets plus
        # only this proof's small evidence objects, not the complete JSON timeline.
        references: dict[str, set[int]] = {}
        selected: list[dict] = []
        logs = 0
        markers = []
        flow_events = []
        event_count = 0
        with archive.open("timeline/events.jsonl") as stream:
            for row in stream:
                if not row.strip():
                    continue
                event = json.loads(row)
                event_count += 1
                assert not network_only or event["source"] != "logs", "Network-only timeline unexpectedly contains device logs"
                match = re.fullmatch(r"([^#]+)#L([1-9][0-9]*)", event["raw_ref"])
                assert match and match[1] in names, "Timeline raw reference missing from package"
                relative, line = match[1], int(match[2])
                assert line <= archive.getinfo(relative).file_size + 1, "Timeline line reference exceeds possible source size"
                expected_path = {"logs": "logs/device.log", "network": "network/events.jsonl", "marker": "timeline/markers.jsonl"}[event["source"]]
                assert relative == expected_path, "Timeline raw reference belongs to another source"
                lines = references.setdefault(relative, set())
                assert line not in lines, "Duplicate timeline raw reference"
                lines.add(line)
                if event["source"] == "logs" and event["kind"] == "log" and event["detail"].get("format") == "iphone_idevicesyslog_utc":
                    assert event["detail"].get("timestamp_basis") == "source_timestamp", "USB log source timestamp missing"
                    logs += 1
                    if logs == 1:
                        selected.append(event)
                elif event["source"] == "marker" and nonce in event["summary"]:
                    markers.append(event); selected.append(event)
                elif event["source"] == "network" and event["detail"].get("flow_id") == flow_id:
                    flow_events.append(event); selected.append(event)
        if not network_only:
            assert logs, "Parsed, timestamped iPhone USB logs missing"
        assert markers, "Nonce user marker missing from shared timeline"
        wanted = {event["raw_ref"] for event in selected}
        source_lines = {}
        for relative, lines in references.items():
            with archive.open(relative) as stream:
                for number, raw in enumerate(raw_lines(stream), 1):
                    if number not in lines:
                        continue
                    assert raw.strip(), "Timeline raw reference points to an empty line"
                    lines.remove(number)
                    reference = f"{relative}#L{number}"
                    if reference in wanted:
                        source_lines[reference] = raw
            assert not lines, "Timeline raw reference outside original evidence"
        for event in selected:
            if event["source"] == "logs":
                assert event["detail"].get("raw_line") == source_lines[event["raw_ref"]].decode("utf-8"), "Parsed USB log differs from its raw line"
        for event in markers:
            original = json.loads(source_lines[event["raw_ref"]])
            assert nonce in original.get("summary", original.get("text", "")), "Nonce marker differs from its raw evidence"
        requests = [event for event in flow_events if event["kind"] == "request"]
        responses = [event for event in flow_events if event["kind"] == "response"]
        assert requests and responses, "Both network phases must appear in the shared timeline"
        for event in requests + responses:
            detail = event["detail"]
            assert body(detail["request_body"]) == expected_request, "Normalized request bytes differ from Safari"
            address = detail.get("client_address")
            assert isinstance(address, list) and address[0] == tunnel_ip, "Proof did not originate from the expected phone tunnel address"
            native_ref = detail.get("native_ref")
            assert native_ref == "network/capture.mitm#" + flow_id, "Timeline native flow reference mismatch"
            original = json.loads(source_lines[event["raw_ref"]])
            assert original["detail"]["flow_id"] == flow_id, "Raw event points at another flow"
            assert body(original["detail"]["request_body"]) == expected_request, "Raw network request differs from Safari"
            if event["kind"] == "response":
                assert body(original["detail"]["response_body"]) == expected_response, "Raw network response differs from Safari"
        assert all(body(event["detail"]["response_body"]) == expected_response for event in responses), "Normalized response bytes differ from Safari"
        native_parity = False
        if require_native:
            from mitmproxy import io
            with tempfile.TemporaryFile() as stream:
                with archive.open("network/capture.mitm") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        stream.write(chunk)
                stream.seek(0)
                flows = [flow for flow in io.FlowReader(stream).stream() if flow.id == flow_id]
                assert len(flows) == 1, "Native proof flow missing or duplicated"
                flow = flows[0]
                assert flow.request.content == expected_request, "Native request bytes differ from Safari"
                assert flow.response and flow.response.status_code == 200 and flow.response.content == expected_response, "Native response bytes differ from Safari"
                assert flow.client_conn.peername and flow.client_conn.peername[0] == tunnel_ip, "Native flow client does not match phone tunnel"
                native_parity = True
        return {"platform": "iphone", "proof_mode": "safari", "proof_scope": "network_only" if network_only else "combined",
                "session_id": manifest["id"], "package": str(package),
                "receipt": str(receipt_path), "proof_nonce": nonce, "http_status": 200, "flow_id": flow_id,
                "request_bytes": len(expected_request), "response_bytes": len(expected_response),
                "request_sha256": receipt["request_sha256"], "response_sha256": receipt["response_sha256"],
                "network_client_address": tunnel_ip, "native_har_safari_body_parity": native_parity,
                "parsed_usb_log_events": logs, "timeline_events": event_count, "package_files": len(names),
                "sources": manifest["sources"], "routing_restored": True,
                "device_log_correlation": "Device logs not selected; this proof verifies network and user markers only" if network_only
                    else "USB logs coexist in the timeline; Safari provides no custom app/request log marker"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Bind only the explicit Mac LAN address and serve the one-time phone page")
    serve.add_argument("--host", required=True, help="Explicit Mac private LAN IPv4 address; not 0.0.0.0 or loopback")
    serve.add_argument("--port", type=int, required=True)
    serve.add_argument("--directory", type=Path, required=True, help="Dedicated private receipt folder, outside the repository")
    serve.add_argument("--nonce", required=True)
    check = commands.add_parser("verify", help="Offline receipt/package verification; does not bind or send requests")
    check.add_argument("--package", type=Path, required=True)
    check.add_argument("--receipt", type=Path, required=True)
    check.add_argument("--nonce", required=True)
    check.add_argument("--phone-tunnel-ip", default="10.0.0.1")
    check.add_argument("--network-only", action="store_true", help="Verify a session recorded with device logs not selected; makes no USB-log claim")
    check.add_argument("--require-native", action="store_true", help="Also compare native flow bodies; requires mitmproxy Python environment")
    check.add_argument("--report", type=Path)
    args = parser.parse_args()
    if not NONCE.fullmatch(args.nonce):
        parser.error("Use a fresh neutral 8–128 character alphanumeric proof nonce (dots, underscores and hyphens allowed)")
    if args.command == "verify":
        result = verify(args.package, args.receipt, args.nonce, args.require_native, args.phone_tunnel_ip, args.network_only)
        if args.report:
            private_write(args.report, result)
        print(json.dumps(result, indent=2))
        return
    try:
        address = ipaddress.IPv4Address(args.host)
        if not address.is_private or address.is_loopback or address.is_unspecified or address.is_multicast or address.is_link_local:
            raise ValueError("Use the Mac's explicit private LAN IPv4 address")
        if not 1024 <= args.port <= 65535:
            raise ValueError("Choose an explicit unprivileged port between 1024 and 65535")
        if not args.directory.is_absolute():
            raise ValueError("Receipt directory must be an absolute private path")
        directory = args.directory.resolve()
        repository = Path(__file__).resolve().parent.parent
        if directory == repository or repository in directory.parents:
            raise ValueError("Keep private proof receipts outside the repository")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = directory.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Receipt directory must be owned by you with mode 0700")
        with ProofServer(str(address), args.port, directory, args.nonce) as server:
            print(json.dumps({"proof_url": f"{server.origin}/?nonce={args.nonce}", "receipt": str(server.receipt_path),
                              "next_action": "Add a timeline marker containing the nonce, then open this URL in iPhone Safari and tap Run Capture Proof once."}), flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
