"""Narrow the metadata trigger field by field."""
from __future__ import annotations

import copy
import json
import os
import urllib.error
import urllib.request
import uuid

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".capture")
EX = os.path.join(ROOT, "exchanges")
KEY = os.environ["MISTRAL_API_KEY"]
URL = "http://127.0.0.1:8899/v1/chat/completions"
UA = "opencode/latest/2.4.1/cli"


def load(name):
    return json.load(open(os.path.join(EX, name, "request.json"), encoding="utf-8"))["body"]


def send(label, body):
    data = json.dumps(body).encode()
    headers = {
        "Authorization": "Bearer " + KEY,
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "Accept-Encoding": "identity",
        "User-Agent": UA,
        "x-affinity": str(uuid.uuid4()),
    }
    req = urllib.request.Request(URL, data=data, headers=headers, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=180)
        status, chunk = resp.status, resp.read(120).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status, chunk = e.code, e.read(160).decode("utf-8", "replace")
    except Exception as e:
        status, chunk = "ERR", str(e)
    print("%-42s %-4s %s" % (label, status, chunk.replace("\n", " ")[:90]))


def main():
    base = load("r2-005--v1-chat-completions-deepseek-v4-1-flash-1017")
    cases = [
        ("full vibe metadata", {"call_source": "vibe_code", "client_name": "vibe_programmatic", "agent_entrypoint": "programmatic", "agent_version": "3.1.5", "client_version": "3.1.5", "version": "3.1.5", "os": "windows", "arch": "amd64", "os_version": "10.0.26300", "terminal_emulator": "windows_terminal", "session_id": str(uuid.uuid4()), "call_type": "main_call", "host_kind": "local", "message_id": "user-turn-probe-1"}),
        ("only call_source", {"call_source": "vibe_code"}),
        ("only client_name", {"client_name": "vibe_programmatic"}),
        ("only agent_entrypoint", {"agent_entrypoint": "programmatic"}),
        ("call_source + client_name", {"call_source": "vibe_code", "client_name": "vibe_programmatic"}),
        ("call_source + entrypoint + client", {"call_source": "vibe_code", "agent_entrypoint": "programmatic", "client_name": "vibe_programmatic"}),
        ("call_source WRONG value", {"call_source": "opencode"}),
        ("client_name WRONG value", {"client_name": "opencode"}),
        ("empty metadata", {}),
    ]
    for label, meta in cases:
        body = copy.deepcopy(base)
        body["metadata"] = meta
        send(label, body)


if __name__ == "__main__":
    main()
