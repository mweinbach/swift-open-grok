#!/usr/bin/env python3
"""Mock LSP that pushes publishDiagnostics on didOpen/didChange."""
import json
import sys

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

def publish(uri, version, message="pushed diagnostic"):
    write_message({
        "jsonrpc": "2.0",
        "method": "textDocument/publishDiagnostics",
        "params": {
            "uri": uri,
            "version": version,
            "diagnostics": [{
                "range": {
                    "start": {"line": 0, "character": 0},
                    "end": {"line": 0, "character": 1},
                },
                "severity": 1,
                "source": "mock-push-lsp",
                "message": message,
            }],
        },
    })

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
                    "textDocumentSync": 1,
                    "diagnosticProvider": {
                        "interFileDependencies": False,
                        "workspaceDiagnostics": False,
                    },
                },
            },
        })
        # Server notification without id must not crash the client.
        write_message({
            "jsonrpc": "2.0",
            "method": "window/logMessage",
            "params": {"type": 3, "message": "mock push server ready"},
        })
    elif method == "initialized":
        continue
    elif method == "textDocument/didOpen":
        doc = msg.get("params", {}).get("textDocument", {})
        publish(doc.get("uri"), doc.get("version", 1), "pushed diagnostic")
    elif method == "textDocument/didChange":
        params = msg.get("params", {})
        doc = params.get("textDocument", {})
        publish(doc.get("uri"), doc.get("version", 1), "pushed diagnostic after change")
    elif method == "textDocument/diagnostic":
        write_message({
            "jsonrpc": "2.0",
            "id": msg_id,
            "error": {"code": -32601, "message": "Method not found"},
        })
    elif msg_id is not None:
        write_message({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": None,
        })
