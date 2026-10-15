"""Synthetic browser-check boundaries; no device, certificate trust or routing changes."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("capture_setup_addon", ROOT / "CaptureRuntime/network_addon.py")
ADDON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADDON)


class SetupProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.nonce = "a" * 32
        environment = mock.patch.dict(os.environ, {"CAPTURE_SESSION_DIR": self.temporary.name,
                                                  "CAPTURE_SETUP_NONCE": self.nonce})
        environment.start()
        self.addCleanup(environment.stop)
        self.addon = ADDON.CaptureAddon()
        response = SimpleNamespace(make=lambda status, content, headers: SimpleNamespace(status_code=status, content=content, headers=headers))
        modules = mock.patch.dict("sys.modules", {"mitmproxy": SimpleNamespace(http=SimpleNamespace(Response=response))})
        modules.start()
        self.addCleanup(modules.stop)

    def flow(self, scheme="http", suffix="", host="mitm.it", method="GET", nonce=None):
        return SimpleNamespace(request=SimpleNamespace(host=host, method=method, scheme=scheme,
            path="/mobile-capture-check/" + (nonce or self.nonce) + suffix), response=None, metadata={})

    def test_only_current_nonce_and_explicit_route_are_served(self):
        for flow in [self.flow(host="example.com"), self.flow(method="POST"), self.flow(nonce="b" * 32),
                     self.flow(suffix="/private-key.pem"), self.flow(suffix="?token=ignored")]:
            with self.subTest(flow=flow):
                self.addon.setup_response(flow)
                self.assertIsNone(flow.response)
                self.assertEqual(flow.metadata, {})
        page = self.flow()
        self.addon.setup_response(page)
        self.assertEqual(page.response.status_code, 200)
        self.assertEqual(page.response.headers["Cache-Control"], "no-store")
        self.assertIn(b"https://mitm.it/mobile-capture-check/", page.response.content)
        self.assertIn(b"credentials:'omit'", page.response.content)

    def test_plain_http_never_yields_https_success(self):
        flow = self.flow(suffix="/https")
        self.addon.setup_response(flow)
        self.assertEqual(flow.response.status_code, 400)
        self.assertNotIn("mobile_capture_setup_nonce", flow.metadata)

    def test_https_response_has_exact_nonce_and_synthetic_unicode_body(self):
        flow = self.flow(scheme="https", suffix="/https")
        self.addon.setup_response(flow)
        payload = json.loads(flow.response.content)
        self.assertEqual(flow.response.status_code, 200)
        self.assertEqual(payload["nonce"], self.nonce)
        self.assertEqual(payload["capture_check"], "browser_https")
        self.assertIn("café", payload["message"])
        self.assertEqual(flow.metadata["mobile_capture_setup_nonce"], self.nonce)
        self.assertEqual(flow.response.headers["Access-Control-Allow-Origin"], "http://mitm.it")

    def test_no_setup_routes_for_regular_recordings_or_invalid_nonce(self):
        for nonce in ["", "../private", "A" * 32, "a" * 1000]:
            with self.subTest(nonce=nonce), mock.patch.dict(os.environ, {"CAPTURE_SETUP_NONCE": nonce}):
                addon = ADDON.CaptureAddon()
                flow = self.flow()
                addon.setup_response(flow)
                self.assertIsNone(flow.response)


if __name__ == "__main__":
    unittest.main()
