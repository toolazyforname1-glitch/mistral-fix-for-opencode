"""Plain-HTTP front for https://api.mistral.ai that records every exchange.

Vibe is pointed at http://127.0.0.1:8899/v1 so request bodies are visible.
Each exchange is written to .capture/exchanges/<seq>-<slug>/{request.json,response.txt,meta.json}
"""
from __future__ import annotations

import http.server
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

TARGET = os.environ.get("CAPTURE_TARGET", "https://api.mistral.ai")
PORT = int(os.environ.get("CAPTURE_PORT", "8899"))
ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".capture")
OUT = os.path.join(ROOT, "exchanges")
os.makedirs(OUT, exist_ok=True)
CTX = ssl.create_default_context()
SEQ = 0
REDACT = {"authorization", "proxy-authorization", "x-api-key", "cookie"}


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", text)[:80]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))
        sys.stderr.flush()

    def do_GET(self):
        self._serve("GET")

    def do_POST(self):
        self._serve("POST")

    def do_DELETE(self):
        self._serve("DELETE")

    def _serve(self, method: str):
        global SEQ
        SEQ += 1
        n = SEQ
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(body.decode("utf-8")) if body else None
        except Exception:
            payload = None
        model = (payload or {}).get("model") if isinstance(payload, dict) else None
        run = os.environ.get("CAPTURE_RUN") or time.strftime("%H%M%S")
        name = "%s-%03d-%s%s" % (run, n, slug(self.path.split("?")[0]), ("-" + slug(model)) if model else "")
        d = os.path.join(OUT, name)
        os.makedirs(d, exist_ok=True)
        auth = self.headers.get("authorization") or ""
        auth_meta = {"scheme": auth.split(" ")[0] if auth else None,
                     "token_len": len(auth.split(" ", 1)[1]) if " " in auth else 0}
        hdrs = {k: ("<redacted>" if k.lower() in REDACT else v) for k, v in self.headers.items()}
        with open(os.path.join(d, "request.json"), "w", encoding="utf-8") as f:
            json.dump({"method": method, "path": self.path, "headers": hdrs, "auth": auth_meta,
                       "body": payload, "raw_len": len(body)}, f, indent=2, ensure_ascii=False)

        fwd = {k: v for k, v in self.headers.items()
               if k.lower() not in ("host", "content-length", "accept-encoding", "connection")}
        req = urllib.request.Request(TARGET + self.path, data=body or None,
                                     headers=fwd, method=method)
        t0 = time.time()
        try:
            resp = urllib.request.urlopen(req, timeout=900, context=CTX)
            status = resp.status
        except urllib.error.HTTPError as e:
            resp = e
            status = e.code
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            msg = ("proxy error: %s" % e).encode()
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            with open(os.path.join(d, "meta.json"), "w", encoding="utf-8") as f:
                json.dump({"status": 502, "error": str(e)}, f)
            return

        self.send_response(status)
        for k, v in resp.headers.items():
            if k.lower() in ("transfer-encoding", "content-length", "connection"):
                continue
            self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        total = 0
        with open(os.path.join(d, "response.txt"), "wb") as f:
            while True:
                chunk = resp.read(4096)
                if not chunk:
                    break
                f.write(chunk)
                f.flush()
                total += len(chunk)
                self.wfile.write(b"%x\r\n" % len(chunk))
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        with open(os.path.join(d, "meta.json"), "w", encoding="utf-8") as f:
            json.dump({"status": status, "bytes": total, "seconds": round(time.time() - t0, 3),
                       "model": model, "path": self.path,
                       "response_headers": dict(resp.headers.items())}, f, indent=2)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print("capture proxy on http://127.0.0.1:%d -> %s" % (PORT, TARGET), flush=True)
    Server(("127.0.0.1", PORT), Handler).serve_forever()
