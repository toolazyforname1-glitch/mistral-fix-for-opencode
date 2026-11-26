import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".capture", "exchanges")


def walk(name):
    d = os.path.join(ROOT, name)
    req = json.load(open(os.path.join(d, "request.json"), encoding="utf-8"))
    meta = json.load(open(os.path.join(d, "meta.json"), encoding="utf-8")) if os.path.exists(os.path.join(d, "meta.json")) else {}
    body = req.get("body")
    print("=" * 100)
    print(name, "|", req["method"], req["path"], "| status", meta.get("status"), "|", meta.get("seconds"), "s")
    print("headers:", ", ".join(sorted(req["headers"].keys())))
    print("content-type:", req["headers"].get("content-type"))
    print("user-agent:", req["headers"].get("user-agent"))
    if not isinstance(body, dict):
        print("body:", type(body).__name__, len(str(body)))
        return
    print("body keys:", sorted(body.keys()))
    for k, v in body.items():
        if k == "messages":
            print("messages:", len(v))
            for m in v:
                c = m.get("content")
                if isinstance(c, list):
                    desc = []
                    for b in c:
                        t = b.get("type")
                        if t == "text":
                            desc.append("text:%d" % len(b.get("text", "")))
                        else:
                            desc.append("%s:%s" % (t, b.get("image_url", {}).get("url", "")[:30] if isinstance(b.get("image_url"), dict) else ""))
                    c = "+".join(desc)
                else:
                    c = "str:%d" % len(c or "")
                extra = {kk: vv for kk, vv in m.items() if kk not in ("role", "content")}
                print("  -", m.get("role"), c, extra if extra else "")
        elif k == "tools":
            print("tools:", len(v))
            for t in v:
                fn = t.get("function", {})
                print("   *", fn.get("name"), "|", (fn.get("description") or "")[:70].replace("\n", " "))
        elif k in ("messages",):
            pass
        elif isinstance(v, (str, int, float, bool)) or v is None:
            print("  %s = %r" % (k, v))
        elif isinstance(v, list):
            print("  %s: list[%d] %r" % (k, len(v), v[:3]))
        else:
            s = json.dumps(v, ensure_ascii=False)
            print("  %s: %s" % (k, s if len(s) < 400 else s[:400] + "..."))


if __name__ == "__main__":
    names = sys.argv[1:] or sorted(os.listdir(ROOT))
    for n in names:
        walk(n)
