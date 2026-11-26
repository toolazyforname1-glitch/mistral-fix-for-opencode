import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".capture", "exchanges")

for name in sys.argv[1:]:
    d = os.path.join(ROOT, name)
    req = json.load(open(os.path.join(d, "request.json"), encoding="utf-8"))
    meta = json.load(open(os.path.join(d, "meta.json"), encoding="utf-8"))
    body = req.get("body") or {}
    print(name, "status", meta.get("status"), "auth", req.get("auth"))
    print("  metadata:", json.dumps(body.get("metadata") if isinstance(body, dict) else None))
    print("  x-affinity:", req["headers"].get("x-affinity"))
    print("  x-session-affinity:", req["headers"].get("x-session-affinity"))
    rh = meta.get("response_headers") or {}
    print("  resp x-headers:", {k: v for k, v in rh.items() if k.lower().startswith("x") or "cache" in k.lower()})
    path = os.path.join(d, "response.txt")
    text = open(path, encoding="utf-8", errors="replace").read() if os.path.exists(path) else ""
    usage = re.findall(r'"usage":\{[^}]*\}', text)
    print("  usage:", usage[-1] if usage else "none")
