import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".capture")


def main(name):
    d = os.path.join(ROOT, "exchanges", name)
    body = json.load(open(os.path.join(d, "request.json"), encoding="utf-8"))["body"]
    out = os.path.join(ROOT, "assets", name)
    os.makedirs(out, exist_ok=True)
    msgs = body.get("messages", [])
    sysmsg = next((m for m in msgs if m.get("role") == "system"), None)
    if sysmsg:
        text = sysmsg["content"] if isinstance(sysmsg["content"], str) else json.dumps(sysmsg["content"], ensure_ascii=False)
        open(os.path.join(out, "system.txt"), "w", encoding="utf-8").write(text)
    tools = body.get("tools") or []
    json.dump(tools, open(os.path.join(out, "tools.json"), "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    rest = {k: v for k, v in body.items() if k not in ("messages", "tools")}
    json.dump(rest, open(os.path.join(out, "params.json"), "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    json.dump(msgs, open(os.path.join(out, "messages.json"), "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(name, "system", len(sysmsg["content"]) if sysmsg else 0, "tools", len(tools), "->", out)


if __name__ == "__main__":
    for n in sys.argv[1:]:
        main(n)
