#!/usr/bin/env python3
"""Check installed CLI protocol with synthetic tokens only; never request quotas."""
import base64
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time

cli = Path(sys.argv[1]).resolve(strict=True)
print(subprocess.check_output([str(cli), "--version"], text=True).strip())

def b64(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

token = b64({"alg": "none", "typ": "JWT"}) + "." + b64({
    "sub": "synthetic-quota-fixture", "exp": 4102444800,
    "https://api.openai.com/auth": {"chatgpt_account_id": "synthetic-workspace", "chatgpt_plan_type": "plus"},
}) + ".fixture"

with tempfile.TemporaryDirectory(prefix="still-quota-protocol-") as directory:
    os.chmod(directory, 0o700)
    env = dict(os.environ, CODEX_HOME=directory)
    for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "RUST_LOG"]:
        env.pop(key, None)
    process = subprocess.Popen([str(cli), "-c", 'cli_auth_credentials_store="ephemeral"', "-c", "analytics.enabled=false", "app-server"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd=directory)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = bytearray()

    def send(message):
        process.stdin.write(json.dumps(message).encode() + b"\n")
        process.stdin.flush()

    def response(request_id):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            while b"\n" in buffer:
                line, _, rest = buffer.partition(b"\n")
                buffer[:] = rest
                value = json.loads(line)
                if value.get("id") == request_id:
                    if "error" in value:
                        raise RuntimeError("Synthetic protocol request failed (response suppressed)")
                    return value["result"]
            if selector.select(0.1):
                chunk = os.read(process.stdout.fileno(), 8192)
                if not chunk:
                    raise RuntimeError("CLI ended before response")
                buffer.extend(chunk)
                if len(buffer) > 2_000_000:
                    raise RuntimeError("CLI response exceeded bound")
        raise RuntimeError("CLI protocol timed out")

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "still_quota_fixture", "version": "1.1.0"}, "capabilities": {"experimentalApi": True}}})
        response(1)
        print("PASS official CLI initialization with experimental capability")
        send({"method": "initialized"})
        send({"id": 2, "method": "account/login/start", "params": {"type": "chatgptAuthTokens", "accessToken": token, "chatgptAccountId": "synthetic-workspace", "chatgptPlanType": "plus"}})
        assert response(2)["type"] == "chatgptAuthTokens"
        print("PASS official CLI external token protocol accepted synthetic input")
    finally:
        selector.close()
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    assert not (Path(directory) / "auth.json").exists()
    print("PASS ephemeral mode persisted no auth.json")
    assert all(token.encode() not in p.read_bytes() for p in Path(directory).rglob("*") if p.is_file())
    print("PASS synthetic access token absent from child files")
print("RESULT 4 protocol checks passed; no real login, rate-limit request or model request")
