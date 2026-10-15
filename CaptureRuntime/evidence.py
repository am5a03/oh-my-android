"""Normalize capture evidence and build a portable, deterministic evidence ZIP.

This module deliberately has no device, proxy, subprocess, or third-party APIs.
Raw evidence is never rewritten or truncated. All paths admitted to a package are
explicitly named below; private runtime state is not an export source.
"""

from __future__ import annotations

import copy
import datetime as dt
import errno
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import unicodedata
import uuid
import zipfile


FORMAT = "device-capture-evidence"
SCHEMA_VERSION = 1
RAW_FILES = (
    "logs/device.log",
    "network/events.jsonl",
    "network/capture.har",
    "network/capture.mitm",
    "network/incomplete.json",
    "timeline/markers.jsonl",
)
PUBLIC_MANIFEST_KEYS = frozenset({
    "id", "platform", "device_id", "device_name", "started_at", "stopped_at",
    "ended_at", "phase", "sources", "warnings", "errors", "error", "failures",
    "counts", "routing_restored", "capture_logs", "capture_network", "target_app",
    "network_service", "network_diagnostics", "tool_versions", "app", "build", "context",
    "clock_calibration", "completeness", "collector_status", "collector_errors",
})
_SECRET_KEYS = frozenset({
    "token", "control_token", "auth_token", "access_token", "refresh_token",
    "password", "secret", "client_secret", "api_key", "private_key",
    "authorization", "credentials", "credential", "cookie", "cookies",
    "control", "runtime", "journal", "recovery_journal", "request_path",
    "output_root", "package_path", "directory", "ca_dir", "confdir",
})
_UTC = dt.timezone.utc
_EPOCH = dt.datetime(1970, 1, 1, tzinfo=_UTC)
_LOGCAT = re.compile(
    r"^[ \t]*(?P<timestamp>\d{9,}(?:\.\d{1,9})?)\s+"
    r"(?P<pid>\d+)\s+(?P<tid>\d+)\s+(?P<level>[VDIWEFAS])\s+"
    r"(?P<tag>.*?):\s?(?P<message>.*)$"
)
_SOURCE_ORDER = {"logs": 0, "network": 1, "marker": 2}


def _root(session_dir: Path) -> Path:
    session_dir = Path(session_dir)
    if session_dir.is_symlink():
        raise ValueError("The session directory must not be a symlink")
    result = session_dir.resolve(strict=True)
    if not result.is_dir():
        raise ValueError("The session path must be a directory")
    return result


def _read_relative(root: Path, relative: str) -> bytes | None:
    """Open each path component without following symlinks, including races."""
    parts = PurePosixPath(relative).parts
    if not parts or relative.startswith("/") or any(p in ("..", ".") for p in parts):
        raise ValueError("Evidence paths must be relative to the session")
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    descriptors = []
    try:
        parent = os.open(root, os.O_RDONLY | directory | nofollow)
        descriptors.append(parent)
        for part in parts[:-1]:
            parent = os.open(part, os.O_RDONLY | directory | nofollow, dir_fd=parent)
            descriptors.append(parent)
        descriptor = os.open(parts[-1], os.O_RDONLY | nofollow | os.O_NONBLOCK, dir_fd=parent)
        descriptors.append(descriptor)
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError(f"Evidence is not a regular file: {relative}")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise ValueError(f"Symlink traversal is not allowed: {relative}") from exc
        raise
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _state(root: Path) -> dict:
    for name in ("session.json", "manifest.json"):
        data = _read_relative(root, name)
        if data is None:
            continue
        try:
            value = json.loads(data)
            if isinstance(value, dict):
                return value.get("session", value) if isinstance(value.get("session", value), dict) else value
        except (ValueError, UnicodeDecodeError):
            continue
    return {}


def _number(value) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError, OverflowError):
        return None


def _datetime(value) -> dt.datetime | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        if isinstance(value, (float, int)) or (isinstance(value, str) and re.fullmatch(r"\d+(?:\.\d+)?", value.strip())):
            return dt.datetime.fromtimestamp(float(value), _UTC)
        text = str(value).strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        # Simulator log stream uses -0700; Python 3.9 expects -07:00.
        text = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", text)
        parsed = dt.datetime.fromisoformat(text)
        # A timezone-free device time must not silently acquire the Mac timezone.
        return parsed.astimezone(_UTC) if parsed.tzinfo is not None else None
    except (ValueError, TypeError, OverflowError, OSError):
        return None


def _iso(value: dt.datetime) -> str:
    return value.astimezone(_UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _calibration(state: dict, source: str) -> dict:
    values = state.get("clock_calibration", {})
    item = values.get(source, {}) if isinstance(values, dict) else {}
    return item if isinstance(item, dict) else {}


def _event(source: str, path: str, line_number: int, raw: bytes, value: dict, state: dict) -> dict:
    raw_time = value.get("timestamp", value.get("time", value.get("timestamp_start")))
    original = value.get("original_timestamp", raw_time)
    parsed = _datetime(raw_time)
    received = _datetime(value.get("received_at"))
    calibration = _calibration(state, source)
    offset = _number(calibration.get("offset_ms"))
    uncertainty = _number(calibration.get("uncertainty_ms"))
    event_uncertainty = _number(value.get("clock_uncertainty_ms"))
    if uncertainty is None and event_uncertainty is not None:
        uncertainty = event_uncertainty
    if uncertainty is not None and uncertainty < 0:
        uncertainty = None
    detail = copy.deepcopy(value.get("detail")) if isinstance(value.get("detail"), dict) else {}
    calibrated = parsed is not None and (offset is not None or event_uncertainty is not None)
    if parsed is not None:
        basis = "source_timestamp"
        if offset is not None:
            parsed += dt.timedelta(milliseconds=offset)
    elif received is not None:
        parsed, basis, uncertainty, calibrated = received, "received_at_fallback", None, False
    else:
        parsed = _datetime(state.get("started_at")) or _EPOCH
        basis = "session_start_fallback" if parsed != _EPOCH else "unavailable_epoch_sentinel"
        uncertainty, calibrated = None, False
    detail.update({"clock_calibrated": calibrated, "timestamp_basis": basis,
                   "temporal_matching": "inferred"})
    if offset is not None:
        detail["clock_offset_ms"] = offset
    if calibration.get("method"):
        detail["clock_method"] = str(calibration["method"])
    if value.get("raw_ref"):
        detail["native_ref"] = value["raw_ref"]
    if value.get("id"):
        detail["source_event_id"] = value["id"]
    identity = hashlib.sha256(source.encode() + b"\0" + path.encode() + b"\0" + str(line_number).encode() + b"\0" + raw).hexdigest()[:24]
    return {
        "id": "event-" + identity,
        "timestamp": _iso(parsed),
        "original_timestamp": str(original) if original is not None else None,
        "received_at": _iso(received) if received is not None else None,
        "source": source,
        "kind": str(value.get("kind", "log" if source == "logs" else source)),
        "summary": str(value.get("summary", "")),
        "raw_ref": f"{path}#L{line_number}",
        "detail": detail,
        "clock_uncertainty_ms": uncertainty,
    }


def _log_value(raw: bytes) -> dict:
    line = raw.decode("utf-8", errors="replace")
    match = _LOGCAT.match(line)
    if match:
        fields = match.groupdict()
        return {"timestamp": fields["timestamp"], "kind": "log", "summary": f'{fields["tag"].strip()}: {fields["message"]}',
                "detail": {"format": "android_logcat_epoch", "pid": int(fields["pid"]), "tid": int(fields["tid"]),
                           "level": fields["level"], "tag": fields["tag"].strip(), "message": fields["message"]}}
    try:
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError("Expected a JSON object")
        message = value.get("eventMessage", value.get("message", value.get("summary", line)))
        return {"timestamp": value.get("timestamp", value.get("date")), "received_at": value.get("received_at"),
                "kind": "log", "summary": str(message), "detail": {"format": "simulator_ndjson", "log": value}}
    except ValueError:
        return {"kind": "unparsed_log", "summary": line, "detail": {"format": "unparsed", "parse_error": "No supported timestamped log format"}}


def _json_value(raw: bytes, source: str) -> dict:
    try:
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError("Expected a JSON object")
        if source == "marker":
            value.setdefault("summary", value.get("text", "Marker"))
            value.setdefault("kind", "marker")
        else:
            request = value.get("request") if isinstance(value.get("request"), dict) else {}
            response = value.get("response") if isinstance(value.get("response"), dict) else {}
            detail = value.setdefault("detail", {})
            if not isinstance(detail, dict):
                detail = value["detail"] = {"original_detail": detail}
            for key, fallback in (("method", request.get("method")), ("url", request.get("url")),
                                  ("status", response.get("status", response.get("status_code"))), ("flow_id", value.get("flow_id"))):
                candidate = value.get(key, fallback)
                if candidate is not None:
                    detail.setdefault(key, candidate)
            if "summary" not in value:
                value["summary"] = " ".join(str(detail[k]) for k in ("status", "method", "url") if detail.get(k) is not None) or "Network event"
            value.setdefault("kind", "response" if response else "request" if request else "network")
        return value
    except (ValueError, UnicodeDecodeError) as exc:
        return {"kind": "parse_error", "summary": f"Unparsed {source} event", "detail": {"parse_error": str(exc)}}


def _read_events(root: Path, state: dict, raw_files: dict[str, bytes] | None = None) -> list[dict]:
    events = []
    for source, path in (("logs", "logs/device.log"), ("network", "network/events.jsonl"), ("marker", "timeline/markers.jsonl")):
        data = raw_files.get(path) if raw_files is not None else _read_relative(root, path)
        if data is None:
            continue
        for line_number, raw in enumerate(data.splitlines(), 1):
            if not raw.strip():
                continue
            value = _log_value(raw) if source == "logs" else _json_value(raw, source)
            events.append(_event(source, path, line_number, raw, value, state))
    events.sort(key=lambda item: (item["timestamp"], _SOURCE_ORDER[item["source"]], int(item["raw_ref"].rsplit("#L", 1)[1]), item["id"]))
    return events


def read_events(session_dir: Path, limit: int | None = None) -> list[dict]:
    """Return chronologically sorted events; a limit retains the latest events.

    No input is truncated. Unknown timestamps have an explicit fallback basis and
    null uncertainty. Timestamp proximity always describes an inferred match.
    """
    if limit is not None and (isinstance(limit, bool) or not isinstance(limit, int) or limit < 0):
        raise ValueError("limit must be a nonnegative integer or None")
    root = _root(session_dir)
    events = _read_events(root, _state(root))
    return events if limit is None else events[-limit:] if limit else []


def read_event_page(session_dir: Path, *, limit: int = 400, source: str = "all",
                    search: str = "", retain_from: str | None = None, older: int = 0) -> dict:
    """Filter the full session before paging; retain displayed history on refresh.

    The oldest displayed event is an anchor, not an offset: incoming device logs
    or network events cannot evict rows already being inspected. Loading older
    expands that same window. This is a view only; raw evidence is never changed.
    """
    for value in (limit, older):
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError("limit and older must be nonnegative integers")
    if source not in ("all", "logs", "network", "marker"):
        raise ValueError("Unknown timeline source")
    events = read_events(session_dir)
    # macOS process arguments may use decomposed Unicode while JSON bodies use
    # composed Unicode. Match canonically equivalent text in either form.
    def folded(value):
        return unicodedata.normalize("NFC", value).casefold()
    query = folded(search)
    matches = [event for event in events if (source == "all" or event["source"] == source)
               and (not query or query in folded(event["summary"] + " " + event["kind"] + " "
                    + event["raw_ref"] + " " + json.dumps(event["detail"], ensure_ascii=False, sort_keys=True)))]
    start = max(0, len(matches) - limit)
    if retain_from is not None:
        anchor = next((index for index, event in enumerate(matches) if event["id"] == retain_from), None)
        if anchor is not None:
            start = max(0, min(start, anchor - older))
    return {"events": matches[start:], "timeline": {"source": source, "search": search,
            "total_count": len(events), "matching_count": len(matches), "has_older": start > 0}}


def append_marker(session_dir: Path, text: str) -> dict:
    """Append one host-clock marker without interpreting text as shell code."""
    if not isinstance(text, str) or not text.strip():
        raise ValueError("Marker text must be a nonempty string")
    root = _root(session_dir)
    nofollow, directory = getattr(os, "O_NOFOLLOW", 0), getattr(os, "O_DIRECTORY", 0)
    descriptors = []
    try:
        parent = os.open(root, os.O_RDONLY | directory | nofollow)
        descriptors.append(parent)
        try:
            os.mkdir("timeline", mode=0o700, dir_fd=parent)
        except FileExistsError:
            pass
        timeline = os.open("timeline", os.O_RDONLY | directory | nofollow, dir_fd=parent)
        descriptors.append(timeline)
        marker_file = os.open("markers.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT | nofollow | os.O_NONBLOCK, 0o600, dir_fd=timeline)
        descriptors.append(marker_file)
        if not stat.S_ISREG(os.fstat(marker_file).st_mode):
            raise ValueError("The marker evidence path must be a regular file")
        timestamp = _iso(dt.datetime.now(_UTC))
        value = {"id": str(uuid.uuid4()), "timestamp": timestamp, "original_timestamp": timestamp,
                 "received_at": timestamp, "source": "marker", "kind": "marker", "summary": text,
                 "detail": {"text": text, "clock_method": "local_host_clock"}, "clock_uncertainty_ms": 1}
        data = _json_bytes(value) + b"\n"
        # One append write keeps normal concurrent UI markers as separate records.
        written = os.write(marker_file, data)
        if written != len(data):
            raise OSError("Could not append the complete marker")
        os.fsync(marker_file)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise ValueError("Symlink traversal is not allowed for markers") from exc
        raise
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
    # Resolve the exact stored record into the same event shape as read_events.
    for event in read_events(root):
        if event["detail"].get("source_event_id") == value["id"]:
            return event
    raise OSError("The appended marker could not be read back")


def _json_bytes(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _public(value):
    if isinstance(value, dict):
        return {str(key): _public(item) for key, item in value.items()
                if str(key).lower() not in _SECRET_KEYS and not str(key).lower().endswith(("_token", "_password", "_secret", "_private_key"))}
    if isinstance(value, (list, tuple)):
        return [_public(item) for item in value]
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return copy.deepcopy(value)


def _package_manifest(manifest: dict, raw_files: dict[str, bytes], events: list[dict]) -> dict:
    result = {key: _public(value) for key, value in manifest.items() if key in PUBLIC_MANIFEST_KEYS}
    result.update({"format": FORMAT, "schema_version": SCHEMA_VERSION,
                   "correlation": {"time_proximity": "inferred", "causal_matching_requires_shared_identifiers": True}})
    result["clock_calibration"] = {source: _public(_calibration(manifest, source)) or {"offset_ms": None, "uncertainty_ms": None, "method": "not_available"}
                                   for source in ("logs", "network")}
    result["clock_calibration"]["marker"] = {"offset_ms": 0, "uncertainty_ms": 1, "method": "local_host_clock"}
    counts = {source: sum(event["source"] == source for event in events) for source in _SOURCE_ORDER}
    result["counts"] = {"logs": counts["logs"], "network": counts["network"], "markers": counts["marker"]}
    original_sources = manifest.get("sources") if isinstance(manifest.get("sources"), dict) else {}
    sources = copy.deepcopy(_public(original_sources))
    warnings = result.get("warnings") if isinstance(result.get("warnings"), list) else []
    evidence_status = {}
    missing = []
    supplied_completeness = manifest.get("completeness")
    partial = (isinstance(supplied_completeness, dict) and bool(supplied_completeness.get("partial"))) or manifest.get("phase") in ("failed", "partial", "preparing", "recording", "stopping")
    for source, expected in (("logs", ("logs/device.log",)), ("network", ("network/events.jsonl", "network/capture.har", "network/capture.mitm"))):
        state = original_sources.get(source)
        requested = manifest.get("capture_" + source)
        if not isinstance(requested, bool):
            requested = state != "not_selected" if state is not None else None
        absent = [path for path in expected if path not in raw_files] if requested else []
        missing.extend(absent)
        decoded_http_events = sum(event["source"] == "network" and event["kind"] in ("request", "response") for event in events)
        observed = decoded_http_events > 0 if source == "network" else counts[source] > 0
        if state == "observed" and not observed:
            sources[source] = "failed" if absent else "started"
            warnings.append(f"{source}: supplied observed status has no corresponding timeline evidence")
        if state in ("failed", "interrupted") or absent:
            partial = True
        evidence_status[source] = {"requested": requested, "events": counts[source],
                                   "observed": observed, "missing_artifacts": absent,
                                   "empty_artifacts": [path for path in expected if path in raw_files and not raw_files[path]],
                                   "runtime_status": state}
        if source == "network":
            evidence_status[source]["decoded_http_events"] = decoded_http_events
    pending = set()
    errors = []
    for event in events:
        if event["source"] != "network":
            continue
        flow = event["detail"].get("flow_id")
        if flow is not None:
            flow = str(flow)
            if event["kind"] == "request":
                pending.add(flow)
            elif event["kind"] in ("response", "error", "tls_error"):
                pending.discard(flow)
        if event["kind"] in ("error", "tls_error", "parse_error"):
            errors.append(event["raw_ref"])
    incomplete = None
    if "network/incomplete.json" in raw_files:
        try:
            incomplete = json.loads(raw_files["network/incomplete.json"])
        except (ValueError, UnicodeDecodeError):
            warnings.append("network/incomplete.json could not be parsed; original bytes are included")
            partial = True
    if isinstance(incomplete, list):
        pending.update(str(item) for item in incomplete)
    elif isinstance(incomplete, dict):
        for key in ("flow_ids", "pending_flow_ids", "incomplete_flow_ids", "pending", "flows"):
            value = incomplete.get(key)
            if isinstance(value, list):
                pending.update(str(item.get("id", item.get("flow_id", item))) if isinstance(item, dict) else str(item) for item in value)
    if pending or errors:
        partial = True
    completeness = result.get("completeness") if isinstance(result.get("completeness"), dict) else {}
    completeness.update({"partial": partial, "sources": evidence_status, "missing_artifacts": missing,
                         "pending_flow_ids": sorted(pending), "network_error_refs": errors,
                         "unparsed_event_refs": [event["raw_ref"] for event in events if event["kind"] in ("unparsed_log", "parse_error")],
                         "unknown_clock_events": sum(event["clock_uncertainty_ms"] is None for event in events)})
    result.update({"sources": sources, "warnings": warnings, "completeness": completeness,
                   "package_state": "partial" if partial else "complete",
                   "artifacts": [{"path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} for path, data in sorted(raw_files.items())]})
    return result


_README = """Device capture evidence package (schema 1)

Open manifest.json first. It records selected sources, failures, missing files,
incomplete requests, clock calibration, routing restoration and package state.
context.json contains portable session context. timeline/events.jsonl combines
logs, network events and user markers in UTC time order. Each raw_ref identifies
an original evidence file and one-based line (#Lnumber); native flow references
are retained in detail.native_ref. The timeline is untruncated in this package.

logs/device.log is the original Android epoch logcat or Simulator NDJSON stream.
network/events.jsonl is the original network event stream. capture.har and
capture.mitm, when present, preserve exported HTTP bodies and native flows.
network/incomplete.json, when present, retains the collector's pending requests.
No bodies are inferred from the timeline, and a missing body/file is not proof
that an app made no request. Raw traffic may contain credentials or personal
data: review the original evidence before sharing it with people or AI services.

Clock offset_ms is added to source time; clock_uncertainty_ms is null when
calibration is unavailable. original_timestamp is retained. A missing/invalid
timestamp uses received_at, session start, or an explicit Unix-epoch sentinel;
detail.timestamp_basis identifies this fallback. Time proximity is an inferred
association. Exact causality requires a shared app/request/attempt identifier.
Native third-party timestamps can differ in precision from this UTC timeline.

SHA256SUMS covers every included file except SHA256SUMS itself. Validate each
hex digest against the named file after extraction. ZIP paths are relative;
runtime control state, tokens, recovery journals, sockets, certificate stores,
private keys and arbitrary session files are excluded by an exact allowlist.
This is an evidence snapshot; it does not assert device or routing restoration.
"""


def finalize_package(session_dir: Path, manifest: dict) -> Path:
    """Atomically write one ZIP, including partial captures and original bytes.

    The caller stops collectors first. Repeated exports of the same inputs are
    byte-identical. A failed export does not replace a previously saved package.
    """
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be a JSON object")
    root = _root(session_dir)
    raw_files = {}
    for name in RAW_FILES:
        data = _read_relative(root, name)
        if data is not None:
            raw_files[name] = data
    state = copy.deepcopy(manifest)
    events = _read_events(root, state, raw_files)
    public_manifest = _package_manifest(state, raw_files, events)
    context = {key: public_manifest[key] for key in ("id", "platform", "device_id", "device_name", "started_at", "stopped_at", "ended_at", "target_app", "app", "build", "tool_versions", "context") if key in public_manifest}
    context["correlation"] = public_manifest["correlation"]
    files = dict(raw_files)
    files.update({"manifest.json": _json_bytes(public_manifest) + b"\n",
                  "context.json": _json_bytes(context) + b"\n",
                  "timeline/events.jsonl": b"".join(_json_bytes(event) + b"\n" for event in events),
                  "README.txt": _README.encode("utf-8")})
    files["SHA256SUMS"] = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(files.items())).encode("utf-8")
    destination = root / "capture-package.zip"
    if destination.is_symlink():
        raise ValueError("The package destination must not be a symlink")
    descriptor, temporary = tempfile.mkstemp(prefix=".capture-package-", suffix=".tmp", dir=root)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                archive.writestr(info, data)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return destination
