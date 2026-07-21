#!/usr/bin/env python3
"""Loopback-only OpenAI Responses SSE fixture for isolated runtime CI."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import time


CREATED = {
    "type": "response.created",
    "response": {
        "id": "resp_audit",
        "object": "response",
        "model": "gpt-5.4",
        "status": "in_progress",
        "output": [],
    },
}
DELTA = {"type": "response.output_text.delta", "delta": "audit-ok"}
COMPLETED = {
    "type": "response.completed",
    "response": {
        "id": "resp_audit",
        "object": "response",
        "model": "gpt-5.4",
        "status": "completed",
        "output": [
            {
                "type": "message",
                "id": "msg_audit",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": "audit-ok"}],
            }
        ],
        "usage": {"input_tokens": 11, "output_tokens": 5, "total_tokens": 16},
    },
}


def probe_response(model: str) -> dict[str, object]:
    return {
        "id": "resp_audit_probe",
        "object": "response",
        "model": model,
        "status": "completed",
        "output": [
            {
                "type": "function_call",
                "id": "fc_audit_probe",
                "call_id": "call_audit_probe",
                "name": "probe_ping",
                "arguments": '{"ok":true}',
                "status": "completed",
            }
        ],
        "usage": {"input_tokens": 11, "output_tokens": 5, "total_tokens": 16},
    }


class AuditServer(ThreadingHTTPServer):
    state_file: Path

    def record(self, event: str) -> None:
        with self.state_file.open("a", encoding="ascii") as state:
            state.write(event + "\n")


class Handler(BaseHTTPRequestHandler):
    server: AuditServer

    def log_message(self, format: str, *args: object) -> None:
        return

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            return
        self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/v1/responses":
            self.send_error(404)
            return
        self.server.record("request-received")
        if self.headers.get("Authorization") != "Bearer audit-only-upstream-key":
            self.server.record("auth-rejected")
            self.send_error(401)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self.server.record("json-rejected")
            self.send_error(400)
            return

        if body.get("stream") is False:
            self.server.record("probe-started")
            payload = json.dumps(
                probe_response(str(body.get("model", "gpt-5.4"))),
                separators=(",", ":"),
            ).encode("ascii")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("X-Request-Id", "mock-audit-probe-request")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            self.server.record("probe-completed")
            return

        slow = "AUDIT_SLOW_STREAM" in json.dumps(body, separators=(",", ":"))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Request-Id", "mock-audit-request")
        self.end_headers()

        try:
            self.write_event(CREATED)
            self.server.record("slow-started" if slow else "fast-started")
            if slow:
                time.sleep(30)
            self.write_event(DELTA)
            self.write_event(COMPLETED)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.server.record("slow-completed" if slow else "fast-completed")
        except (BrokenPipeError, ConnectionResetError):
            self.server.record("slow-interrupted" if slow else "fast-interrupted")

    def write_event(self, payload: dict[str, object]) -> None:
        event_type = str(payload["type"])
        frame = f"event: {event_type}\ndata: {json.dumps(payload, separators=(',', ':'))}\n\n"
        self.wfile.write(frame.encode("ascii"))
        self.wfile.flush()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=19090)
    parser.add_argument("--state-file", type=Path, required=True)
    args = parser.parse_args()
    args.state_file.write_text("", encoding="ascii")
    server = AuditServer(("127.0.0.1", args.port), Handler)
    server.state_file = args.state_file
    server.serve_forever()


if __name__ == "__main__":
    main()
