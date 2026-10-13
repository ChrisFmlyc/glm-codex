"""Exercise fresh-copy launchers against a local endpoint, without real secrets."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import tomllib
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = os.environ.get("GLM_TEST_PWSH") or shutil.which("pwsh") or shutil.which("powershell")
LAUNCHERS = (["bash"] if shutil.which("bash") and os.name != "nt" else []) + (["powershell"] if POWERSHELL else [])


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.clone = self.folder / "Fresh Clone"
        shutil.copytree(ROOT / "scripts", self.clone / "scripts")
        self.project = self.folder / "MixedCase Project"
        self.project.mkdir()
        self.env_file = self.clone / ".env"
        self.capture = self.folder / "capture.json"
        self.marker = self.folder / "executed-env-command"
        self.body = {"data": [{"max_model_len": 1048576, "id": "glm-5.3-flash", "object": "model"}]}
        self.status = 200
        self.requests = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append((self.path, self.headers.get("Authorization")))
                status = owner.status if self.headers.get("Authorization") == "Bearer test-endpoint-key" else 401
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                body = owner.body
                self.wfile.write((body if isinstance(body, str) else json.dumps(body, indent=2)).encode())

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}/v1"
        self.bin = self.folder / "bin"
        self.bin.mkdir()
        (self.bin / "codex-stub.cjs").write_text('''const fs = require('node:fs');
fs.writeFileSync(process.env.GLM_TEST_CAPTURE, JSON.stringify({
  args: process.argv.slice(2),
  config: fs.readFileSync(process.env.CODEX_HOME + '/config.toml', 'utf8'),
  home: process.env.CODEX_HOME,
}));
process.exit(process.argv.includes('--test-fail') ? 7 : 0);
''')
        if os.name == "nt":
            (self.bin / "codex.cmd").write_text('@echo off\r\nnode "%~dp0codex-stub.cjs" %*\r\nexit /b %ERRORLEVEL%\r\n')
        else:
            stub = self.bin / "codex"
            stub.write_text('#!/bin/sh\nexec node "$(dirname "$0")/codex-stub.cjs" "$@"\n')
            stub.chmod(0o755)

    def settings(self, **overrides):
        values = {"GLM_BASE_URL": self.base, "GLM_API_KEY": "test-endpoint-key",
                  "GLM_MODEL_NAME": "stale-alias", "GLM_MAX_CONTEXT": "65536"}
        values.update(overrides)
        self.env_file.write_text("".join(f"{k}={v}\n" for k, v in values.items()))

    def launch(self, launcher, *args, explicit=True):
        self.capture.unlink(missing_ok=True)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("GLM_") and k not in ("CODEX_APPROVAL", "CODEX_SANDBOX", "CODEX_HOME")}
        env["PATH"] = str(self.bin) + os.pathsep + env["PATH"]
        env["GLM_TEST_CAPTURE"] = str(self.capture)
        if launcher == "bash":
            cmd = ["bash", str(self.clone / "scripts/codex-glm.sh")]
        else:
            cmd = [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                   "-File", str(self.clone / "scripts/codex-glm.ps1")]
        if explicit:
            cmd += ["-e", str(self.env_file)]
        result = subprocess.run(cmd + list(args), cwd=self.project, env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        if self.capture.exists():
            capture = json.loads(self.capture.read_text())
            config = tomllib.loads(capture["config"])
        else:
            capture, config = None, None
        return result, capture, config

    def each(self):
        if not LAUNCHERS:
            self.skipTest("No supported launcher interpreter installed")
        return LAUNCHERS

    def test_fresh_clone_normalizes_saved_url_and_discovers_model_and_context(self):
        for launcher in self.each():
            with self.subTest(launcher=launcher):
                self.settings(GLM_BASE_URL=f'"{self.base}/models/"', GLM_API_KEY="'test-endpoint-key'")
                # A .env received from Windows is usable in either launcher.
                self.env_file.write_bytes(self.env_file.read_bytes().replace(b"\n", b"\r\n"))
                result, capture, config = self.launch(launcher)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(capture["args"], ["-m", "glm-5.3-flash"])
                self.assertEqual(config["model_context_window"], 1048576)
                self.assertEqual(config["model_providers"]["glm"]["base_url"], self.base)
                self.assertEqual(config["model_providers"]["glm"]["wire_api"], "responses")
                self.assertEqual(config["approval_policy"], "never")
                self.assertEqual(config["sandbox_mode"], "danger-full-access")
                project = str(self.project).lower() if os.name == "nt" else str(self.project)
                self.assertEqual(config["projects"][project]["trust_level"], "trusted")
                self.assertEqual(Path(capture["home"]), self.clone / ".codex-home")
                self.assertNotIn("test-endpoint-key", capture["config"])
                self.assertNotIn("model_max_output_tokens", config)
                saved = self.env_file.read_text()
                self.assertIn("GLM_MODEL_NAME=glm-5.3-flash", saved)
                self.assertIn("GLM_MAX_CONTEXT=1048576", saved)
                self.assertEqual(self.requests[-1], ("/v1/models", "Bearer test-endpoint-key"))

    def test_selected_model_in_multi_model_response_keeps_its_own_context(self):
        self.body["data"].append({"id": "second-model", "max_model_len": 32768})
        for launcher in self.each():
            with self.subTest(launcher=launcher):
                self.settings(GLM_MODEL_NAME="glm-5.3-flash")
                result, _, config = self.launch(launcher)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(config["model_context_window"], 1048576)

    def test_ambiguous_model_stops_before_launching_codex(self):
        self.body["data"].append({"id": "second-model", "max_model_len": 32768})
        for launcher in self.each():
            with self.subTest(launcher=launcher):
                self.settings()
                result, capture, _ = self.launch(launcher)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(capture)
                self.assertIn("second-model", result.stdout + result.stderr)

    def test_missing_advertised_context_uses_env_and_still_discovers_alias(self):
        del self.body["data"][0]["max_model_len"]
        for launcher in self.each():
            with self.subTest(launcher=launcher):
                self.settings()
                result, _, config = self.launch(launcher)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(config["model"], "glm-5.3-flash")
                self.assertEqual(config["model_context_window"], 65536)

    def test_invalid_model_responses_stop_before_launching_codex(self):
        invalid = ["<html>wrong website</html>", {"data": []}, {"data": [{"id": "x", "max_model_len": -1}]},
                   {"data": [{"id": "x", "max_model_len": "1048576"}]}]
        for launcher in self.each():
            for body in invalid:
                with self.subTest(launcher=launcher, body=body):
                    self.settings()
                    self.body = body
                    result, capture, _ = self.launch(launcher)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNone(capture)
                    self.assertIn("invalid /v1/models response", result.stdout + result.stderr)

    def test_unready_and_unauthorized_endpoint_fail_without_a_terminal(self):
        for launcher in self.each():
            for status in (401, 503):
                with self.subTest(launcher=launcher, status=status):
                    self.settings()
                    self.status = status
                    result, capture, _ = self.launch(launcher)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNone(capture)
                    self.assertIn(str(status), result.stdout + result.stderr)

    def test_trust_is_preserved_and_args_and_exit_status_are_forwarded(self):
        for launcher in self.each():
            with self.subTest(launcher=launcher):
                self.settings()
                home = self.clone / ".codex-home"
                home.mkdir(exist_ok=True)
                (home / "config.toml").write_text("[projects.'/previous/project']\ntrust_level = \"trusted\"\n")
                result, capture, config = self.launch(launcher, "exec", "--test-fail", "a task with spaces")
                self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
                self.assertEqual(capture["args"], ["-m", "glm-5.3-flash", "exec", "--test-fail", "a task with spaces"])
                self.assertEqual(config["projects"]["/previous/project"]["trust_level"], "trusted")

    def test_explicit_env_wins_and_shell_expressions_are_never_executed(self):
        (self.project / ".env").write_text("GLM_BASE_URL=http://wrong.invalid/v1\nGLM_API_KEY=wrong\n")
        for launcher in self.each():
            with self.subTest(launcher=launcher):
                self.settings(GLM_UNUSED=f'$(touch "{self.marker}")')
                result, _, _ = self.launch(launcher)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.marker.exists())

    def test_repo_env_fallback_and_auto_mode(self):
        for launcher in self.each():
            with self.subTest(launcher=launcher):
                self.settings()
                result, _, config = self.launch(launcher, "--auto-mode", explicit=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(config["approval_policy"], "on-request")
                self.assertEqual(config["sandbox_mode"], "workspace-write")
                self.assertTrue(config["sandbox_workspace_write"]["network_access"])
                if os.name == "nt":
                    self.assertEqual(config["windows"]["sandbox"], "unelevated")

    def test_scripts_remain_portable(self):
        script = ROOT / "scripts/codex-glm.ps1"
        script.read_bytes().decode("ascii")
        if shutil.which("bash") and os.name != "nt":
            subprocess.run(["bash", "-n", str(ROOT / "scripts/codex-glm.sh")], check=True)


if __name__ == "__main__":
    unittest.main()
