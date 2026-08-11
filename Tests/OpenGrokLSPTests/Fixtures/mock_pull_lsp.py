#!/usr/bin/env python3
import json
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"

def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        text = line.decode("utf-8", "replace").strip()
        if ":" in text:
            key, value = text.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    body = sys.stdin.buffer.read(length)
    return json.loads(body.decode("utf-8"))

def write_message(payload):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8"))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()

while True:
    msg = read_message()
    if msg is None:
        break
    method = msg.get("method")
    msg_id = msg.get("id")
    if method == "initialize":
        write_message({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "capabilities": {
                    "diagnosticProvider": {
                        "interFileDependencies": True,
                        "workspaceDiagnostics": False,
                    }
                },
            },
        })
    elif method == "initialized":
        continue
    elif method == "textDocument/diagnostic":
        if MODE == "reject":
            write_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {"code": -32601, "message": "Method not found"},
            })
        else:
            write_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "kind": "full",
                    "resultId": "mock-1",
                    "items": [{
                        "range": {
                            "start": {"line": 0, "character": 0},
                            "end": {"line": 0, "character": 1},
                        },
                        "severity": 1,
                        "source": "mock-lsp",
                        "message": "mock diagnostic",
                    }],
                },
            })
    elif msg_id is not None:
        write_message({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": None,
        })
