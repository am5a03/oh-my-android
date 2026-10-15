"""mitmproxy addon. Full bodies remain in native flows and base64 HAR fields."""
import base64
import datetime as dt
import json
import os
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

    def running(self):
        self.root.mkdir(parents=True, exist_ok=True)
        self.flush()
        (self.root / "ready.json").write_text(json.dumps({"pid": os.getpid(), "ready_at": iso()}))

    def event(self, kind, summary, flow=None, detail=None, timestamp=None):
        flow_id = getattr(flow, "id", None)
        request = getattr(flow, "request", None)
        payload = {"flow_id": flow_id}
        if request:
            payload.update(method=request.method, url=request.pretty_url)
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
