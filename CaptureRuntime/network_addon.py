"""mitmproxy addon. Full bodies remain in native flows and base64 HAR fields."""
import base64
import datetime as dt
import json
import os
import re
import time
from pathlib import Path


def iso(timestamp=None):
    return dt.datetime.fromtimestamp(time.time() if timestamp is None else timestamp, dt.timezone.utc).isoformat().replace("+00:00", "Z")


class CaptureAddon:
    def __init__(self):
        self.root = Path(os.environ.get("CAPTURE_SESSION_DIR", ".")) / "network"
        self.entries = {}
        self.pending = {}
        self.missing_bodies = []
        nonce = os.environ.get("CAPTURE_SETUP_NONCE", "")
        self.setup_nonce = nonce if re.fullmatch(r"[0-9a-f]{32}", nonce) else None

    def setup_response(self, flow):
        """A nonce-bound browser TLS check, served by this existing proxy only."""
        if not self.setup_nonce or flow.request.host.lower() != "mitm.it":
            return
        prefix = "/mobile-capture-check/" + self.setup_nonce
        path = flow.request.path
        if path not in (prefix, prefix + "/https") or flow.request.method != "GET":
            return
        from mitmproxy import http
        headers = {"Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
                   "X-Content-Type-Options": "nosniff"}
        if path.endswith("/https"):
            if flow.request.scheme != "https":
                flow.response = http.Response.make(400, b"Use HTTPS for this check", headers)
                return
            payload = {"nonce": self.setup_nonce, "capture_check": "browser_https",
                       "message": "Synthetic capture check: caf\u00e9 \u65e5\u672c\u8a9e"}
            headers["Content-Type"] = "application/json; charset=utf-8"
            headers["Access-Control-Allow-Origin"] = "http://mitm.it"
            flow.response = http.Response.make(200, json.dumps(payload, ensure_ascii=False).encode(), headers)
        else:
            headers["Content-Type"] = "text/html; charset=utf-8"
            headers["Content-Security-Policy"] = "default-src 'none'; connect-src https://mitm.it; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
            target = "https://mitm.it" + prefix + "/https"
            page = """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mobile Capture Check</title><style>body{font:17px system-ui;max-width:40em;margin:3em auto;padding:1.5em;color-scheme:light dark}button{font:inherit;padding:1em;border-radius:.7em}p{line-height:1.5}</style>
<h1>Check HTTPS Capture</h1><p>Keep Mobile Capture checking on your Mac. This button sends synthetic text through its capture connection. It does not send app data to an external test service.</p>
<button id="check">Verify HTTPS</button><p id="status" role="status"></p>
<p>This verifies this browser's connection and certificate trust. Your Mac checks app logs separately. It does not verify every app or SDK, or your internet connection.</p>
<script>const b=document.getElementById('check'),s=document.getElementById('status');b.onclick=async()=>{b.disabled=true;s.textContent='Checking HTTPS…';try{const r=await fetch(TARGET,{cache:'no-store',credentials:'omit'});if(!r.ok)throw Error('The check returned '+r.status);const p=await r.json();if(p.nonce!==NONCE)throw Error('Use the current check link on your Mac');s.textContent='HTTPS captured. Return to Mobile Capture on your Mac.';}catch(e){s.textContent='HTTPS could not be verified. Check the capture certificate is installed and fully trusted, then try again. Your Mac has more details.';}finally{b.disabled=false;}};</script></html>"""
            page = page.replace("TARGET", json.dumps(target)).replace("NONCE", json.dumps(self.setup_nonce))
            flow.response = http.Response.make(200, page.encode(), headers)
        flow.metadata["mobile_capture_setup_nonce"] = self.setup_nonce

    def running(self):
        self.root.mkdir(parents=True, exist_ok=True)
        self.flush()
        (self.root / "ready.json").write_text(json.dumps({"pid": os.getpid(), "ready_at": iso()}))

    def event(self, kind, summary, flow=None, detail=None, timestamp=None):
        flow_id = getattr(flow, "id", None)
        request = getattr(flow, "request", None)
        payload = {"flow_id": flow_id}
        if flow is not None:
            payload["client_address"] = getattr(getattr(flow, "client_conn", None), "peername", None)
        if request:
            payload.update(method=request.method, url=request.pretty_url)
        if flow is not None and getattr(flow, "metadata", {}).get("mobile_capture_setup_nonce"):
            payload.update(setup_probe=True, setup_probe_nonce=flow.metadata["mobile_capture_setup_nonce"])
            transport = os.environ.get("CAPTURE_SETUP_TRANSPORT", "unknown")
            payload["setup_probe_transport"] = transport if transport in ("iphone_wireguard", "android_reverse", "simulator_proxy") else "unknown"
        payload.update(detail or {})
        event = {"id": f"network:{flow_id or time.time_ns()}:{kind}", "timestamp": iso(timestamp),
                 "original_timestamp": str(timestamp) if timestamp is not None else None,
                 "received_at": iso(), "source": "network", "kind": kind,
                 "summary": summary, "raw_ref": f"network/capture.mitm#{flow_id}" if flow_id else "network/events.jsonl",
                 "detail": payload, "clock_uncertainty_ms": 1}
        with (self.root / "events.jsonl").open("a", encoding="utf-8") as out:
            out.write(json.dumps(event, ensure_ascii=False) + "\n")

    @staticmethod
    def headers(message):
        return [{"name": str(k), "value": str(v)} for k, v in message.headers.items(multi=True)]

    @staticmethod
    def body(message):
        try:
            return message.content or b""
        except ValueError:
            return message.raw_content or b""

    def body_detail(self, message):
        if message.raw_content is None:
            return {"encoding": None, "text": None, "bytes": None, "unavailable": True,
                    "reason": "mitmproxy did not retain this body; this is not an empty body"}
        body = self.body(message)
        try:
            return {"encoding": "utf-8", "text": body.decode("utf-8"), "bytes": len(body)}
        except UnicodeDecodeError:
            return {"encoding": "base64", "text": base64.b64encode(body).decode("ascii"), "bytes": len(body)}

    def entry(self, flow):
        request, response = flow.request, flow.response
        request_body = self.body(request)
        end = (getattr(response, "timestamp_end", None) if response else None) or time.time()
        result = {"startedDateTime": iso(request.timestamp_start), "time": max(0, (end - request.timestamp_start) * 1000),
                  "request": {"method": request.method, "url": request.pretty_url,
                              "httpVersion": request.http_version, "cookies": [], "headers": self.headers(request),
                              "queryString": [{"name": k, "value": v} for k, v in request.query.items(multi=True)],
                              "headersSize": -1, "bodySize": len(request_body)},
                  "response": {"status": 0, "statusText": "Incomplete", "httpVersion": "", "cookies": [],
                               "headers": [], "content": {"size": 0, "mimeType": "", "text": "", "encoding": "base64"},
                               "redirectURL": "", "headersSize": -1, "bodySize": -1},
                  "cache": {}, "timings": {"send": 0, "wait": -1, "receive": 0},
                  "_flow_id": flow.id, "_incomplete": response is None}
        if request_body:
            result["request"]["postData"] = {"mimeType": request.headers.get("content-type", "application/octet-stream"),
                                                "text": base64.b64encode(request_body).decode("ascii"),
                                                "encoding": "base64", "_encoding": "base64"}
        if request.raw_content is None:
            result["request"]["_bodyUnavailable"] = True
            result["request"]["bodySize"] = -1
        if response:
            body = self.body(response)
            result["response"] = {"status": response.status_code, "statusText": response.reason,
                                  "httpVersion": response.http_version, "cookies": [], "headers": self.headers(response),
                                  "content": {"size": len(body), "mimeType": response.headers.get("content-type", ""),
                                              "text": base64.b64encode(body).decode("ascii"), "encoding": "base64"},
                                  "redirectURL": response.headers.get("location", ""), "headersSize": -1, "bodySize": len(body)}
            if response.raw_content is None:
                result["response"]["_bodyUnavailable"] = True
                result["response"]["bodySize"] = -1
                result["response"]["content"]["size"] = -1
        if getattr(flow, "error", None):
            result["_error"] = str(flow.error)
        return result

    def flush(self):
        payload = {"log": {"version": "1.2", "creator": {"name": "Capture Companion", "version": "0.1"},
                           "entries": list(self.entries.values()),
                           "comment": "Request postData uses the base64 encoding extension. Bodies are not truncated."}}
        temp = self.root / "capture.har.tmp"
        temp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        temp.replace(self.root / "capture.har")
        (self.root / "incomplete.json").write_text(json.dumps({"flow_ids": list(self.pending), "count": len(self.pending),
                                                              "missing_bodies": self.missing_bodies}))

    def request(self, flow):
        self.setup_response(flow)
        if flow.request.raw_content is None:
            self.missing_bodies.append({"flow_id": flow.id, "source": "request"})
        self.pending[flow.id] = flow
        self.entries[flow.id] = self.entry(flow)
        self.event("request", f"{flow.request.method} {flow.request.pretty_url}", flow,
                   {"request_headers": self.headers(flow.request), "request_body": self.body_detail(flow.request)}, flow.request.timestamp_start)
        self.flush()

    def response(self, flow):
        if flow.response.raw_content is None:
            self.missing_bodies.append({"flow_id": flow.id, "source": "response"})
        self.pending.pop(flow.id, None)
        self.entries[flow.id] = self.entry(flow)
        self.event("response", f"{flow.response.status_code} {flow.request.method} {flow.request.pretty_url}", flow,
                   {"status": flow.response.status_code, "request_headers": self.headers(flow.request),
                    "request_body": self.body_detail(flow.request), "response_headers": self.headers(flow.response),
                    "response_body": self.body_detail(flow.response)},
                   flow.response.timestamp_end or flow.response.timestamp_start)
        self.flush()

    def error(self, flow):
        self.pending.pop(flow.id, None)
        self.entries[flow.id] = self.entry(flow)
        self.event("error", f"Request failed: {flow.error}", flow, {"error": str(flow.error)})
        self.flush()

    def tls_failed_client(self, data):
        self.event("tls_error", "Client TLS handshake failed; check CA trust or certificate pinning",
                   detail={"error": str(getattr(getattr(data, "conn", None), "error", "TLS handshake failed"))})

    def done(self):
        for flow in self.pending.values():
            self.entries[flow.id] = self.entry(flow)
        self.flush()


addons = [CaptureAddon()]
