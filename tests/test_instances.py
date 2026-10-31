#!/usr/bin/env python3
"""Cross-process control and CLI checks, with an engine-free native helper."""
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

BUILD = Path(sys.argv.pop(1) if len(sys.argv) > 1 else "build").resolve()


class Instances(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="kapitsa-instances-")
        cls.home = Path(cls.tmp.name)
        cls.env = dict(os.environ, KAPITSA_HOME=str(cls.home))
        cls.cli = cls.home / "kapitsa"
        shutil.copy2(BUILD / "kapitsa", cls.cli)
        # Exercise the actual launcher and machine configuration transport,
        # replacing only the model-running helper with the CPU fixture.
        helper = cls.home / "kapitsa-runtime"
        helper.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "config = json.load(sys.stdin)\n"
            "home = Path(os.environ['KAPITSA_HOME'])\n"
            "identifier = config['instance_id']\n"
            "(home / (identifier + '-config.json')).write_text(json.dumps(config))\n"
            "os.setsid()\n"
            f"os.execv({str(BUILD / 'runtime_test')!r}, ['runtime_test', '--fixture', "
            "str(home / 'instances'), identifier])\n"
        )
        helper.chmod(0o700)
        cls.started = []
        try:
            for name, port in [("code", 8000), ("chat", 8001)]:
                p = cls.run_cli("start", "--name", name, "--model", "fake", "--port", str(port), "--context", "90k")
                if p.returncode:
                    raise RuntimeError(p.stderr)
                cls.started.append(name)
        except Exception:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        for name in cls.started:
            cls.run_cli("stop", "--instance", name)
        time.sleep(0.4)
        cls.tmp.cleanup()

    @classmethod
    def run_cli(cls, *args):
        return subprocess.run([str(cls.cli), *args], env=cls.env, text=True, capture_output=True, timeout=15)

    def status(self, name):
        p = self.run_cli("status", "--instance", name, "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)

    def test_configuration_transport(self):
        config = json.loads((self.home / "code-config.json").read_text())
        self.assertEqual(config["context"], 90 * 1024)
        self.assertEqual(config["port"], 8000)
        self.assertEqual(config["instance_id"], "code")

    def test_discovery_and_public_output(self):
        p = self.run_cli("instances", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        records = json.loads(p.stdout)
        self.assertEqual({r["instance_id"] for r in records}, {"code", "chat"})
        self.assertNotEqual(records[0]["pid"], records[1]["pid"])
        for r in records:
            self.assertNotIn("token", r)
            self.assertNotIn("control_url", r)

    def test_ambiguity_is_explicit(self):
        p = self.run_cli("status", "--json")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ambiguous", p.stderr)

    def test_duplicate_start_preserves_owner(self):
        before = self.status("code")
        p = self.run_cli("start", "--name", "code", "--model", "fake")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.status("code")["run_id"], before["run_id"])

    def test_resume_detaches_without_cancelling(self):
        before = self.status("code")["requests"][0]["completion_tokens"]
        p = subprocess.Popen([str(self.cli), "resume", "--instance", "code", "--json"],
                             env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(p.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=5), "observer did not attach")
            first = json.loads(p.stdout.readline())
            self.assertEqual(first["instance_id"], "code")
            p.send_signal(signal.SIGINT)
            _, err = p.communicate(timeout=5)
            self.assertEqual(p.returncode, 0, err)
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()
        time.sleep(0.1)
        self.assertGreater(self.status("code")["requests"][0]["completion_tokens"], before)

    def test_stale_record_is_visible_without_hiding_live_instances(self):
        path = self.home / "instances" / "dead.json"
        record = {"protocol": 1, "instance_id": "dead", "run_id": str(uuid.uuid4()),
                  "name": "dead", "pid": 1, "control_url": "http://127.0.0.1:1", "token": str(uuid.uuid4())}
        path.write_text(json.dumps(record))
        path.chmod(0o600)
        try:
            p = self.run_cli("instances", "--json")
            self.assertEqual(p.returncode, 0, p.stderr)
            statuses = {r["instance_id"]: r["state"] for r in json.loads(p.stdout)}
            self.assertEqual(statuses, {"code": "ready", "chat": "ready", "dead": "unreachable"})
        finally:
            path.unlink()

    def test_native_configuration_checks_without_a_model(self):
        good = {"protocol": 1, "instance_id": "native", "model": "fake", "context": 32768}
        variants = [good, dict(good, protocol=2), dict(good, slots=True),
                    dict(good, instance_id="../escape"), dict(good, context=2**64 - 1),
                    dict(good, unknown=True), dict(good, mem_budget_gb=-1), dict(good, disk_cache="invalid")]
        for i, config in enumerate(variants):
            p = subprocess.run([str(BUILD / "kapitsa-runtime"), "--check"], input=json.dumps(config),
                               env=self.env, text=True, capture_output=True, timeout=5)
            self.assertEqual(p.returncode == 0, i == 0, p.stderr)
        self.assertFalse((self.home / "instances" / "native.json").exists())

    def test_native_configuration_roundtrip_preserves_requested_options(self):
        base = {"protocol": 1, "instance_id": "edit", "name": "Edited", "model": "fake", "port": 8012}
        explicit = dict(base, context=92160, slots=2, spec=0, mem_budget_gb=24.5,
                        dflash="/custom/drafter", disk_cache="512m", prefill_chunk=512)
        for config in [base, explicit]:
            p = subprocess.run([str(BUILD / "kapitsa-runtime"), "--check"], input=json.dumps(config),
                               env=self.env, text=True, capture_output=True, timeout=5)
            self.assertEqual(p.returncode, 0, p.stderr)
            exported = json.loads(p.stdout)["configuration"]
            self.assertEqual(exported, config)
            second = subprocess.run([str(BUILD / "kapitsa-runtime"), "--check"], input=json.dumps(exported),
                                    env=self.env, text=True, capture_output=True, timeout=5)
            self.assertEqual(second.returncode, 0, second.stderr)

    def test_z_stop_selects_only_one_instance(self):
        other = self.status("code")["run_id"]
        p = self.run_cli("stop", "--instance", "chat", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["state"], "stopping")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self.run_cli("status", "--instance", "chat").returncode == 0:
            time.sleep(0.05)
        self.assertNotEqual(self.run_cli("status", "--instance", "chat").returncode, 0)
        self.assertEqual(self.status("code")["run_id"], other)


if __name__ == "__main__":
    unittest.main()
