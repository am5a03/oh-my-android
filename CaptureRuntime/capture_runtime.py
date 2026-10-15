#!/usr/bin/env python3
"""Generic, local capture coordinator. Stdout is a single JSON CLI response."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import glob
import json
import os
import plistlib
import secrets
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
PROXY_KEYS = ("http_proxy", "global_http_proxy_host", "global_http_proxy_port", "global_http_proxy_exclusion_list", "global_proxy_pac_url")
ANDROID_CLEARED_PROXY = {"http_proxy": ":0", "global_http_proxy_host": "", "global_http_proxy_port": "0",
                         "global_http_proxy_exclusion_list": "", "global_proxy_pac_url": ""}
ACTIVE_PHASES = {"preparing", "recording", "stopping"}


class CaptureError(RuntimeError):
    pass


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(temp, 0o600)
    temp.replace(path)


def run(command, *, input_data=None, timeout=20, check=True):
    try:
        result = subprocess.run([str(x) for x in command], input=input_data, capture_output=True,
                                text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CaptureError(f"Cannot run {Path(str(command[0])).name}: {exc}") from exc
    if check and result.returncode:
        detail = (result.stderr.strip() or result.stdout.strip())[-1800:]
        raise CaptureError(f"{Path(str(command[0])).name} failed ({result.returncode}): {detail}")
    return result


def executable(explicit, name, candidates=()):
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
            raise CaptureError(f"{name}_path must be an absolute executable file: {explicit}")
        return str(path)
    found = shutil.which(name)
    if found:
        return found
    for candidate in candidates:
        for match in sorted(glob.glob(str(Path(candidate).expanduser())), reverse=True):
            if Path(match).is_file() and os.access(match, os.X_OK):
                return match
    return None


def tools_for(request=None):
    request = request or {}
    adb = executable(request.get("adb_path"), "adb", ["~/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb"])
    mitm = executable(request.get("mitmdump_path"), "mitmdump", [
        "/opt/homebrew/bin/mitmdump", "/usr/local/bin/mitmdump", "~/.local/bin/mitmdump",
        "/opt/homebrew/Caskroom/mitmproxy/*/mitmproxy.app/Contents/MacOS/mitmdump",
        "/usr/local/Caskroom/mitmproxy/*/mitmproxy.app/Contents/MacOS/mitmdump",
        "/opt/homebrew/Caskroom/mitmproxy/*/mitmdump", "/usr/local/Caskroom/mitmproxy/*/mitmdump",
        "/Applications/mitmproxy.app/Contents/MacOS/mitmdump"])
    simctl = request.get("simctl_path")
    if not simctl and Path("/usr/bin/xcrun").exists():
        result = run(["/usr/bin/xcrun", "--find", "simctl"], check=False)
        if result.returncode == 0:
            simctl = result.stdout.strip()
    return {"adb": adb, "mitmdump": mitm, "simctl": simctl, "python": sys.executable}


def list_devices(tools):
    devices = []
    if tools.get("adb"):
        result = run([tools["adb"], "devices", "-l"], check=False)
        for line in result.stdout.splitlines()[1:]:
            fields = line.split()
            if len(fields) < 2:
                continue
            metadata = dict(part.split(":", 1) for part in fields[2:] if ":" in part)
            devices.append({"id": fields[0], "name": metadata.get("model", fields[0]).replace("_", " "),
                            "platform": "android", "state": "ready" if fields[1] == "device" else fields[1]})
    if tools.get("simctl"):
        result = run([tools["simctl"], "list", "devices", "available", "--json"], check=False)
        if result.returncode == 0:
            payload = json.loads(result.stdout)
            for group in payload.get("devices", {}).values():
                for device in group:
                    devices.append({"id": device["udid"], "name": device.get("name", device["udid"]),
                                    "platform": "simulator", "state": "booted" if device.get("state") == "Booted" else device.get("state", "unknown").lower()})
    return devices


def network_services():
    path = "/usr/sbin/networksetup"
    if not Path(path).exists():
        return []
    result = run([path, "-listallnetworkservices"], check=False)
    return [line for line in result.stdout.splitlines()[1:] if line and not line.startswith("*")]


def evidence_module():
    import evidence
    return evidence


def response(session_dir, *, cap=400, source="all", search="", retain_from=None, older=0):
    state = read_json(Path(session_dir) / "session.json")
    if not state:
        raise CaptureError("Session not found. Select its capture directory.")
    page = evidence_module().read_event_page(Path(session_dir), limit=cap, source=source,
                                             search=search, retain_from=retain_from, older=older)
    state["counts"] = {source: 0 for source in ("logs", "network", "markers")}
    diagnostics = {"decoded_http_events": 0, "tls_errors": 0, "certificate_rejections": 0, "request_errors": 0}
    # Counts are raw source counts, including request/response events separately.
    for source, relative in (("logs", "logs/device.log"), ("network", "network/events.jsonl"), ("markers", "timeline/markers.jsonl")):
        path = Path(session_dir) / relative
        if path.exists():
            with path.open("rb") as stream:
                state["counts"][source] = sum(1 for _ in stream)
            observed = bool(state["counts"][source])
            if source == "network":
                observed = False
                with path.open(encoding="utf-8") as stream:
                    for line in stream:
                        try:
                            event = json.loads(line)
                            kind = event.get("kind")
                            if kind in ("request", "response"):
                                observed = True
                                diagnostics["decoded_http_events"] += 1
                            elif kind == "tls_error":
                                diagnostics["tls_errors"] += 1
                                error = str(event.get("detail", {}).get("error", "")).lower()
                                if "does not trust" in error or "certificate unknown" in error or "unknown ca" in error:
                                    diagnostics["certificate_rejections"] += 1
                            elif kind == "error":
                                diagnostics["request_errors"] += 1
                        except ValueError:
                            continue
            if state["sources"].get(source) in ("started", "tls_failed"):
                if observed:
                    state["sources"][source] = "observed"
                elif source == "network" and diagnostics["tls_errors"]:
                    state["sources"][source] = "tls_failed"
    state["network_diagnostics"] = diagnostics
    if diagnostics["tls_errors"]:
        if diagnostics["certificate_rejections"]:
            setup = ("Install this companion's capture CA on Android and use a test build that trusts it. "
                     if state.get("platform") == "android" else
                     "Trust this companion's capture CA in the selected Simulator. ")
            warning = (f"{diagnostics['certificate_rejections']} TLS connections reached the proxy but the client rejected its certificate. "
                       + setup +
                       "A previously installed Charles or other proxy CA may be different. Pinned connections may still fail.")
        else:
            warning = (f"{diagnostics['tls_errors']} TLS handshakes failed. Check capture CA trust, certificate pinning and the TLS error details.")
        if warning not in state["warnings"]:
            state["warnings"].append(warning)
    return {"session": state, **page}


def acquire_routing_lock(session_dir):
    """One owner across output roots; stale recovery cannot be silently bypassed."""
    directory = Path(os.environ.get("CAPTURE_RUNTIME_STATE_DIRECTORY", f"/tmp/capture-companion-{os.getuid()}"))
    directory.mkdir(mode=0o700, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o077:
        raise CaptureError("Private capture lock directory has unsafe ownership/permissions.")
    stream = (directory / "owner.lock").open("a+")
    try:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        stream.close()
        raise CaptureError("Another capture currently owns device/host routing. Stop it before starting another.")
    stream.seek(0)
    previous = stream.read().strip()
    if previous and previous != str(session_dir):
        state = read_json(Path(previous) / "session.json", {})
        if state.get("phase") in ACTIVE_PHASES or state.get("routing_restored") is False:
            stream.close()
            raise CaptureError(f"A previous capture needs recovery. Stop it first: {previous}")
    stream.seek(0)
    stream.truncate()
    stream.write(str(session_dir))
    stream.flush()
    os.fsync(stream.fileno())
    return stream


def adb_command(tools, device, *args):
    return [tools["adb"], "-s", device, *args]


def android_proxy_snapshot(tools, device):
    result = run(adb_command(tools, device, "shell", "settings", "list", "global"))
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return {key: values.get(key) for key in PROXY_KEYS}


def android_write_proxy(tools, device, values):
    for key in reversed(PROXY_KEYS):
        value = values.get(key)
        command = ["settings", "delete", "global", key] if value is None else ["settings", "put", "global", key, str(value)]
        # ADB reconstructs a remote shell command. Preserve empty values and quote
        # saved settings for that shell, independently of the host argument array.
        run(adb_command(tools, device, "shell", shlex.join(command)))


def android_proxy_is_disabled(values):
    return (values.get("http_proxy") in (None, "", ":0")
            and not values.get("global_http_proxy_host")
            and values.get("global_http_proxy_port") in (None, "", "0")
            and not values.get("global_proxy_pac_url"))


def android_assert_proxy_owned(current, journal):
    conflicts = []
    for key in PROXY_KEYS:
        allowed = [journal["before"].get(key), journal["applied"].get(key)]
        if journal.get("runtime_proxy_clear_attempted"):
            allowed.append(ANDROID_CLEARED_PROXY[key])
        if key == "http_proxy" and journal.get("runtime_proxy_clear_empty_attempted"):
            allowed.append("")
        if current.get(key) not in allowed:
            conflicts.append(key)
    if conflicts:
        raise CaptureError("Android proxy changed outside this capture; preserved it. Restore manually or retry after resolving: " + ", ".join(conflicts))


def android_clear_runtime_proxy(tools, device, *, timeout=5, journal=None, journal_path=None):
    # Deleting HTTP_PROXY makes ProxyTracker skip its deprecated-setting handler,
    # leaving the old proxy cached in ConnectivityService/NetworkMonitor. An
    # explicit empty host/zero port invokes setGlobalProxy and its change broadcast.
    current = android_proxy_snapshot(tools, device)
    if journal is None:
        journal = {"before": current, "applied": current, "runtime_proxy_clear_attempted": True}
    android_assert_proxy_owned(current, journal)
    if journal.get("runtime_proxy_clear_acknowledged") and current == ANDROID_CLEARED_PROXY:
        return
    journal["runtime_proxy_clear_acknowledged"] = False
    if current.get("http_proxy") == ":0":
        # SettingsProvider may suppress notifications for identical writes. A
        # failed previous :0 attempt therefore needs a real, safe value change.
        # The empty legacy value does not install another proxy and is journaled
        # before writing so a crash here remains an owned recoverable state.
        journal["runtime_proxy_clear_empty_attempted"] = True
        if journal_path:
            write_json(journal_path, journal)
        run(adb_command(tools, device, "shell", "settings put global http_proxy ''"))
        current = android_proxy_snapshot(tools, device)
        android_assert_proxy_owned(current, journal)
        if current.get("http_proxy") != "":
            raise CaptureError("Android legacy proxy changed during the owned clear transition; preserved it. Resolve that change and retry Cleanup & Save.")
    if journal_path:
        write_json(journal_path, journal)
    run(adb_command(tools, device, "shell", "settings put global http_proxy :0"))
    deadline = time.monotonic() + timeout
    while True:
        current = android_proxy_snapshot(tools, device)
        android_assert_proxy_owned(current, journal)
        if current.get("http_proxy") != ":0":
            raise CaptureError("Android legacy proxy changed while clearing its cached proxy; preserved it. Resolve that change and retry Cleanup & Save.")
        # ProxyTracker writes these normalized values before broadcasting. Wait
        # for that acknowledgment before restoring absent/present database values.
        if current == ANDROID_CLEARED_PROXY:
            return
        if time.monotonic() >= deadline:
            raise CaptureError("Android did not acknowledge clearing its cached proxy. Reconnect this device and retry Cleanup & Save; routing restoration is not verified.")
        time.sleep(0.05)


def proxy_helper(action, service=None, payload=None):
    # A private module cache avoids requiring writes to the user's developer cache.
    cache = Path(f"/tmp/capture-companion-{os.getuid()}") / "swift-cache"
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    command = ["/usr/bin/swift", "-module-cache-path", str(cache), str(HERE / "proxy_settings.swift"), action]
    if service:
        command.append(service)
    result = run(command, input_data=json.dumps(payload) if payload is not None else None, timeout=60)
    return json.loads(result.stdout)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def claim_routing(session_dir, state, request, tools, port):
    journal_path = session_dir / "runtime" / "routing.json"
    device = state["device_id"]
    if state["platform"] == "android":
        before = android_proxy_snapshot(tools, device)
        reverse = run(adb_command(tools, device, "reverse", "--list")).stdout
        endpoint = f"tcp:{port}"
        if any(endpoint == field for line in reverse.splitlines() for field in line.split()[1:2]):
            raise CaptureError("Chosen Android reverse endpoint is already in use. Retry capture.")
        applied = {"http_proxy": f"127.0.0.1:{port}", "global_http_proxy_host": "127.0.0.1",
                   "global_http_proxy_port": str(port), "global_http_proxy_exclusion_list": "", "global_proxy_pac_url": ""}
        journal = {"platform": "android", "device_id": device, "tools": tools, "before": before,
                   "applied": applied, "endpoint": endpoint, "reverse_attempted": False, "proxy_attempted": False, "restored": False}
        write_json(journal_path, journal)
        journal["reverse_attempted"] = True
        write_json(journal_path, journal)
        run(adb_command(tools, device, "reverse", "--no-rebind", endpoint, endpoint))
        journal["proxy_attempted"] = True
        write_json(journal_path, journal)
        android_write_proxy(tools, device, applied)
        if android_proxy_snapshot(tools, device) != applied:
            raise CaptureError("Android did not retain the requested HTTP proxy settings.")
        state["warnings"].append("Android captures apps that honor the system HTTP proxy. CA trust/network security configuration is required for HTTPS; pinning, QUIC and proxy bypass can leave gaps.")
    else:
        service = request.get("network_service")
        if not service:
            raise CaptureError("Select an explicit Mac network service for Simulator capture.")
        before = proxy_helper("snapshot", service)
        config = before.get("configuration", {})
        if config.get("ProxyAutoConfigEnable") or config.get("ProxyAutoDiscoveryEnable"):
            raise CaptureError("This network service uses automatic proxy configuration/discovery. Disable PAC/WPAD explicitly or choose another service before capture; existing settings were preserved.")
        journal = {"platform": "simulator", "before": before, "port": port, "apply_attempted": True, "restored": False}
        write_json(journal_path, journal)
        # The intended dictionary is durable before the mutation, allowing recovery
        # even if the helper or supervisor exits immediately after applying it.
        applied = dict(before)
        applied["configuration"] = dict(before["configuration"], HTTPEnable=1, HTTPProxy="127.0.0.1", HTTPPort=port,
                                        HTTPSEnable=1, HTTPSProxy="127.0.0.1", HTTPSPort=port)
        applied["enabled"] = True
        applied["configuration_present"] = True
        journal["applied"] = applied
        write_json(journal_path, journal)
        proxy_helper("apply", payload=journal)
        state["warnings"].append(f"Simulator network capture changes the Mac’s {service} HTTP/HTTPS proxy and includes unrelated host and Simulator traffic. Apps that bypass the proxy or pin certificates may be absent.")
    state["routing_restored"] = None
    write_json(session_dir / "session.json", state)


def restore_routing(session_dir):
    path = session_dir / "runtime" / "routing.json"
    journal = read_json(path)
    if not journal or journal.get("restored"):
        return True
    if journal["platform"] == "android":
        tools, device = journal["tools"], journal["device_id"]
        if journal.get("proxy_attempted"):
            current = android_proxy_snapshot(tools, device)
            # Accept only before/applied and durably journaled clearing values;
            # partial startup/clear/restoration can leave a mixture of these.
            android_assert_proxy_owned(current, journal)
            if android_proxy_is_disabled(journal["before"]):
                journal["runtime_proxy_clear_attempted"] = True
                write_json(path, journal)
                android_clear_runtime_proxy(tools, device, journal=journal, journal_path=path)
                journal["runtime_proxy_clear_acknowledged"] = True
                write_json(path, journal)
                if android_proxy_snapshot(tools, device) != ANDROID_CLEARED_PROXY:
                    raise CaptureError("Android proxy changed after its clear acknowledgment; preserved it. Resolve that change and retry Cleanup & Save.")
            else:
                android_assert_proxy_owned(android_proxy_snapshot(tools, device), journal)
            android_write_proxy(tools, device, journal["before"])
            if android_proxy_snapshot(tools, device) != journal["before"]:
                raise CaptureError("Android proxy restoration could not be verified. Reconnect this device and Stop again.")
        if journal.get("reverse_attempted"):
            result = run(adb_command(tools, device, "reverse", "--list"))
            endpoint = journal["endpoint"]
            owned = [line.split() for line in result.stdout.splitlines() if len(line.split()) >= 3 and line.split()[1] == endpoint]
            if owned and any(fields[2] != endpoint for fields in owned):
                raise CaptureError("ADB reverse mapping changed externally; refusing to remove another mapping.")
            if owned:
                run(adb_command(tools, device, "reverse", "--remove", endpoint))
            remaining = run(adb_command(tools, device, "reverse", "--list")).stdout
            if any(len(line.split()) >= 2 and line.split()[1] == endpoint for line in remaining.splitlines()):
                raise CaptureError("ADB reverse cleanup could not be verified.")
    else:
        proxy_helper("restore", payload=journal)
    journal["restored"] = True
    journal["restored_at"] = now()
    write_json(path, journal)
    return True


def start_worker(session_dir, name, command, output, env=None):
    config = session_dir / "runtime" / f"{name}-worker.json"
    write_json(config, {"command": command, "output": str(output), "stderr": str(session_dir / "runtime" / f"{name}.stderr"), "env": env or {}})
    # A worker owns its subprocess handles and is held alive by this private pipe.
    # If the supervisor dies, EOF makes the worker shut down its child gracefully.
    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_worker", "--config", str(config)],
                               stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True, close_fds=True)
    return process


def stop_workers(workers):
    errors = []
    for process in workers.values():
        if process.stdin:
            try:
                process.stdin.close()
            except OSError:
                pass
    for name, process in workers.items():
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            # This is a still-owned Popen handle, never a PID loaded from disk.
            process.terminate()
            errors.append(f"{name} worker did not finish gracefully; evidence may be incomplete")
    return errors


def network_startup_failure(session_dir, executable_path):
    receipt = read_json(session_dir / "runtime" / "network-worker.result.json", {})
    code = receipt.get("exit_code")
    status = ""
    if isinstance(code, int):
        if code < 0:
            try:
                status = " (" + signal.Signals(-code).name + ")"
            except ValueError:
                status = f" (signal {-code})"
        else:
            status = f" (exit code {code})"
    message = f"mitmdump could not start{status}. Executable: {executable_path}."
    stderr = session_dir / "runtime" / "network.stderr"
    detail = stderr.read_text(errors="replace").strip()[-1600:] if stderr.exists() else ""
    if detail:
        message += "\n" + detail
    if sys.platform == "darwin" and code == -signal.SIGKILL:
        message += ("\nmacOS may have blocked mitmproxy from opening. Check for a macOS security alert. "
                    "If you trust the installation source, allow mitmproxy yourself in System Settings > "
                    "Privacy & Security > Open Anyway, then retry capture. A SIGKILL alone does not prove "
                    "a security block; no system security settings were changed by the companion.")
    elif not detail:
        message += " No error output was produced. Check that this executable can run before retrying capture."
    return CaptureError(message)


def worker(config_path):
    config = read_json(config_path)
    environment = os.environ.copy()
    environment.update(config["env"])
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    output = Path(config["output"])
    output.parent.mkdir(parents=True, exist_ok=True)
    stopping = False

    def request_stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    with output.open("ab", buffering=0) as out, open(config["stderr"], "ab", buffering=0) as err:
        try:
            child = subprocess.Popen(config["command"], stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                     env=environment, start_new_session=True, close_fds=True)
        except OSError as exc:
            err.write((str(exc) + "\n").encode())
            write_json(Path(config_path).with_suffix(".result.json"), {"exit_code": 127, "finished_at": now(), "error": str(exc)})
            return 1
        try:
            while child.poll() is None and not stopping:
                readable, _, _ = select.select([sys.stdin.buffer], [], [], 0.2)
                if readable and not os.read(sys.stdin.fileno(), 1):
                    break
            if child.poll() is None:
                for sig, seconds in ((signal.SIGINT, 10), (signal.SIGTERM, 3), (signal.SIGKILL, 2)):
                    try:
                        os.killpg(child.pid, sig)
                        child.wait(timeout=seconds)
                        break
                    except ProcessLookupError:
                        break
                    except subprocess.TimeoutExpired:
                        continue
        finally:
            write_json(Path(config_path).with_suffix(".result.json"), {"exit_code": child.poll(), "finished_at": now()})
    return 0


def calibrate_clock(request, tools):
    if request["platform"] != "android":
        return {"offset_ms": None, "uncertainty_ms": None, "method": "Simulator log timestamps are host-related; clock alignment not measured"}
    before = time.time()
    result = run(adb_command(tools, request["device_id"], "shell", "date", "+%s"), check=False)
    after = time.time()
    try:
        value = float(result.stdout.strip())
        return {"offset_ms": ((before + after) / 2 - value - 0.5) * 1000,
                "uncertainty_ms": 500 + (after - before) * 500, "method": "adb date epoch seconds; quantization plus round trip"}
    except ValueError:
        return {"offset_ms": None, "uncertainty_ms": None, "method": "device clock calibration unavailable"}


def simulator_apps(output):
    """simctl emits JSON, XML/binary plists, or OpenStep plists across Xcodes."""
    try:
        apps = json.loads(output)
    except ValueError:
        try:
            apps = plistlib.loads(output.encode("utf-8"))
        except (ValueError, plistlib.InvalidFileException):
            converted = run(["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-"], input_data=output)
            apps = json.loads(converted.stdout)
    if not isinstance(apps, dict) or any(not isinstance(value, dict) for value in apps.values()):
        raise CaptureError("Simulator app metadata is not a bundle-to-application dictionary.")
    return apps


def predicate_string(value):
    if not isinstance(value, str) or not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise CaptureError("Simulator process executable has an invalid name; use an installed app bundle identifier.")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def simulator_log_command(request, tools, state):
    command = [tools["simctl"], "spawn", request["device_id"], "log", "stream", "--style", "ndjson", "--level", "debug"]
    target = str(request.get("target_app") or "").strip()
    if not target:
        scope = {"mode": "all_simulator_processes", "predicate": None}
        state["warnings"].append("Simulator logs include all processes at debug level. High volume can consume memory and disk; enter a target app bundle identifier for process-scoped logs, or use the timeline filters to inspect the full session.")
    else:
        apps = simulator_apps(run([tools["simctl"], "listapps", request["device_id"]]).stdout)
        app = apps.get(target)
        if app is None:
            raise CaptureError(f"Target app {target!r} is not installed on this Simulator. Enter its exact bundle identifier or clear the target for broad logs.")
        if app.get("CFBundleIdentifier", target) != target:
            raise CaptureError("Simulator app metadata contains an inconsistent bundle identifier; no capture routing was changed.")
        executable_name = app.get("CFBundleExecutable")
        resolution = "simctl listapps CFBundleExecutable"
        if not executable_name:
            container = run([tools["simctl"], "get_app_container", request["device_id"], target, "app"]).stdout.strip()
            info = Path(container) / "Info.plist"
            try:
                with info.open("rb") as source:
                    metadata = plistlib.load(source)
                executable_name = metadata.get("CFBundleExecutable")
            except (OSError, ValueError, plistlib.InvalidFileException) as exc:
                raise CaptureError(f"Cannot resolve target app executable from its Info.plist: {exc}") from exc
            resolution = "simctl get_app_container Info.plist CFBundleExecutable"
        if not isinstance(executable_name, str) or Path(executable_name).name != executable_name or executable_name in (".", ".."):
            raise CaptureError("Target app does not declare a usable CFBundleExecutable; no capture routing was changed.")
        predicate = "process == " + predicate_string(executable_name)
        command += ["--predicate", predicate]
        scope = {"mode": "simulator_process", "bundle_id": target, "executable": executable_name,
                 "predicate": predicate, "resolution": resolution}
        state["warnings"].append(f"Simulator logs are scoped to process {executable_name!r} from bundle {target!r}; exact predicate: {predicate}. Includes SDK logs emitted by that process across restarts. Separate helper/extension processes are outside this scope.")
    state.setdefault("context", {})["log_scope"] = scope
    return command


def prepare(session_dir, state, request, workers):
    tools = tools_for(request)
    available = list_devices(tools)
    matched = [d for d in available if d["id"] == request["device_id"] and d["platform"] == request["platform"]]
    if not matched or matched[0]["state"] not in ("ready", "booted"):
        raise CaptureError("Selected device is not ready. Unlock/authorize Android USB debugging or boot the selected Simulator.")
    state["device_name"] = request.get("device_name") or matched[0]["name"]
    state["clock_calibration"] = {"logs": calibrate_clock(request, tools),
                                  "network": {"offset_ms": 0, "uncertainty_ms": 1, "method": "proxy and received timestamps use the Mac clock"}}
    log_command = None
    if request.get("capture_logs") and request["platform"] == "simulator":
        # Resolve before starting the proxy or changing any route, so an invalid
        # target fails without touching network settings or silently broadening.
        log_command = simulator_log_command(request, tools, state)
    write_json(session_dir / "session.json", state)
    if request.get("capture_network"):
        if not tools.get("mitmdump"):
            raise CaptureError("mitmdump is required for network capture. Install mitmproxy or supply mitmdump_path.")
        port = free_port()
        private_ca = Path(request.get("ca_directory") or (Path.home() / "Library" / "Application Support" / "Capture Companion" / "mitmproxy"))
        if not private_ca.is_absolute():
            raise CaptureError("ca_directory must be an absolute private directory.")
        private_ca.mkdir(parents=True, exist_ok=True, mode=0o700)
        if private_ca.is_symlink() or private_ca.stat().st_uid != os.getuid() or private_ca.stat().st_mode & 0o077:
            raise CaptureError("Capture CA directory must be owned by this user with mode 700; it contains a private signing key.")
        command = [tools["mitmdump"], "--listen-host", "127.0.0.1", "--listen-port", str(port),
                   "--mode", "regular", "--set", f"confdir={private_ca}", "--set", "connection_strategy=lazy",
                   "--set", "store_streamed_bodies=true", "-w", str(session_dir / "network" / "capture.mitm"),
                   "-s", str(HERE / "network_addon.py")]
        workers["network"] = start_worker(session_dir, "network", command, session_dir / "runtime" / "mitmdump.stdout", {"CAPTURE_SESSION_DIR": str(session_dir)})
        deadline = time.monotonic() + 25
        ready = session_dir / "network" / "ready.json"
        while time.monotonic() < deadline and not ready.exists():
            if workers["network"].poll() is not None:
                raise network_startup_failure(session_dir, tools["mitmdump"])
            time.sleep(0.1)
        if not ready.exists():
            raise CaptureError("Network collector did not become ready. Check mitmdump_path and local port access.")
        ca = private_ca / "mitmproxy-ca-cert.pem"
        if not ca.exists():
            raise CaptureError("Proxy started without a public CA certificate. Network capture cannot be prepared.")
        public_ca = session_dir / "setup" / "capture-ca-cert.pem"
        public_ca.parent.mkdir(mode=0o700)
        shutil.copyfile(ca, public_ca)
        state["ca_certificate_path"] = str(public_ca)
        state["proxy_port"] = port
        if request["platform"] == "simulator" and request.get("trust_simulator_ca"):
            run([tools["simctl"], "keychain", request["device_id"], "add-root-cert", str(public_ca)])
            state["warnings"].append("The public capture CA was explicitly imported into this Simulator. It remains trusted after capture; erase/remove it when no longer needed. No host CA trust was changed.")
        elif request["platform"] == "simulator":
            state["warnings"].append("No CA import requested this session. A previously trusted companion CA can be reused; otherwise HTTPS requires trusting its public certificate. Failed TLS requests are recorded as gaps.")
        claim_routing(session_dir, state, request, tools, port)
        state["sources"]["network"] = "started"
    if request.get("capture_logs"):
        if request["platform"] == "android":
            command = adb_command(tools, request["device_id"], "logcat", "-v", "epoch", "-T", "1")
        else:
            command = log_command
        workers["logs"] = start_worker(session_dir, "logs", command, session_dir / "logs" / "device.log")
        time.sleep(0.6)
        if workers["logs"].poll() is not None:
            error = (session_dir / "runtime" / "logs.stderr").read_text(errors="replace")[-1600:]
            raise CaptureError("Device log collector exited during startup: " + error)
        state["sources"]["logs"] = "started"
        if request.get("target_app") and request["platform"] == "android":
            state["warnings"].append("Android target_app is recorded as context. Raw device logs include all processes so app restarts and SDK processes are retained.")
    state["phase"] = "recording"
    state["recording_at"] = now()
    write_json(session_dir / "session.json", state)


def restore_with_warning(session_dir, state):
    try:
        state["routing_restored"] = restore_routing(session_dir)
    except Exception as exc:
        state["routing_restored"] = False
        state["warnings"].append("Routing recovery still required: " + str(exc))


def finalize(session_dir, state, *, startup_failure=False, interrupted=False, routing_attempted=False):
    previous = state.get("completeness", {})
    new_interruption = interrupted
    interrupted = interrupted or bool(previous.get("interrupted"))
    startup_failure = startup_failure or bool(previous.get("startup_failed")) or state.get("phase") == "failed"
    state["stopped_at"] = state.get("stopped_at") or now()
    if not routing_attempted:
        restore_with_warning(session_dir, state)
    incomplete = read_json(session_dir / "network" / "incomplete.json", {})
    state["completeness"] = {**previous, "incomplete_requests": incomplete.get("count", 0),
                             "incomplete_flow_ids": incomplete.get("flow_ids", []),
                             "interrupted": interrupted, "startup_failed": startup_failure,
                             "network_attribution": "proxy traffic may include other processes; temporal matches are inferred",
                             "body_limit": "No configured body truncation; missing/inflight bodies remain explicit"}
    state["completeness"]["missing_bodies"] = incomplete.get("missing_bodies", [])
    network_errors = {"error": 0, "tls_error": 0}
    network_events = session_dir / "network" / "events.jsonl"
    if network_events.exists():
        with network_events.open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    kind = json.loads(line).get("kind")
                    if kind in network_errors:
                        network_errors[kind] += 1
                except ValueError:
                    continue
    state["completeness"]["network_errors"] = network_errors
    state["collector_status"] = {path.name.removesuffix("-worker.result.json"): read_json(path)
                                 for path in (session_dir / "runtime").glob("*-worker.result.json")}
    current = response(session_dir)["session"]
    state["counts"] = current["counts"]
    state["network_diagnostics"] = current["network_diagnostics"]
    for warning in current["warnings"]:
        if warning not in state["warnings"]:
            state["warnings"].append(warning)
    for source in ("logs", "network"):
        if state["sources"][source] in ("started", "tls_failed") and current["sources"][source] in ("observed", "tls_failed"):
            state["sources"][source] = current["sources"][source]
        if new_interruption and state["sources"][source] in ("preparing", "started", "observed"):
            state["sources"][source] = "interrupted"
    missing = [source for source in ("logs", "network") if state["sources"][source] in ("started", "tls_failed")]
    state["completeness"]["sources_without_observed_evidence"] = missing
    if missing:
        state["warnings"].append("No observed evidence from selected source(s): " + ", ".join(missing))
    failed_sources = any(status in ("failed", "interrupted") for status in state["sources"].values())
    state["phase"] = "failed" if startup_failure else ("partial" if interrupted or failed_sources or not state["routing_restored"] or incomplete.get("count") or incomplete.get("missing_bodies") or missing or any(network_errors.values()) else "saved")
    # Terminal state is published only after the ZIP has been atomically finalized.
    write_json(session_dir / "session.json", dict(state, phase="stopping"))
    try:
        state["package_path"] = str(evidence_module().finalize_package(session_dir, state))
    except Exception as exc:
        state["warnings"].append("Package export failed: " + str(exc))
        state["phase"] = "partial" if not startup_failure else "failed"
    write_json(session_dir / "session.json", state)
    return state


def supervise(session_dir):
    request = read_json(session_dir / "runtime" / "request.json")
    control = read_json(session_dir / "runtime" / "control.json")
    state = read_json(session_dir / "session.json")
    workers = {}
    stopping = False

    def request_stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    ownership = None
    try:
        server.bind(control["socket"])
        os.chmod(control["socket"], 0o600)
        server.listen(4)
        server.settimeout(0.25)
        try:
            ownership = acquire_routing_lock(session_dir)
            prepare(session_dir, state, request, workers)
        except Exception as exc:
            state["warnings"].append(str(exc))
            for source in ("logs", "network"):
                if state["sources"][source] != "not_selected":
                    state["sources"][source] = "failed"
            state["phase"] = "stopping"
            write_json(session_dir / "session.json", state)
            restore_with_warning(session_dir, state)
            stop_workers(workers)
            finalize(session_dir, state, startup_failure=True, routing_attempted=True)
            return 1
        interrupted = False
        while not stopping:
            failed = [name for name, process in workers.items() if process.poll() is not None]
            if failed:
                for name in failed:
                    state["sources"][name] = "interrupted"
                state["warnings"].append("Collector exited unexpectedly: " + ", ".join(failed))
                interrupted = True
                break
            try:
                client, _ = server.accept()
            except socket.timeout:
                continue
            with client:
                client.settimeout(2)
                try:
                    data = b""
                    while b"\n" not in data and len(data) < 8192:
                        chunk = client.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                    message = json.loads(data)
                    if not secrets.compare_digest(str(message.get("token", "")), control["token"]):
                        client.sendall(b'{"error":"Unauthorized session control"}\n')
                        continue
                    if message.get("action") == "stop":
                        stopping = True
                    client.sendall(b'{"ok":true}\n')
                except (OSError, ValueError):
                    continue
        state["phase"] = "stopping"
        write_json(session_dir / "session.json", state)
        # Keep the proxy listening until routing is restored, including while
        # macOS requests authorization. Never strand the host on a closed proxy.
        restore_with_warning(session_dir, state)
        state["warnings"].extend(stop_workers(workers))
        finalize(session_dir, state, interrupted=interrupted, routing_attempted=True)
        return 0
    finally:
        if ownership:
            ownership.close()
        server.close()
        try:
            Path(control["socket"]).unlink()
        except FileNotFoundError:
            pass


def control_request(session_dir, action):
    control = read_json(session_dir / "runtime" / "control.json")
    if not control:
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(control["socket"])
            client.sendall(json.dumps({"action": action, "token": control["token"]}).encode() + b"\n")
            result = json.loads(client.recv(8192))
            return result.get("ok") is True
    except (OSError, ValueError):
        return False


def session_path(value):
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise CaptureError("Session directory must be an absolute path.")
    if not (path / "session.json").is_file():
        raise CaptureError("No capture session exists in that directory.")
    return path


def start(request_path, **view):
    request = read_json(request_path)
    if not isinstance(request, dict):
        raise CaptureError("Start request must be a JSON object.")
    if request.get("platform") not in ("android", "simulator") or not request.get("device_id"):
        raise CaptureError("Choose an explicit Android device or booted iOS Simulator.")
    if not (request.get("capture_logs") or request.get("capture_network")):
        raise CaptureError("Select device logs, network capture, or both.")
    root = Path(request.get("output_root", "")).expanduser()
    if not root.is_absolute():
        raise CaptureError("output_root must be an absolute private directory.")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    # A capture has exclusive ownership of routing. Preserve all other sessions.
    for previous in root.glob("*/session.json"):
        earlier = read_json(previous, {})
        if earlier.get("phase") in ACTIVE_PHASES or earlier.get("routing_restored") is False:
            raise CaptureError(f"A previous capture is active or needs recovery. Stop it first: {previous.parent}")
    identifier = str(uuid.uuid4())
    directory = root / (dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + identifier[:8])
    directory.mkdir(mode=0o700)
    for subdir in ("runtime", "logs", "network", "timeline"):
        (directory / subdir).mkdir(mode=0o700)
    state = {"id": identifier, "directory": str(directory), "platform": request["platform"],
             "device_id": request["device_id"], "device_name": request.get("device_name", request["device_id"]),
             "started_at": now(), "phase": "preparing", "sources": {"logs": "preparing" if request.get("capture_logs") else "not_selected",
                                                                      "network": "preparing" if request.get("capture_network") else "not_selected"},
             "warnings": [], "package_path": None, "counts": {"logs": 0, "network": 0, "markers": 0},
             "routing_restored": None if request.get("capture_network") else True,
             "target_app": request.get("target_app"), "network_service": request.get("network_service"), "clock_calibration": {}}
    write_json(directory / "session.json", state)
    write_json(directory / "runtime" / "request.json", request)
    control = {"socket": f"/tmp/capture-{identifier}.sock", "token": secrets.token_hex(32)}
    write_json(directory / "runtime" / "control.json", control)
    with (directory / "runtime" / "supervisor.stderr").open("ab") as errors:
        supervisor = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve()), "_supervise", "--session", str(directory)],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errors, start_new_session=True, close_fds=True)
    deadline = time.monotonic() + 100
    while time.monotonic() < deadline:
        state = read_json(directory / "session.json")
        if state["phase"] in ("recording", "saved", "partial", "failed"):
            return response(directory, **view)
        if supervisor.poll() is not None:
            result = stop(directory, **view)
            result["error"] = "Capture supervisor exited during startup. Inspect runtime/supervisor.stderr for tool diagnostics."
            return result
        time.sleep(0.1)
    control_request(directory, "stop")
    result = response(directory, **view)
    result["error"] = f"Capture startup timed out. Stop/recover this session: {directory}"
    return result


def status(directory, **view):
    state = read_json(directory / "session.json")
    if state["phase"] in ACTIVE_PHASES and not control_request(directory, "ping"):
        result = response(directory, **view)
        if result["session"]["phase"] in ACTIVE_PHASES:
            result["session"]["warnings"] = list(dict.fromkeys(result["session"]["warnings"] + ["Capture supervisor has not answered. Preparation/shutdown may be in progress; use Stop for safe recovery."]))
            result["session"]["supervisor_available"] = False
        return result
    return response(directory, **view)


def stop(directory, **view):
    state = read_json(directory / "session.json")
    if state["phase"] in ACTIVE_PHASES and control_request(directory, "stop"):
        deadline = time.monotonic() + 65
        while time.monotonic() < deadline:
            state = read_json(directory / "session.json")
            if state["phase"] not in ACTIVE_PHASES:
                return response(directory, **view)
            time.sleep(0.1)
        raise CaptureError(f"Collectors are still stopping. Retry Stop for recovery: {directory}")
    if state["phase"] in ACTIVE_PHASES or state.get("routing_restored") is False or not state.get("package_path"):
        # No PID loaded from disk is signalled. Worker EOF supervision handles orphan
        # collection; routing recovery uses only the durable ownership journal.
        try:
            ownership = acquire_routing_lock(directory)
        except CaptureError:
            result = response(directory, **view)
            result["session"]["warnings"].append("The supervisor still owns capture routing. Preparation or shutdown may be waiting for macOS authorization; wait and retry Stop. Recovery has not changed its settings.")
            return result
        try:
            configs = list((directory / "runtime").glob("*-worker.json"))
            deadline = time.monotonic() + 22
            while time.monotonic() < deadline and any(not config.with_suffix(".result.json").exists() for config in configs):
                time.sleep(0.1)
            missing = [config.stem for config in configs if not config.with_suffix(".result.json").exists()]
            if missing:
                result = response(directory, **view)
                result["session"]["warnings"].append("Worker shutdown receipts are unavailable; recovery/export is deferred to preserve evidence: " + ", ".join(missing))
                return result
            state = read_json(directory / "session.json")
            active_orphan = state["phase"] in ACTIVE_PHASES
            if active_orphan:
                state["warnings"].append("Recovered after supervisor interruption; final in-flight evidence may be incomplete.")
            finalize(directory, state, interrupted=active_orphan)
        finally:
            ownership.close()
    return response(directory, **view)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    discover = sub.add_parser("devices")
    discover.add_argument("--adb-path")
    discover.add_argument("--mitmdump-path")
    begin = sub.add_parser("start")
    begin.add_argument("--request", required=True)
    public_commands = [begin]
    for action in ("status", "marker", "stop", "_supervise"):
        command = sub.add_parser(action)
        command.add_argument("--session", required=True)
        if action == "marker":
            command.add_argument("--text", required=True)
        if action != "_supervise":
            public_commands.append(command)
    def nonnegative(value):
        number = int(value)
        if number < 0:
            raise argparse.ArgumentTypeError("must be nonnegative")
        return number
    for command in public_commands:
        command.add_argument("--source", choices=("all", "logs", "network", "marker"), default="all")
        command.add_argument("--search", default="")
        command.add_argument("--event-limit", type=nonnegative, default=400)
        command.add_argument("--retain-from")
        command.add_argument("--older-count", type=nonnegative, default=0)
    worker_parser = sub.add_parser("_worker")
    worker_parser.add_argument("--config", required=True)
    args = parser.parse_args(argv)
    if args.action == "_worker":
        return worker(args.config)
    if args.action == "_supervise":
        return supervise(Path(args.session))
    view = ({"cap": args.event_limit, "source": args.source, "search": args.search,
             "retain_from": args.retain_from, "older": args.older_count}
            if args.action != "devices" else {})
    try:
        if args.action == "devices":
            tools = tools_for({"adb_path": args.adb_path, "mitmdump_path": args.mitmdump_path})
            result = {"devices": list_devices(tools), "tools": tools, "network_services": network_services()}
        elif args.action == "start":
            result = start(args.request, **view)
        else:
            directory = session_path(args.session)
            if args.action == "marker":
                if read_json(directory / "session.json")["phase"] != "recording":
                    raise CaptureError("Markers can be added only while a session is recording.")
                evidence_module().append_marker(directory, args.text)
                result = response(directory, **view)
            else:
                result = status(directory, **view) if args.action == "status" else stop(directory, **view)
        if result.get("session", {}).get("phase") == "failed" and not result.get("error"):
            result["error"] = "; ".join(result["session"].get("warnings", [])) or "Capture failed; inspect the recoverable session."
        print(json.dumps(result, ensure_ascii=False))
        return 1 if result.get("error") or result.get("session", {}).get("phase") == "failed" else 0
    except Exception as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
