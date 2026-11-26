"""Replay controlled request variants against the real Mistral gateway.

Goal: isolate which part of Vibe's request makes the same API key succeed where
OpenCode's request gets 402 "API budget exhausted".
"""
from __future__ import annotations

import copy
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".capture")
EX = os.path.join(ROOT, "exchanges")
KEY = os.environ["MISTRAL_API_KEY"]
URL = "http://127.0.0.1:8899/v1/chat/completions"
VIBE_UA = "mistral-client-python/Mistral-Vibe/3.1.5"


def load(name):
    return json.load(open(os.path.join(EX, name, "request.json"), encoding="utf-8"))["body"]


def send(label, body, ua, affinity, stream=True):
    data = json.dumps(body).encode()
    headers = {
        "Authorization": "Bearer " + KEY,
        "Content-Type": "application/json",
        "Accept": "text/event-stream" if stream else "application/json",
        "Accept-Encoding": "identity",
        "User-Agent": ua,
    }
    if affinity:
        headers["x-affinity"] = affinity
    req = urllib.request.Request(URL, data=data, headers=headers, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=180)
        status = resp.status
        chunk = resp.read(400).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status = e.code
        chunk = e.read(300).decode("utf-8", "replace")
    except Exception as e:
        status = "ERR"
        chunk = str(e)
    print("%-46s %s  %s" % (label, status, chunk.replace("\n", " ")[:150]))
    return status


def main():
    vibe = load("r2-003--v1-chat-completions-deepseek-v4-1-flash-1017")
    oc = load("r2-005--v1-chat-completions-deepseek-v4-1-flash-1017")
    oc_ua = "opencode/latest/2.4.1/cli"
    aff = str(uuid.uuid4())

    print("control:")
    send("vibe-body / vibe-UA / vibe-affinity", copy.deepcopy(vibe), VIBE_UA, aff)
    send("oc-body / oc-UA / oc-affinity", copy.deepcopy(oc), oc_ua, "ses_probe")

    print("\nvibe body mutations:")
    v = copy.deepcopy(vibe)
    v.pop("metadata", None)
    send("vibe minus metadata", v, VIBE_UA, aff)
    v = copy.deepcopy(vibe)
    send("vibe body / oc-UA", v, oc_ua, aff)
    v = copy.deepcopy(vibe)
    v.pop("metadata", None)
    send("vibe -metadata / oc-UA", v, oc_ua, aff)

    print("\noc body + vibe fields:")
    o = copy.deepcopy(oc)
    o["metadata"] = copy.deepcopy(vibe["metadata"])
    send("oc + vibe metadata", o, oc_ua, "ses_probe")
    o = copy.deepcopy(oc)
    send("oc + vibe-UA", o, VIBE_UA, "ses_probe")
    o = copy.deepcopy(oc)
    o["metadata"] = copy.deepcopy(vibe["metadata"])
    send("oc + metadata + vibe-UA", o, VIBE_UA, "ses_probe")
    o = copy.deepcopy(oc)
    o["metadata"] = copy.deepcopy(vibe["metadata"])
    o["parallel_tool_calls"] = True
    o["reasoning_effort"] = "max"
    o["temperature"] = 1.0
    send("oc + metadata + vibe params", o, VIBE_UA, "ses_probe")
    o = copy.deepcopy(oc)
    for k in ("max_completion_tokens", "stream_options"):
        o.pop(k, None)
    send("oc -max_tokens -stream_options", o, oc_ua, "ses_probe")


if __name__ == "__main__":
    main()
