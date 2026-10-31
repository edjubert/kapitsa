#!/usr/bin/env python3
"""Native desktop model API: real downloader, tiny synthetic files, no inference."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

BUILD = Path(sys.argv.pop(1) if len(sys.argv) > 1 else "build").resolve()


class NativeModels(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kapitsa-native-models-")
        self.home = Path(self.tmp.name)
        files = {
            "config.json": json.dumps({"model_type": "qwen3_5", "linear_num_value_heads": 1,
                                       "num_hidden_layers": 1}).encode(),
            "model.safetensors": b"synthetic-download-fixture" * 12_000,
        }
        self.files = files
        self.slow = False
        self.requests = []
        self.ranges = []
        self.catalog_files = {}
        test = self

        class Hub(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                test.requests.append(self.path)
                test.ranges.append((self.path, self.headers.get("Range")))
                if self.path.startswith("/api/models/fixture/tiny/revision/"):
                    body = json.dumps({"sha": "fixed", "siblings": [
                        {"rfilename": name, "size": len(data),
                         "lfs": {"sha256": hashlib.sha256(data).hexdigest()}}
                        for name, data in files.items()]}).encode()
                elif self.path.startswith("/fixture/tiny/resolve/fixed/"):
                    body = files[self.path.rsplit("/", 1)[1]]
                elif test.catalog_files and self.path.startswith("/api/models/") and "/revision/" in self.path:
                    body = json.dumps({"sha": self.path.rsplit("/", 1)[1], "siblings": [
                        {"rfilename": name, "size": len(data)}
                        for name, data in test.catalog_files.items()]}).encode()
                elif test.catalog_files and "/resolve/" in self.path:
                    body = test.catalog_files.get(self.path.rsplit("/", 1)[1])
                    if body is None:
                        self.send_error(404)
                        return
                else:
                    self.send_error(404)
                    return
                status, lo, hi = 200, 0, len(body) - 1
                if value := self.headers.get("Range"):
                    lo, hi = map(int, value.removeprefix("bytes=").split("-"))
                    hi = min(hi, len(body) - 1)
                    status = 206
                self.send_response(status)
                if status == 206:
                    self.send_header("Content-Range", f"bytes {lo}-{hi}/{len(body)}")
                self.send_header("Content-Length", str(hi - lo + 1))
                self.end_headers()
                try:
                    for offset in range(lo, hi + 1, 4096):
                        self.wfile.write(body[offset:min(offset + 4096, hi + 1)])
                        self.wfile.flush()
                        if test.slow and self.path.endswith("safetensors"):
                            time.sleep(0.02)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.env = dict(os.environ, KAPITSA_HOME=str(self.home),
                        HF_ENDPOINT=f"http://127.0.0.1:{self.server.server_port}",
                        HF_TOKEN="", HUGGING_FACE_HUB_TOKEN="",
                        HF_TOKEN_PATH=str(self.home / "absent-token"), HF_HOME=str(self.home / "hf"))

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def run_request(self, request):
        process = subprocess.run([str(BUILD / "kapitsa-runtime"), "--model-request"],
                                 input=json.dumps(request), capture_output=True, text=True,
                                 env=self.env, timeout=15)
        messages = [json.loads(line) for line in process.stdout.splitlines()]
        return process, messages

    @staticmethod
    def planning_files(weights):
        # Real model shapes and a header describing large weights, but none of
        # their data. Any accidental load would fail instead of running inference.
        config = {"model_type": "qwen3_5_moe", "text_config": {
            "hidden_size": 2048, "num_hidden_layers": 40, "vocab_size": 248320,
            "linear_num_key_heads": 16, "linear_num_value_heads": 32,
            "linear_key_head_dim": 128, "linear_value_head_dim": 128,
            "num_attention_heads": 16, "num_key_value_heads": 2, "head_dim": 256,
            "num_experts": 256, "num_experts_per_tok": 8,
            "moe_intermediate_size": 512, "shared_expert_intermediate_size": 512,
            "max_position_embeddings": 262144, "eos_token_id": 248046}}
        header = json.dumps({"model.language_model.layers.0.mlp.switch_mlp.gate_proj.weight":
                             {"dtype": "U8", "shape": [weights], "data_offsets": [0, weights]}}).encode()
        return {"config.json": json.dumps(config).encode(),
                "model.safetensors": len(header).to_bytes(8, "little") + header}

    def capacity(self, model, **options):
        return self.run_request({"protocol": 1, "action": "capacity", "budget_bytes": 16 * 10**9,
                                 "configuration": {"protocol": 1, "model": model, **options}})

    def test_capacity_distinguishes_oversized_models_and_context(self):
        folder = self.home / "header-only"
        folder.mkdir()
        for weights, oversized in [(90 * 10**9, True), (100 * 10**6, False)]:
            for name, data in self.planning_files(weights).items():
                (folder / name).write_bytes(data)
            process, messages = self.capacity(str(folder), context=32768, slots=2,
                                              prefill_chunk=512, dflash="none")
            self.assertEqual(process.returncode, 0, process.stderr)
            plan = messages[-1]["capacity"]
            self.assertEqual(messages[-1]["type"], "capacity")
            self.assertEqual(plan["status"], "known")
            self.assertEqual(plan["startup_bytes"] > plan["budget_bytes"], oversized)
            self.assertEqual(plan["context"], 32768)
            self.assertEqual(plan["slots"], 2)
        _, longer = self.capacity(str(folder), context=131072, slots=4,
                                   prefill_chunk=512, dflash="none")
        self.assertGreater(longer[-1]["capacity"]["startup_bytes"], plan["startup_bytes"])
        self.assertGreater(longer[-1]["capacity"]["conversation_bytes"], plan["conversation_bytes"])
        _, capped = self.capacity(str(folder), context=1048576, slots=1, dflash="none")
        self.assertEqual(capped[-1]["capacity"]["context"], 262144)
        self.assertFalse(self.requests, "Local header plans must be offline")
        self.assertLess(sum(p.stat().st_size for p in folder.iterdir()), 2000)

    def test_capacity_fetches_only_catalog_headers_and_caches_them(self):
        _, messages = self.run_request({"protocol": 1, "action": "list"})
        model = next(m for m in messages[0]["catalog"] if m["id"] == "qwen3.6-35b-a3b")
        variant = next(v for v in model["variants"] if v["name"] == "4bit")
        self.catalog_files = self.planning_files(90 * 10**9)
        process, messages = self.capacity(variant["id"], context=32768, slots=2, dflash="none")
        self.assertEqual(process.returncode, 0, process.stderr)
        plan = messages[-1]["capacity"]
        self.assertEqual(plan["status"], "known", messages)
        self.assertGreater(plan["startup_bytes"], plan["budget_bytes"])
        weights = [value for path, value in self.ranges if path.endswith(".safetensors")]
        self.assertTrue(weights)
        self.assertTrue(all(value and value.startswith("bytes=") for value in weights))
        self.assertFalse(list((self.home / "models").glob("*")))
        before = len(self.requests)
        process, _ = self.capacity(variant["id"], context=32768, slots=2, dflash="none")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(len(self.requests), before)

    def test_capacity_missing_headers_is_unknown_and_invalid_options_are_rejected(self):
        folder = self.home / "no-headers"
        folder.mkdir()
        (folder / "config.json").write_bytes(self.planning_files(1)["config.json"])
        process, messages = self.capacity(str(folder), context=32768, slots=2, dflash="none")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(messages[-1]["capacity"]["status"], "unknown")
        self.assertNotIn("startup_bytes", messages[-1]["capacity"])
        for change in [{"budget_bytes": True}, {"budget_bytes": 0}, {"budget_bytes": -1},
                       {"budget_bytes": 1.5}, {"budget_bytes": 10**30},
                       {"configuration": {"model": str(folder), "slots": 12}},
                       {"configuration": {"model": str(folder), "context": "90k"}}]:
            request = {"protocol": 1, "action": "capacity", "budget_bytes": 16 * 10**9,
                       "configuration": {"model": str(folder)}, **change}
            process, messages = self.run_request(request)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(messages[-1]["type"], "error")

    def test_catalog_and_local_models_are_offline(self):
        local = self.home / "models" / "local"
        local.mkdir(parents=True)
        (local / "config.json").write_text("{}")
        process, messages = self.run_request({"protocol": 1, "action": "list"})
        self.assertEqual(process.returncode, 0, process.stderr)
        reply = messages[0]
        self.assertEqual(reply["type"], "library")
        self.assertTrue(reply["catalog"])
        self.assertFalse(self.requests)
        self.assertEqual(reply["installed"][0]["dir"], str(local))
        self.assertFalse(reply["installed"][0]["managed"])
        self.assertTrue(all(v["id"].endswith(":" + v["name"])
                            for m in reply["catalog"] for v in m["variants"]))

    def test_real_download_emits_progress_and_reuses_offline(self):
        request = {"protocol": 1, "action": "download", "model": "fixture/tiny"}
        process, messages = self.run_request(request)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(messages[0]["type"], "preparing")
        self.assertEqual(messages[-1]["type"], "complete")
        progress = [m for m in messages if m["type"] == "progress"]
        self.assertTrue(progress)
        self.assertEqual(progress[-1]["done"], progress[-1]["total"])
        folder = Path(messages[-1]["dir"])
        for name, data in self.files.items():
            self.assertEqual((folder / name).read_bytes(), data)
        before = len(self.requests)
        process, messages = self.run_request(request)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(messages[-1]["type"], "complete")
        self.assertEqual(len(self.requests), before)
        _, library = self.run_request({"protocol": 1, "action": "list"})
        self.assertTrue(library[0]["installed"][0]["complete"])
        self.assertTrue(library[0]["installed"][0]["managed"])

    def test_interrupt_keeps_parts_and_resume_finishes(self):
        self.slow = True
        process = subprocess.Popen([str(BUILD / "kapitsa-runtime"), "--model-request"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=self.env)
        try:
            process.stdin.write(json.dumps({"protocol": 1, "action": "download", "model": "fixture/tiny"}))
            process.stdin.close()
            self.assertEqual(json.loads(process.stdout.readline())["type"], "preparing")
            # The first progress callback means the downloader installed its
            # signal handler and is fetching ranges, not resolving metadata.
            progress = json.loads(process.stdout.readline())
            self.assertEqual(progress["type"], "progress")
            self.assertLess(progress["done"], progress["total"])
            process.send_signal(signal.SIGINT)
            process.wait(timeout=8)
            remaining = [json.loads(line) for line in process.stdout]
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(remaining[-1]["type"], "error")
            self.assertTrue(list((self.home / "models").rglob("*.part")))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            process.stderr.close()
        self.slow = False
        process, messages = self.run_request({"protocol": 1, "action": "download", "model": "fixture/tiny"})
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(messages[-1]["type"], "complete")
        self.assertEqual((Path(messages[-1]["dir"]) / "model.safetensors").read_bytes(),
                         self.files["model.safetensors"])

    def test_invalid_requests_return_structured_errors(self):
        for request in [{"protocol": 2, "action": "list"}, {"protocol": True, "action": "list"},
                        {"protocol": 1, "action": "delete"}, {"protocol": 1, "action": "list", "shell": "x"},
                        {"protocol": 1, "action": "download", "model": str(self.home)},
                        {"protocol": 1, "action": "download", "model": ""}]:
            process, messages = self.run_request(request)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(messages[-1]["type"], "error")
            self.assertTrue(messages[-1]["message"])


if __name__ == "__main__":
    unittest.main()
