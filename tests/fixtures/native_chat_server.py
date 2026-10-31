#!/usr/bin/env python3
"""Engine-free HTTP fixture for the native chat tests and isolated UI previews."""

import argparse
import json
import os
from pathlib import Path
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        state = self.server.state
        if self.path.startswith("/v1/events"):
            if (self.headers.get("Authorization") != "Bearer fixture-control"
                    or self.headers.get("X-Kapitsa-Run-ID") != state["run_id"]):
                self.reply(401, {"error": {"message": "control auth"}})
                return
            self.reply(200, dict(state, state="ready", model=self.server.model, context=4096,
                                 slots=2, quant="Synthetic fixture", requests=[], cursor=0,
                                 events=[], reset=False))
        elif self.path == "/v1/models":
            if state["instance_id"] == "chat-protected" and not self.authorized():
                self.reply(401, {"error": {"message": "API key required"}})
                return
            self.reply(200, {"allow_switch": state["instance_id"] != "chat-beta", "timing": "both", "data": [
                {"id": self.server.model, "display_name": self.server.model, "active": True,
                 "downloaded": True, "context_fit": 4096},
                {"id": "fixture-other", "display_name": "Another model", "downloaded": True},
                {"id": "fixture-catalog", "display_name": "Catalog model", "downloaded": False}
            ]})
        elif self.path == "/capture":
            with self.server.lock:
                self.reply(200, self.server.capture)
        else:
            self.reply(404, {})

    def authorized(self):
        return self.headers.get("Authorization") == "Bearer fixture-key"

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.server.state["instance_id"] == "chat-protected" and not self.authorized():
            self.reply(401, {"error": {"message": "API key required"}})
            return
        if self.path == "/v1/models/switch":
            self.server.model = body["model"]
            self.reply(200, {"status": "ok", "model": self.server.model})
            return
        if self.path != "/v1/chat/completions":
            self.reply(404, {})
            return
        text = body["messages"][-1]["content"]
        if isinstance(text, list):
            text = next((item["text"] for item in text if item["type"] == "text"), "")
        with self.server.lock:
            self.server.capture["bodies"].append(body)
            self.server.capture["control_leaked"] |= self.headers.get("Authorization") == "Bearer fixture-control"
        if text == "unauthorized" and not self.authorized():
            self.reply(401, {"error": {"message": "API key required"}})
            return
        if text == "error":
            self.reply(500, {"error": {"message": "Synthetic failure"}})
            return
        if text == "redirect":
            self.send_response(307)
            self.send_header("Location", self.server.state["api_url"] + "/capture")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def event(value):
            data = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
            # Split UTF-8 and CRLF across writes, as a real socket may do.
            wire = (": keepalive\r\ndata: " + data + "\r\n\r\n").encode()
            for offset in range(0, len(wire), 7):
                self.wfile.write(wire[offset:offset + 7])
                self.wfile.flush()

        def delta(**value):
            event({"choices": [{"delta": value}]})

        try:
            if text == "waiting":
                time.sleep(0.3)
            delta(reasoning_content="Je vérifie les détails, café ☕.\n")
            time.sleep(0.08)
            answer = (
                "## Réponse native\n\nBonjour **Kapitsa** — café ☕.\n\n"
                "| Fonction | État |\n| --- | --- |\n| Streaming | Prêt |\n| Images | Prêtes |\n\n"
                "```swift\nlet message = \"Bonjour\"\nprint(message)\n```\n\n"
                "- Historique par instance\n- Images jointes\n\n> Une réponse de test, sans modèle.\n"
            )
            if text == "slow":
                for index in range(200):
                    delta(content=f"Étape {index + 1}. ")
                    time.sleep(0.04)
            else:
                for offset in range(0, len(answer), 20):
                    delta(content=answer[offset:offset + 20])
                    time.sleep(0.01)
            if text == "truncated":
                return
            if text == "stream-error":
                event({"error": {"message": "Synthetic stream failure"}})
                return
            event({"choices": [{"delta": {}, "finish_reason": "length" if text == "length" else "stop"}],
                   "usage": {"completion_tokens": 80, "prompt_tokens": 200,
                             "prompt_tokens_details": {"cached_tokens": 50},
                             "kapitsa": {"prefill_ms": 100}}})
            event("[DONE]")
        except (BrokenPipeError, ConnectionResetError):
            with self.server.lock:
                self.server.capture["disconnected"] += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True, type=Path)
    args = parser.parse_args()
    registry = args.home / "instances"
    registry.mkdir(mode=0o700, parents=True, exist_ok=True)
    servers = []
    for instance in ("alpha", "beta", "protected"):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        url = f"http://127.0.0.1:{server.server_port}"
        record = {"protocol": 1, "instance_id": "chat-" + instance, "run_id": "run-" + instance,
                  "name": "Chat " + instance, "pid": os.getpid(), "control_url": url,
                  "token": "fixture-control"}
        server.state = dict(record, api_url=url)
        server.model = "fixture-" + instance
        server.lock = threading.Lock()
        server.capture = {"bodies": [], "disconnected": 0, "control_leaked": False}
        destination = registry / (record["instance_id"] + ".json")
        destination.write_text(json.dumps(record))
        destination.chmod(0o600)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print(json.dumps([server.state for server in servers]), flush=True)
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    stopped.wait()
    for server in servers:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
