"""Synthetic tool-boundary tests. Never talks to ADB, Simulator or host proxies."""
import base64
import importlib.util
import http.client
import http.server
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "CaptureRuntime"))
import capture_runtime as runtime


FAKE_ADB = r'''#!/usr/bin/env python3
import json, os, shlex, signal, sys, time
from pathlib import Path
path = Path(os.environ["FAKE_CAPTURE_STATE"])
state = json.loads(path.read_text())
args = sys.argv[1:]
if args == ["devices", "-l"]:
    print("List of devices attached\nfake-android device model:Neutral_Sample")
    sys.exit(0)
assert args[:2] == ["-s", "fake-android"], args
args = args[2:]
if args and args[0] == "shell":
    # The real ADB client joins shell arguments before passing them to Android.
    args = ["shell"] + shlex.split(" ".join(args[1:]))
if args == ["shell", "date", "+%s"]:
    print(int(time.time()))
elif args[:3] == ["shell", "settings", "list"]:
    for key, value in state["proxy"].items(): print(key + "=" + value)
elif args[:2] == ["shell", "settings"]:
    action, key = args[2], args[4]
    previous = state["proxy"].get(key)
    if action == "delete": state["proxy"].pop(key, None)
    else: state["proxy"][key] = args[5]
    if "effective_proxy" in state and action == "put" and key == "http_proxy":
        state.setdefault("http_proxy_writes", []).append(args[5])
        if args[5] == ":0" and previous != args[5]:
            if not os.environ.get("FAKE_CAPTURE_CLEAR_STUCK"):
                state["effective_proxy"] = None
                state["cache_clear_signals"] = state.get("cache_clear_signals", 0) + 1
                state["proxy"].update({"global_http_proxy_host":"", "global_http_proxy_port":"0",
                                      "global_http_proxy_exclusion_list":"", "global_proxy_pac_url":""})
            if os.environ.get("FAKE_CAPTURE_CLEAR_EXTERNAL_PROXY"):
                state["proxy"]["http_proxy"] = os.environ["FAKE_CAPTURE_CLEAR_EXTERNAL_PROXY"]
                state["effective_proxy"] = os.environ["FAKE_CAPTURE_CLEAR_EXTERNAL_PROXY"]
            if os.environ.get("FAKE_CAPTURE_CLEAR_EXTERNAL_HOST"):
                state["proxy"]["global_http_proxy_host"] = os.environ["FAKE_CAPTURE_CLEAR_EXTERNAL_HOST"]
        elif args[5] not in ("", ":0") and previous != args[5]: state["effective_proxy"] = args[5]
    # Deletions, empty legacy values and identical writes do not clear the cache.
    path.write_text(json.dumps(state))
elif args == ["reverse", "--list"]:
    for key, value in state["reverse"].items(): print("fake-android " + key + " " + value)
elif args[:2] == ["reverse", "--no-rebind"]:
    if args[2] in state["reverse"]: sys.exit(1)
    state["reverse"][args[2]] = args[3]
    path.write_text(json.dumps(state))
elif args[:2] == ["reverse", "--remove"]:
    state["reverse"].pop(args[2], None)
    path.write_text(json.dumps(state))
elif args[0] == "logcat":
    assert "-c" not in args, "must never clear logs"
    if os.environ.get("FAKE_CAPTURE_LOG_FAIL"): sys.exit(9)
    print(f"{time.time():.3f} 123 124 I Sample: neutral capture marker", flush=True)
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    while True: time.sleep(.05)
else: raise Exception(args)
'''

FAKE_MITM = r'''#!/usr/bin/env python3
import importlib.util, os, signal, sys, time
from pathlib import Path
from types import SimpleNamespace as NS
args = sys.argv[1:]
ca = Path(next(value[8:] for value in args if value.startswith("confdir=")))
ca.mkdir(exist_ok=True)
(ca / "mitmproxy-ca-cert.pem").write_text("PUBLIC CA")
(ca / "mitmproxy-ca.pem").write_text("PRIVATE KEY MUST NOT EXPORT")
native = Path(args[args.index("-w") + 1]); native.write_bytes(b"SYNTHETIC FLOW FIXTURE\n")
spec = importlib.util.spec_from_file_location("capture_addon", args[args.index("-s") + 1])
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
addon = module.addons[0]
class Fields(dict):
    def items(self, multi=False): return list(super().items())
request = NS(method="POST", pretty_url="https://sample.invalid/ad?slot=neutral", http_version="HTTP/1.1",
             headers=Fields({"content-type":"application/json"}), query=Fields({"slot":"neutral"}),
             content=b'{"placement":"sample"}', raw_content=b'{"placement":"sample"}', timestamp_start=time.time())
flow = NS(id="neutral-flow", request=request, response=None, error=None)
addon.running()
if os.environ.get("FAKE_CAPTURE_TLS_ONLY"):
    addon.tls_failed_client(NS(conn=NS(error="The client does not trust the proxy's certificate (ssl/tls alert certificate unknown)")))
else:
    addon.request(flow)
    flow.response = NS(status_code=200, reason="OK", http_version="HTTP/1.1", headers=Fields({"content-type":"application/octet-stream"}),
                       content=b'\x00\xfffull-response-body', raw_content=b'\x00\xfffull-response-body', timestamp_start=time.time(), timestamp_end=time.time())
    addon.response(flow)
def stop(*_):
    addon.done()
    with native.open("ab") as out: out.write(b"FINISHED\n")
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
while True: time.sleep(.05)
'''


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.fake_state = self.root / "fake-state.json"
        self.original = {"proxy": {"http_proxy": "original.invalid:8888", "global_proxy_pac_url": "https://pac.invalid/proxy.pac", "untouched": "kept"},
                         "reverse": {"tcp:7777": "tcp:7778"}}
        runtime.write_json(self.fake_state, self.original)
        self.adb = self.root / "adb"
        self.mitm = self.root / "mitmdump"
        self.simctl = self.root / "simctl"
        self.adb.write_text(FAKE_ADB)
        self.mitm.write_text(FAKE_MITM)
        self.simctl.write_text('#!/usr/bin/env python3\nprint(\'{"devices":{}}\')\n')
        self.adb.chmod(0o700)
        self.mitm.chmod(0o700)
        self.simctl.chmod(0o700)
        self.environment = mock.patch.dict(os.environ, {"FAKE_CAPTURE_STATE": str(self.fake_state),
                                                         "CAPTURE_RUNTIME_STATE_DIRECTORY": str(self.root / "lock")})
        self.environment.start()
        self.sessions = []

    def tearDown(self):
        for session in self.sessions:
            try:
                self.cli("stop", "--session", str(session))
            except Exception:
                pass
        self.environment.stop()
        self.temporary.cleanup()

    def cli(self, *arguments):
        result = subprocess.run([sys.executable, str(ROOT / "CaptureRuntime" / "capture_runtime.py"), *arguments],
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(len(result.stdout.splitlines()), 1, result.stderr + result.stdout)
        return result.returncode, json.loads(result.stdout)

    def begin(self, **overrides):
        request = {"platform": "android", "device_id": "fake-android", "capture_logs": True,
                   "capture_network": True, "output_root": str(self.root / "captures"), "adb_path": str(self.adb),
                   "mitmdump_path": str(self.mitm), "simctl_path": str(self.simctl), "ca_directory": str(self.root / "private-ca")}
        request.update(overrides)
        path = self.root / ("request-" + str(time.time_ns()) + ".json")
        runtime.write_json(path, request)
        code, payload = self.cli("start", "--request", str(path))
        if "session" in payload:
            self.sessions.append(Path(payload["session"]["directory"]))
        return code, payload

    def test_android_round_trip_full_bodies_shared_timeline_and_exact_restore(self):
        code, start = self.begin()
        self.assertEqual(code, 0, start)
        session = Path(start["session"]["directory"])
        self.assertEqual(start["session"]["phase"], "recording")
        self.assertEqual(start["session"]["sources"], {"logs": "observed", "network": "observed"})
        changed = runtime.read_json(self.fake_state)
        self.assertEqual(changed["proxy"]["global_proxy_pac_url"], "")
        self.assertEqual(changed["proxy"]["untouched"], "kept")
        self.cli("marker", "--session", str(session), "--text", "tap ad; literal $(no-shell)")
        code, stopped = self.cli("stop", "--session", str(session))
        self.assertEqual(code, 0, stopped)
        self.assertEqual(stopped["session"]["phase"], "saved")
        self.assertTrue(stopped["session"]["routing_restored"])
        self.assertEqual(runtime.read_json(self.fake_state), self.original)
        events = stopped["events"]
        self.assertEqual({e["source"] for e in events}, {"logs", "network", "marker"})
        network = next(e for e in events if e["kind"] == "response")
        self.assertEqual(network["detail"]["request_body"]["text"], '{"placement":"sample"}')
        body = network["detail"]["response_body"]
        self.assertEqual(base64.b64decode(body["text"]), b"\x00\xfffull-response-body")
        with zipfile.ZipFile(stopped["session"]["package_path"]) as package:
            names = package.namelist()
            self.assertIn("network/capture.har", names)
            self.assertIn("network/capture.mitm", names)
            self.assertIn("timeline/events.jsonl", names)
            self.assertFalse(any("runtime" in name or "ca.pem" in name or "control" in name for name in names))
            self.assertNotIn(b"PRIVATE KEY MUST NOT EXPORT", b"".join(package.read(name) for name in names))

    def test_startup_failure_rolls_back_and_returns_recoverable_envelope(self):
        with mock.patch.dict(os.environ, {"FAKE_CAPTURE_LOG_FAIL": "1"}):
            code, result = self.begin()
        self.assertEqual(code, 1)
        self.assertIn("error", result)
        self.assertEqual(result["session"]["phase"], "failed")
        self.assertTrue(result["session"]["routing_restored"])
        self.assertEqual(runtime.read_json(self.fake_state), self.original)
        self.assertTrue(Path(result["session"]["package_path"]).exists())

    def test_capture_lock_spans_output_roots_and_unauthorized_control_cannot_stop(self):
        code, started = self.begin()
        self.assertEqual(code, 0, started)
        session = Path(started["session"]["directory"])
        control = runtime.read_json(session / "runtime" / "control.json")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(control["socket"])
            client.sendall(b'{"action":"stop","token":"wrong"}\n')
            self.assertIn(b"Unauthorized", client.recv(4096))
        code, blocked = self.begin(output_root=str(self.root / "other-captures"))
        self.assertEqual(code, 1)
        self.assertIn("Another capture", blocked["error"])
        self.assertEqual(self.cli("status", "--session", str(session))[1]["session"]["phase"], "recording")

    def test_tls_errors_do_not_claim_decoded_network_observed(self):
        with mock.patch.dict(os.environ, {"FAKE_CAPTURE_TLS_ONLY": "1"}):
            code, started = self.begin(capture_logs=False)
        self.assertEqual(code, 0, started)
        self.assertEqual(started["session"]["sources"]["network"], "tls_failed")
        self.assertEqual(started["session"]["network_diagnostics"], {"decoded_http_events": 0, "tls_errors": 1, "certificate_rejections": 1, "request_errors": 0})
        self.assertTrue(any("client rejected its certificate" in value for value in started["session"]["warnings"]))
        stopped = self.cli("stop", "--session", started["session"]["directory"])[1]
        self.assertEqual(stopped["session"]["phase"], "partial")
        self.assertEqual(stopped["session"]["sources"]["network"], "tls_failed")
        self.assertEqual(stopped["session"]["completeness"]["sources_without_observed_evidence"], ["network"])
        with zipfile.ZipFile(stopped["session"]["package_path"]) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["network_diagnostics"]["certificate_rejections"], 1)

    def test_decoded_http_after_tls_failure_is_observed_with_gaps(self):
        session = self.root / "tls-then-http"
        (session / "network").mkdir(parents=True)
        runtime.write_json(session / "session.json", {"id": "retry", "phase": "recording", "sources": {"logs": "not_selected", "network": "tls_failed"}, "warnings": []})
        events = [{"kind": "tls_error", "detail": {"error": "The client does not trust the proxy's certificate"}},
                  {"kind": "request", "summary": "GET https://example.invalid/"}, {"kind": "response", "summary": "200 GET https://example.invalid/"}]
        (session / "network/events.jsonl").write_text("".join(json.dumps(event) + "\n" for event in events))
        result = runtime.response(session)["session"]
        self.assertEqual(result["sources"]["network"], "observed")
        self.assertEqual(result["network_diagnostics"]["decoded_http_events"], 2)
        self.assertEqual(result["network_diagnostics"]["certificate_rejections"], 1)
        self.assertEqual(runtime.read_json(session / "session.json")["sources"]["network"], "tls_failed")

    def test_status_cli_filters_full_session_and_retains_rows_across_refresh(self):
        session = self.root / "timeline-history"
        (session / "network").mkdir(parents=True)
        (session / "logs").mkdir()
        runtime.write_json(session / "session.json", {"id": "history", "started_at": "2026-10-15T00:00:00Z",
                           "phase": "saved", "sources": {"logs": "observed", "network": "observed"}, "warnings": []})
        def network_lines(count):
            return "".join(json.dumps({"kind": "request", "timestamp": f"2026-10-15T00:00:{i:02d}Z",
                                       "summary": f"GET https://example.invalid/ad/{i}"}) + "\n" for i in range(count))
        network = session / "network/events.jsonl"
        network.write_text(network_lines(5))
        (session / "logs/device.log").write_text("1792022460.000  1  2 I Noise: later\n" * 600)
        args = ("status", "--session", str(session), "--source", "network", "--search", "/AD/", "--event-limit", "2")
        code, first = self.cli(*args)
        self.assertEqual(code, 0)
        self.assertEqual([event["summary"].rsplit("/", 1)[1] for event in first["events"]], ["3", "4"])
        self.assertEqual(first["session"]["counts"], {"logs": 600, "network": 5, "markers": 0})
        self.assertEqual(first["timeline"]["matching_count"], 5)
        anchor = first["events"][0]["id"]
        network.write_text(network_lines(9))
        _, refreshed = self.cli(*args, "--retain-from", anchor)
        self.assertEqual(len(refreshed["events"]), 6)
        _, older = self.cli(*args, "--retain-from", anchor, "--older-count", "3")
        self.assertEqual(len(older["events"]), 9)
        self.assertFalse(older["timeline"]["has_older"])
        self.assertEqual(network.read_text(), network_lines(9))

    def test_external_proxy_changes_are_preserved_and_stop_can_retry_recovery(self):
        code, started = self.begin()
        session = Path(started["session"]["directory"])
        changed = runtime.read_json(self.fake_state)
        changed["proxy"]["http_proxy"] = "external.invalid:9999"
        runtime.write_json(self.fake_state, changed)
        stopped = self.cli("stop", "--session", str(session))[1]
        self.assertEqual(stopped["session"]["phase"], "partial")
        self.assertFalse(stopped["session"]["routing_restored"])
        self.assertEqual(runtime.read_json(self.fake_state)["proxy"]["http_proxy"], "external.invalid:9999")
        journal = runtime.read_json(session / "runtime" / "routing.json")
        changed["proxy"]["http_proxy"] = journal["applied"]["http_proxy"]
        runtime.write_json(self.fake_state, changed)
        recovered = self.cli("stop", "--session", str(session))[1]
        self.assertTrue(recovered["session"]["routing_restored"])
        self.assertEqual(runtime.read_json(self.fake_state), self.original)

    def test_worker_eof_stops_its_owned_child_without_disk_pid_kills(self):
        session = self.root / "worker-session"
        (session / "runtime").mkdir(parents=True)
        marker = self.root / "child-stopped"
        script = self.root / "owned-child.py"
        script.write_text("import pathlib,signal,time,sys\n"
                          "signal.signal(signal.SIGINT,lambda *_:(pathlib.Path(sys.argv[1]).write_text('stopped'),sys.exit(0)))\n"
                          "while True: time.sleep(.05)\n")
        process = runtime.start_worker(session, "owned", [sys.executable, str(script), str(marker)], session / "child.log")
        time.sleep(.3)
        process.stdin.close()
        process.wait(timeout=5)
        self.assertEqual(marker.read_text(), "stopped")

    def test_simulator_pac_is_refused_before_mutation(self):
        session = self.root / "sim-session"
        (session / "runtime").mkdir(parents=True)
        before = {"service_id": "fake-service", "enabled": True, "configuration": {"ProxyAutoConfigEnable": 1}}
        with mock.patch.object(runtime, "proxy_helper", return_value=before) as helper:
            with self.assertRaisesRegex(runtime.CaptureError, "PAC/WPAD"):
                runtime.claim_routing(session, {"platform": "simulator", "device_id": "fake-sim"}, {"network_service": "Fake Wi-Fi"}, {}, 1234)
            helper.assert_called_once_with("snapshot", "Fake Wi-Fi")

    def test_discovery_uses_only_explicit_fake_adb(self):
        with mock.patch.object(runtime, "tools_for", return_value={"adb": str(self.adb), "simctl": None, "mitmdump": str(self.mitm)}):
            devices = runtime.list_devices(runtime.tools_for())
        self.assertEqual(devices, [{"id": "fake-android", "name": "Neutral Sample", "platform": "android", "state": "ready"}])

    def test_stop_clears_android_runtime_cache_before_restoring_unset_keys(self):
        state = {"proxy": {}, "reverse": self.original["reverse"], "effective_proxy": None}
        runtime.write_json(self.fake_state, state)
        code, started = self.begin()
        self.assertEqual(code, 0, started)
        self.assertIsNotNone(runtime.read_json(self.fake_state)["effective_proxy"])
        code, stopped = self.cli("stop", "--session", started["session"]["directory"])
        self.assertEqual(code, 0, stopped)
        restored = runtime.read_json(self.fake_state)
        self.assertIsNone(restored["effective_proxy"])
        self.assertEqual(restored["cache_clear_signals"], 1)
        self.assertEqual(restored["proxy"], {})
        self.assertEqual(restored["reverse"], self.original["reverse"])
        self.assertTrue(stopped["session"]["routing_restored"])
        journal = runtime.read_json(Path(started["session"]["directory"]) / "runtime/routing.json")
        self.assertTrue(journal["runtime_proxy_clear_acknowledged"])

    def test_runtime_cache_clear_without_framework_acknowledgment_fails(self):
        runtime.write_json(self.fake_state, {"proxy": {"global_http_proxy_host":"127.0.0.1", "global_http_proxy_port":"1234"},
                                             "reverse": {}, "effective_proxy":"127.0.0.1:1234"})
        with mock.patch.dict(os.environ, {"FAKE_CAPTURE_CLEAR_STUCK":"1"}):
            with self.assertRaisesRegex(runtime.CaptureError, "did not acknowledge"):
                runtime.android_clear_runtime_proxy({"adb": str(self.adb)}, "fake-android", timeout=.1)
        self.assertEqual(runtime.read_json(self.fake_state)["effective_proxy"], "127.0.0.1:1234")

    def test_missing_clear_acknowledgment_can_retry_stop_with_a_real_setting_transition(self):
        runtime.write_json(self.fake_state, {"proxy": {}, "reverse": self.original["reverse"], "effective_proxy": None})
        # The supervisor inherits a stuck framework for the first Stop. Recovery
        # runs in a fresh CLI after the synthetic framework becomes responsive.
        with mock.patch.dict(os.environ, {"FAKE_CAPTURE_CLEAR_STUCK": "1"}):
            code, started = self.begin()
        self.assertEqual(code, 0, started)
        session = Path(started["session"]["directory"])
        first = self.cli("stop", "--session", str(session))[1]
        self.assertFalse(first["session"]["routing_restored"])
        failed = runtime.read_json(self.fake_state)
        self.assertEqual(failed["proxy"]["http_proxy"], ":0")
        self.assertIsNotNone(failed["effective_proxy"])
        recovered = self.cli("stop", "--session", str(session))[1]
        self.assertTrue(recovered["session"]["routing_restored"], recovered)
        restored = runtime.read_json(self.fake_state)
        self.assertIsNone(restored["effective_proxy"])
        self.assertEqual(restored["proxy"], {})
        self.assertEqual(restored["reverse"], self.original["reverse"])
        self.assertEqual(restored["http_proxy_writes"][-2:], ["", ":0"])
        self.assertEqual(restored["cache_clear_signals"], 1)
        journal = runtime.read_json(session / "runtime" / "routing.json")
        self.assertTrue(journal["runtime_proxy_clear_empty_attempted"])
        self.assertTrue(journal["runtime_proxy_clear_acknowledged"])

    def test_identical_clear_writes_and_deletions_do_not_clear_the_fake_runtime_cache(self):
        runtime.write_json(self.fake_state, {"proxy": {"http_proxy": ":0"}, "reverse": {}, "effective_proxy": "old.invalid:1234"})
        tools = {"adb": str(self.adb)}
        runtime.run(runtime.adb_command(tools, "fake-android", "shell", "settings put global http_proxy :0"))
        self.assertEqual(runtime.read_json(self.fake_state)["effective_proxy"], "old.invalid:1234")
        runtime.run(runtime.adb_command(tools, "fake-android", "shell", "settings delete global http_proxy"))
        self.assertEqual(runtime.read_json(self.fake_state)["effective_proxy"], "old.invalid:1234")

    def test_external_legacy_proxy_change_during_clearing_is_preserved(self):
        runtime.write_json(self.fake_state, {"proxy": {}, "reverse": {}, "effective_proxy": None})
        with mock.patch.dict(os.environ, {"FAKE_CAPTURE_CLEAR_EXTERNAL_PROXY": "external.invalid:9999"}):
            _, started = self.begin()
        result = self.cli("stop", "--session", started["session"]["directory"])[1]
        self.assertFalse(result["session"]["routing_restored"])
        self.assertEqual(runtime.read_json(self.fake_state)["proxy"]["http_proxy"], "external.invalid:9999")
        self.assertTrue(any("preserved" in warning for warning in result["session"]["warnings"]))

    def test_external_modern_proxy_change_during_clearing_is_preserved(self):
        runtime.write_json(self.fake_state, {"proxy": {}, "reverse": {}, "effective_proxy": None})
        with mock.patch.dict(os.environ, {"FAKE_CAPTURE_CLEAR_EXTERNAL_HOST": "external.invalid"}):
            _, started = self.begin()
        result = self.cli("stop", "--session", started["session"]["directory"])[1]
        self.assertFalse(result["session"]["routing_restored"])
        self.assertEqual(runtime.read_json(self.fake_state)["proxy"]["global_http_proxy_host"], "external.invalid")

    def test_external_change_after_clear_acknowledgment_is_not_overwritten(self):
        session = self.root / "clear-ack-race"
        journal_path = session / "runtime" / "routing.json"
        applied = dict(runtime.ANDROID_CLEARED_PROXY, http_proxy="127.0.0.1:1234", global_http_proxy_host="127.0.0.1", global_http_proxy_port="1234")
        journal = {"platform": "android", "tools": {"adb": str(self.adb)}, "device_id": "fake-android", "proxy_attempted": True,
                   "before": {key: None for key in runtime.PROXY_KEYS}, "applied": applied}
        runtime.write_json(journal_path, journal)
        external = dict(runtime.ANDROID_CLEARED_PROXY, http_proxy="external.invalid:9999")
        with mock.patch.object(runtime, "android_proxy_snapshot", side_effect=[applied, external]), \
             mock.patch.object(runtime, "android_clear_runtime_proxy"), mock.patch.object(runtime, "android_write_proxy") as write:
            with self.assertRaisesRegex(runtime.CaptureError, "changed after its clear acknowledgment"):
                runtime.restore_routing(session)
        write.assert_not_called()
        self.assertFalse(runtime.read_json(journal_path).get("restored", False))

    def test_previously_acknowledged_complete_clear_is_reused_without_another_notification(self):
        session = self.root / "clear-already-acknowledged"
        journal_path = session / "runtime" / "routing.json"
        runtime.write_json(self.fake_state, {"proxy": dict(runtime.ANDROID_CLEARED_PROXY), "reverse": {}, "effective_proxy": None, "http_proxy_writes": []})
        applied = dict(runtime.ANDROID_CLEARED_PROXY, http_proxy="127.0.0.1:1234", global_http_proxy_host="127.0.0.1", global_http_proxy_port="1234")
        runtime.write_json(journal_path, {"platform": "android", "tools": {"adb": str(self.adb)}, "device_id": "fake-android", "proxy_attempted": True,
                                        "before": {key: None for key in runtime.PROXY_KEYS}, "applied": applied,
                                        "runtime_proxy_clear_attempted": True, "runtime_proxy_clear_acknowledged": True})
        self.assertTrue(runtime.restore_routing(session))
        restored = runtime.read_json(self.fake_state)
        self.assertEqual(restored["proxy"], {})
        self.assertEqual(restored["http_proxy_writes"], [])

    def test_crash_after_owned_empty_transition_remains_recoverable(self):
        session = self.root / "clear-empty-crash"
        journal_path = session / "runtime" / "routing.json"
        applied = dict(runtime.ANDROID_CLEARED_PROXY, http_proxy="127.0.0.1:1234", global_http_proxy_host="127.0.0.1", global_http_proxy_port="1234")
        runtime.write_json(self.fake_state, {"proxy": dict(applied, http_proxy=""), "reverse": {}, "effective_proxy": "127.0.0.1:1234"})
        runtime.write_json(journal_path, {"platform": "android", "tools": {"adb": str(self.adb)}, "device_id": "fake-android", "proxy_attempted": True,
                                        "before": {key: None for key in runtime.PROXY_KEYS}, "applied": applied,
                                        "runtime_proxy_clear_attempted": True, "runtime_proxy_clear_empty_attempted": True})
        self.assertTrue(runtime.restore_routing(session))
        self.assertIsNone(runtime.read_json(self.fake_state)["effective_proxy"])
        self.assertEqual(runtime.read_json(self.fake_state)["proxy"], {})

    def test_mitmdump_discovery_without_login_shell_path(self):
        # Finder-launched apps do not necessarily inherit Homebrew/pipx PATH.
        for installed in ("/opt/homebrew/bin/mitmdump", "/usr/local/bin/mitmdump", "~/.local/bin/mitmdump"):
            with self.subTest(installed=installed), mock.patch.object(runtime.shutil, "which", return_value=None), \
                    mock.patch.object(runtime.glob, "glob", side_effect=lambda pattern: [str(self.mitm)] if pattern == str(Path(installed).expanduser()) else []):
                tools = runtime.tools_for({"adb_path": str(self.adb), "simctl_path": str(self.simctl)})
                self.assertEqual(tools["mitmdump"], str(self.mitm))

    def test_startup_sigkill_without_stderr_has_actionable_macos_hint(self):
        session = self.root / "blocked-startup"
        runtime.write_json(session / "runtime" / "network-worker.result.json", {"exit_code": -9})
        with mock.patch.object(runtime.sys, "platform", "darwin"):
            message = str(runtime.network_startup_failure(session, str(self.mitm)))
        self.assertIn("SIGKILL", message)
        self.assertIn(str(self.mitm), message)
        self.assertIn("may have blocked", message)
        self.assertIn("Privacy & Security > Open Anyway", message)
        self.assertIn("does not prove", message)

    def test_startup_keeps_tool_diagnostic_without_claiming_security_block(self):
        session = self.root / "bad-addon"
        runtime.write_json(session / "runtime" / "network-worker.result.json", {"exit_code": 1})
        (session / "runtime" / "network.stderr").write_text("Addon import failed")
        message = str(runtime.network_startup_failure(session, str(self.mitm)))
        self.assertIn("exit code 1", message)
        self.assertIn("Addon import failed", message)
        self.assertNotIn("Open Anyway", message)

    def test_stop_does_not_recover_or_export_while_owner_lock_is_held(self):
        session = self.root / "busy-session"
        (session / "runtime").mkdir(parents=True)
        runtime.write_json(session / "session.json", {"id": "busy", "directory": str(session), "phase": "preparing", "routing_restored": None,
                                                     "sources": {"logs": "preparing", "network": "preparing"}, "warnings": []})
        ownership = runtime.acquire_routing_lock(session)
        try:
            with mock.patch.object(runtime, "control_request", return_value=False), mock.patch.object(runtime, "restore_routing") as restore:
                result = runtime.stop(session)
            restore.assert_not_called()
            self.assertEqual(result["session"]["phase"], "preparing")
            self.assertIn("still owns", result["session"]["warnings"][-1])
        finally:
            ownership.close()

    def test_status_never_clobbers_terminal_state_when_ping_races_finalization(self):
        session = self.root / "status-race"
        session.mkdir()
        active = {"id": "race", "directory": str(session), "phase": "recording", "sources": {}, "warnings": [], "package_path": None}
        runtime.write_json(session / "session.json", active)

        def completed(*_):
            runtime.write_json(session / "session.json", dict(active, phase="saved", package_path="/private/final.zip"))
            return False

        with mock.patch.object(runtime, "control_request", side_effect=completed):
            result = runtime.status(session)
        self.assertEqual(result["session"]["phase"], "saved")
        self.assertEqual(runtime.read_json(session / "session.json")["package_path"], "/private/final.zip")

    def test_mixed_decoded_requests_and_tls_gaps_are_partial(self):
        _, started = self.begin(capture_logs=False)
        session = Path(started["session"]["directory"])
        event = {"id": "tls-gap", "source": "network", "kind": "tls_error", "timestamp": runtime.now(),
                 "summary": "Synthetic untrusted CA", "detail": {}, "raw_ref": "network/events.jsonl"}
        with (session / "network" / "events.jsonl").open("a") as stream:
            stream.write(json.dumps(event) + "\n")
        result = self.cli("stop", "--session", str(session))[1]
        self.assertEqual(result["session"]["phase"], "partial")
        self.assertEqual(result["session"]["sources"]["network"], "observed")
        self.assertEqual(result["session"]["completeness"]["network_errors"]["tls_error"], 1)

    def test_terminal_missing_package_can_retry_export(self):
        _, started = self.begin(capture_network=False)
        session = Path(started["session"]["directory"])
        self.cli("stop", "--session", str(session))
        state = runtime.read_json(session / "session.json")
        original_stopped_at = state["stopped_at"]
        Path(state["package_path"]).unlink()
        state.update(phase="partial", package_path=None)
        runtime.write_json(session / "session.json", state)
        result = self.cli("stop", "--session", str(session))[1]
        self.assertIsNotNone(result["session"]["package_path"])
        self.assertTrue(Path(result["session"]["package_path"]).exists())
        self.assertFalse(result["session"]["completeness"]["interrupted"])
        self.assertFalse(result["session"]["completeness"]["startup_failed"])
        self.assertEqual(result["session"]["sources"]["logs"], "observed")
        self.assertEqual(result["session"]["stopped_at"], original_stopped_at)
        self.assertFalse(any("Recovered after supervisor interruption" in warning for warning in result["session"]["warnings"]))

    def test_export_retry_preserves_interruption_and_startup_failure_history(self):
        _, started = self.begin(capture_network=False)
        session = Path(started["session"]["directory"])
        self.cli("stop", "--session", str(session))
        baseline = runtime.read_json(session / "session.json")
        for interrupted, startup_failed, source, phase in ((True, False, "interrupted", "partial"), (False, True, "failed", "failed")):
            with self.subTest(interrupted=interrupted, startup_failed=startup_failed):
                state = json.loads(json.dumps(baseline))
                state.update(phase=phase, package_path=None)
                state["sources"]["logs"] = source
                state["completeness"].update(interrupted=interrupted, startup_failed=startup_failed)
                runtime.write_json(session / "session.json", state)
                result = self.cli("stop", "--session", str(session))[1]["session"]
                self.assertEqual(result["completeness"]["interrupted"], interrupted)
                self.assertEqual(result["completeness"]["startup_failed"], startup_failed)
                self.assertEqual(result["sources"]["logs"], source)
                self.assertEqual(result["phase"], phase)

    def test_simulator_target_resolves_executable_and_escapes_exact_predicate(self):
        executable = 'Capture "Proof"\\测试'
        request = {"device_id": "fake-simulator", "target_app": "dev.sample.proof"}
        state = {"warnings": []}
        apps = {"dev.sample.proof": {"CFBundleIdentifier": "dev.sample.proof", "CFBundleExecutable": executable}}
        with mock.patch.object(runtime, "run", return_value=SimpleNamespace(stdout=json.dumps(apps))) as run:
            command = runtime.simulator_log_command(request, {"simctl": str(self.simctl)}, state)
        run.assert_called_once_with([str(self.simctl), "listapps", "fake-simulator"])
        expected = 'process == "Capture \\"Proof\\"\\\\测试"'
        self.assertEqual(command[-2:], ["--predicate", expected])
        self.assertEqual(state["context"]["log_scope"]["executable"], executable)
        self.assertIn(expected, state["warnings"][-1])

    def test_simulator_app_metadata_accepts_xml_and_openstep_plists(self):
        apps = {"dev.sample.proof": {"CFBundleExecutable": "CaptureProof"}}
        self.assertEqual(runtime.simulator_apps(plistlib.dumps(apps).decode()), apps)
        openstep = '{ "dev.sample.proof" = { CFBundleExecutable = CaptureProof; }; }'
        self.assertEqual(runtime.simulator_apps(openstep), apps)

    def test_simulator_target_resolves_missing_executable_from_container_info_plist(self):
        container = self.root / "Neutral Sample.app"
        container.mkdir()
        with (container / "Info.plist").open("wb") as out:
            plistlib.dump({"CFBundleExecutable": "CaptureProof"}, out)
        state = {"warnings": []}
        request = {"device_id": "fake-simulator", "target_app": "dev.sample.proof"}
        with mock.patch.object(runtime, "run", side_effect=[SimpleNamespace(stdout=json.dumps({"dev.sample.proof": {}})), SimpleNamespace(stdout=str(container) + "\n")]) as run:
            command = runtime.simulator_log_command(request, {"simctl": str(self.simctl)}, state)
        self.assertEqual(run.call_args_list[-1].args[0], [str(self.simctl), "get_app_container", "fake-simulator", "dev.sample.proof", "app"])
        self.assertEqual(command[-1], 'process == "CaptureProof"')
        self.assertIn("Info.plist", state["context"]["log_scope"]["resolution"])

    def test_unknown_simulator_target_fails_before_proxy_or_workers_start(self):
        request = {"platform": "simulator", "device_id": "fake-simulator", "capture_logs": True, "capture_network": True, "target_app": "dev.missing.app"}
        state = {"warnings": []}
        with mock.patch.object(runtime, "tools_for", return_value={"simctl": str(self.simctl)}), \
             mock.patch.object(runtime, "list_devices", return_value=[{"id": "fake-simulator", "platform": "simulator", "state": "booted", "name": "Neutral Simulator"}]), \
             mock.patch.object(runtime, "run", return_value=SimpleNamespace(stdout="{}")), \
             mock.patch.object(runtime, "claim_routing") as routing, mock.patch.object(runtime, "start_worker") as worker:
            with self.assertRaisesRegex(runtime.CaptureError, "not installed"):
                runtime.prepare(self.root, state, request, {})
        routing.assert_not_called()
        worker.assert_not_called()

    def test_empty_simulator_target_retains_broad_logs_and_warns_about_volume(self):
        state = {"warnings": []}
        with mock.patch.object(runtime, "run") as run:
            command = runtime.simulator_log_command({"device_id": "fake-simulator", "target_app": " "}, {"simctl": str(self.simctl)}, state)
        run.assert_not_called()
        self.assertNotIn("--predicate", command)
        self.assertEqual(state["context"]["log_scope"]["mode"], "all_simulator_processes")
        self.assertIn("High volume", state["warnings"][-1])


@unittest.skipUnless(os.environ.get("CAPTURE_TEST_MITMDUMP"), "Set CAPTURE_TEST_MITMDUMP for an isolated real-proxy body fidelity check")
class RealProxyBodyTests(unittest.TestCase):
    def test_real_http_post_native_har_and_events_retain_full_binary_bodies(self):
        request_body = b"\x00\xffneutral-request:" + bytes(range(256)) * 512
        response_body = b"\xfe\x00neutral-response:" + bytes(range(256)) * 1024
        observed = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                observed.append(self.rfile.read(int(self.headers["Content-Length"])))
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)

            def log_message(self, *_):
                pass

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "network").mkdir()
            ca = root / "private-ca"
            ca.mkdir(mode=0o700)
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            port = runtime.free_port()
            environment = dict(os.environ, CAPTURE_SESSION_DIR=str(root))
            command = [os.environ["CAPTURE_TEST_MITMDUMP"], "--listen-host", "127.0.0.1", "--listen-port", str(port),
                       "--set", f"confdir={ca}", "--set", "store_streamed_bodies=true", "-s", str(ROOT / "CaptureRuntime" / "network_addon.py"),
                       "-w", str(root / "network" / "capture.mitm")]
            with (root / "proxy.stderr").open("wb") as errors:
                process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=errors, env=environment)
                try:
                    deadline = time.monotonic() + 20
                    while not (root / "network" / "ready.json").exists():
                        if process.poll() is not None or time.monotonic() > deadline:
                            self.fail("Real proxy did not become ready: " + (root / "proxy.stderr").read_text())
                        time.sleep(.1)
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                    connection.request("POST", f"http://127.0.0.1:{server.server_port}/neutral", request_body, {"Content-Type": "application/octet-stream"})
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), response_body)
                    connection.close()
                finally:
                    if process.poll() is None:
                        process.send_signal(signal.SIGINT)
                        process.wait(timeout=15)
                    server.shutdown()
                    server.server_close()
            self.assertEqual(observed, [request_body])
            har = runtime.read_json(root / "network" / "capture.har")["log"]["entries"][0]
            self.assertEqual(base64.b64decode(har["request"]["postData"]["text"]), request_body)
            self.assertEqual(base64.b64decode(har["response"]["content"]["text"]), response_body)
            events = [json.loads(line) for line in (root / "network" / "events.jsonl").read_text().splitlines()]
            details = next(event["detail"] for event in events if event["kind"] == "response")
            self.assertEqual(base64.b64decode(details["request_body"]["text"]), request_body)
            self.assertEqual(base64.b64decode(details["response_body"]["text"]), response_body)
            # Read the actual native format with the same installed official tool.
            verifier = root / "verify_native.py"
            result_path = root / "native-bodies.json"
            verifier.write_text("import base64,json\nfrom pathlib import Path\n"
                                "def response(flow):\n"
                                "    value={'request':base64.b64encode(flow.request.raw_content).decode(),'response':base64.b64encode(flow.response.raw_content).decode()}\n"
                                f"    Path({str(result_path)!r}).write_text(json.dumps(value))\n")
            checked = subprocess.run([os.environ["CAPTURE_TEST_MITMDUMP"], "-nr", str(root / "network" / "capture.mitm"),
                                      "--set", f"confdir={ca}", "-s", str(verifier)], capture_output=True, text=True, timeout=20)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            native = runtime.read_json(result_path)
            self.assertEqual(base64.b64decode(native["request"]), request_body)
            self.assertEqual(base64.b64decode(native["response"]), response_body)


if __name__ == "__main__":
    unittest.main()
