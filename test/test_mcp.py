#!/usr/bin/env python3
import socket
import json
import sys
import time

HOST = "127.0.0.1"
PORT = 8765

def get_lan_ip():
    import subprocess
    for iface in ("en0", "en1"):
        proc = subprocess.run(
            ["ipconfig", "getifaddr", iface],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        ip = proc.stdout.strip()
        if ip:
            return ip
    return None

def read_http_response(sock):
    resp = b""
    while b"\r\n\r\n" not in resp:
        c = sock.recv(8192)
        if not c:
            return resp
        resp += c

    head, _, body = resp.partition(b"\r\n\r\n")
    content_length = 0
    for line in head.decode("iso-8859-1", errors="replace").split("\r\n"):
        if line.lower().startswith("content-length:"):
            content_length = int(line.split(":", 1)[1].strip())
            break

    while len(body) < content_length:
        c = sock.recv(8192)
        if not c:
            break
        resp += c
        body += c
    return resp

def build_request(method, path, body, headers=None):
    headers = headers or {}
    req = f"{method} {path} HTTP/1.1\r\nHost: {HOST}\r\n"
    for name, value in headers.items():
        req += f"{name}: {value}\r\n"
    if body:
        req += f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
    req += "\r\n"
    if body:
        req += body
    return req.encode()

def send_raw_http(method, path, body, headers=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((HOST, PORT))
    try:
        s.sendall(build_request(method, path, body, headers))
    except BrokenPipeError:
        pass
    resp = read_http_response(s)
    s.close()
    return resp

def send_split_http(method, path, body, split_at, headers=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((HOST, PORT))
    req = build_request(method, path, body, headers)
    s.sendall(req[:split_at])
    time.sleep(0.1)
    s.sendall(req[split_at:])
    resp = read_http_response(s)
    s.close()
    return resp

def parse_http_response(resp):
    text = resp.decode("utf-8", errors="replace")
    head, _, body = text.partition("\r\n\r\n")
    status_line = head.splitlines()[0] if head else ""
    status_code = int(status_line.split()[1]) if status_line else 0
    return status_code, head, body

def assert_status(name, resp, expected):
    status_code, head, body = parse_http_response(resp)
    if status_code != expected:
        print(f"{name}: expected HTTP {expected}, got {status_code}", file=sys.stderr)
        print(head, file=sys.stderr)
        print(body[:600], file=sys.stderr)
        sys.exit(1)
    return status_code, head, body

def assert_json_method_response(name, resp):
    status_code, head, body = assert_status(name, resp, 200)
    payload = json.loads(body)
    if payload.get("jsonrpc") != "2.0" or "id" not in payload:
        print(f"{name}: invalid JSON-RPC response: {payload}", file=sys.stderr)
        sys.exit(1)
    return payload

def assert_tool_result(name, payload):
    result = payload.get("result")
    if not isinstance(result, dict):
        print(f"{name}: missing result object: {payload}", file=sys.stderr)
        sys.exit(1)
    content = result.get("content")
    if not isinstance(content, list) or not content:
        print(f"{name}: missing non-empty result.content: {payload}", file=sys.stderr)
        sys.exit(1)
    first = content[0]
    if first.get("type") != "text" or not isinstance(first.get("text"), str):
        print(f"{name}: first content block is not TextContent: {payload}", file=sys.stderr)
        sys.exit(1)
    if "structuredContent" not in result:
        print(f"{name}: missing result.structuredContent: {payload}", file=sys.stderr)
        sys.exit(1)

print("=== Test 0: LAN address is not reachable ===")
lan_ip = get_lan_ip()
if lan_ip:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect((lan_ip, PORT))
        print(f"LAN exposure: expected {lan_ip}:{PORT} to reject connections", file=sys.stderr)
        sys.exit(1)
    except OSError:
        print(f"LAN exposure check passed: {lan_ip}:{PORT} is not reachable")
    finally:
        s.close()
else:
    print("LAN exposure check skipped: no en0/en1 address found")

print("=== Test 1: initialize ===")
initialize_body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test_mcp","version":"1.0"}}}'
resp = send_raw_http("POST", "/mcp", initialize_body, {"Accept": "application/json, text/event-stream"})
print(f"Got {len(resp)} bytes")
print(resp.decode("utf-8", errors="replace")[:600])
payload = assert_json_method_response("initialize", resp)
if payload["result"].get("protocolVersion") != "2025-03-26":
    print(f"initialize: expected negotiated protocolVersion 2025-03-26, got {payload['result'].get('protocolVersion')}", file=sys.stderr)
    sys.exit(1)

print("\n=== Test 2: split initialize ===")
resp = send_split_http("POST", "/mcp", initialize_body, 64, {"Accept": "application/json, text/event-stream"})
print(f"Got {len(resp)} bytes")
print(resp.decode("utf-8", errors="replace")[:600])
assert_json_method_response("split initialize", resp)

print("\n=== Test 3: notifications/initialized ===")
resp = send_raw_http("POST", "/mcp", '{"jsonrpc":"2.0","method":"notifications/initialized"}', {"Accept": "application/json, text/event-stream"})
print(f"Got {len(resp)} bytes")
print(resp.decode("utf-8", errors="replace")[:600])
assert_status("notifications/initialized", resp, 202)

print("\n=== Test 4: tools/list ===")
resp = send_raw_http("POST", "/mcp", '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
print(f"Got {len(resp)} bytes")
print(resp.decode("utf-8", errors="replace")[:600])
assert_json_method_response("tools/list", resp)

print("\n=== Test 5: peek_ping ===")
resp = send_raw_http("POST", "/mcp", '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"peek_ping","arguments":{}}}')
print(f"Got {len(resp)} bytes")
print(resp.decode("utf-8", errors="replace")[:600])
payload = assert_json_method_response("peek_ping", resp)
assert_tool_result("peek_ping", payload)

print("\n=== Test 6: camera_status ===")
resp = send_raw_http("POST", "/mcp", '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"camera_status","arguments":{}}}')
print(f"Got {len(resp)} bytes")
print(resp.decode("utf-8", errors="replace")[:600])
payload = assert_json_method_response("camera_status", resp)
assert_tool_result("camera_status", payload)

print("\n=== Test 7: 404 ===")
resp = send_raw_http("POST", "/other", '{"jsonrpc":"2.0","id":5,"method":"initialize","params":{}}')
print(f"Got {len(resp)} bytes")
print(resp.decode("utf-8", errors="replace")[:300])
assert_status("404", resp, 404)

print("\n=== Test 8: oversized body rejected ===")
oversized = '{"jsonrpc":"2.0","id":8,"method":"initialize","params":"' + ("x" * (1024 * 1024 + 1)) + '"}'
resp = send_raw_http("POST", "/mcp", oversized)
status_code, head, body = parse_http_response(resp)
if status_code not in (400, 413):
    print(f"oversized body: expected HTTP 400 or 413, got {status_code}", file=sys.stderr)
    print(head, file=sys.stderr)
    sys.exit(1)
