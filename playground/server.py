#!/usr/bin/env python3
"""Local web playground for microsvg.

Serves a single-page UI that renders an SVG three ways (browser, resvg,
microsvg) and diffs the two rasterizers.

Run:  python3 playground/server.py [--port 8765]
Then open http://127.0.0.1:8765

Safety notes:
  * Binds to 127.0.0.1 only.
  * The submitted SVG is only ever written to a temp file and handed to the
    two renderer subprocesses as a file path. Nothing inside it is executed,
    interpreted, or echoed back into a shell (no shell=True anywhere).
  * Request bodies are capped at 2 MB; subprocesses are capped at 30 s.
"""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
INDEX_HTML = os.path.join(HERE, "index.html")
SVG_DIR = os.path.join(REPO, "tests", "svg")
OURS_BIN = os.path.join(REPO, ".lake", "build", "bin", "microsvg")

MAX_BODY = 2 * 1024 * 1024  # 2 MB
TIMEOUT = 30  # seconds per renderer


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

def _run(cmd, cwd):
    """Run a renderer. Returns (png_bytes|None, error_str|None, elapsed_ms)."""
    out_path = cmd[-1]
    start = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        ms = (time.perf_counter() - start) * 1000.0
        return None, "timed out after %d s" % TIMEOUT, ms
    except FileNotFoundError:
        ms = (time.perf_counter() - start) * 1000.0
        return None, "not found on PATH: %s" % cmd[0], ms
    except OSError as exc:
        ms = (time.perf_counter() - start) * 1000.0
        return None, "failed to launch: %s" % exc, ms
    ms = (time.perf_counter() - start) * 1000.0

    err = (proc.stderr or b"").decode("utf-8", "replace").strip()
    if proc.returncode != 0:
        if not err:
            err = (proc.stdout or b"").decode("utf-8", "replace").strip()
        if not err:
            err = "exited with status %d" % proc.returncode
        return None, err, ms
    if not os.path.exists(out_path):
        return None, err or "renderer produced no output file", ms
    with open(out_path, "rb") as fh:
        return fh.read(), (err or None), ms


def _metrics(ours_png, ref_png):
    """Per-pixel agreement over RGBA, using the max channel diff per pixel."""
    try:
        import io

        import numpy as np
        from PIL import Image
    except ImportError:
        return None

    try:
        a = np.asarray(Image.open(io.BytesIO(ours_png)).convert("RGBA"), dtype=np.int16)
        b = np.asarray(Image.open(io.BytesIO(ref_png)).convert("RGBA"), dtype=np.int16)
    except Exception:
        return None

    same_size = bool(a.shape == b.shape)
    if not same_size:
        h = min(a.shape[0], b.shape[0])
        w = min(a.shape[1], b.shape[1])
        if h == 0 or w == 0:
            return {
                "exact": 0.0,
                "within8": 0.0,
                "within32": 0.0,
                "mean_abs": 0.0,
                "same_size": False,
            }
        a = a[:h, :w, :]
        b = b[:h, :w, :]

    diff = np.abs(a - b).max(axis=2)
    return {
        "exact": float((diff == 0).mean()),
        "within8": float((diff <= 8).mean()),
        "within32": float((diff <= 32).mean()),
        "mean_abs": float(diff.mean()),
        "same_size": same_size,
    }


def render_both(svg_text, width=None):
    tmpdir = tempfile.mkdtemp(prefix="microsvg-playground-")
    try:
        in_path = os.path.join(tmpdir, "input.svg")
        with open(in_path, "w", encoding="utf-8") as fh:
            fh.write(svg_text)

        ours_cmd = [OURS_BIN, in_path]
        ref_cmd = [shutil.which("resvg") or "resvg", in_path]
        if width:
            ours_cmd += ["--width", str(width)]
            ref_cmd += ["-w", str(width)]
        ours_cmd.append(os.path.join(tmpdir, "ours.png"))
        ref_cmd.append(os.path.join(tmpdir, "ref.png"))

        if not os.path.exists(OURS_BIN):
            ours_png, ours_err, ours_ms = (
                None,
                "microsvg binary not found at %s (run `lake build`)" % OURS_BIN,
                0.0,
            )
        else:
            ours_png, ours_err, ours_ms = _run(ours_cmd, tmpdir)
        ref_png, ref_err, ref_ms = _run(ref_cmd, tmpdir)

        metrics = _metrics(ours_png, ref_png) if (ours_png and ref_png) else None

        return {
            "ours": base64.b64encode(ours_png).decode("ascii") if ours_png else None,
            "ours_error": ours_err,
            "ours_ms": round(ours_ms, 2),
            "ref": base64.b64encode(ref_png).decode("ascii") if ref_png else None,
            "ref_error": ref_err,
            "ref_ms": round(ref_ms, 2),
            "metrics": metrics,
        }
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def list_examples():
    out = []
    try:
        names = sorted(n for n in os.listdir(SVG_DIR) if n.endswith(".svg"))
    except OSError:
        return out
    for name in names:
        try:
            with open(os.path.join(SVG_DIR, name), "r", encoding="utf-8") as fh:
                out.append({"name": name, "source": fh.read()})
        except OSError:
            continue
    return out


# --------------------------------------------------------------------------
# http
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "microsvg-playground"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s %s\n" % (self.command or "-", fmt % args))

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _json(self, code, payload):
        self._send(code, json.dumps(payload), "application/json; charset=utf-8")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            try:
                with open(INDEX_HTML, "rb") as fh:
                    self._send(200, fh.read(), "text/html; charset=utf-8")
            except OSError:
                self._send(500, "index.html not found", "text/plain; charset=utf-8")
        elif path == "/examples":
            self._json(200, list_examples())
        elif path == "/healthz":
            self._json(200, {"ok": True})
        else:
            self._send(404, "not found", "text/plain; charset=utf-8")

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/render":
            self._send(404, "not found", "text/plain; charset=utf-8")
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0:
            self._json(400, {"error": "bad Content-Length"})
            return
        if length > MAX_BODY:
            self._json(413, {"error": "request body too large (limit 2 MB)"})
            return

        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            self._json(400, {"error": "invalid JSON: %s" % exc})
            return
        if not isinstance(payload, dict):
            self._json(400, {"error": "expected a JSON object"})
            return

        svg = payload.get("svg")
        if not isinstance(svg, str) or not svg.strip():
            self._json(400, {"error": "missing 'svg' string"})
            return

        width = payload.get("width")
        if width in (None, "", 0):
            width = None
        else:
            try:
                width = int(width)
            except (TypeError, ValueError):
                self._json(400, {"error": "'width' must be an integer"})
                return
            if not (1 <= width <= 8192):
                self._json(400, {"error": "'width' must be between 1 and 8192"})
                return

        try:
            self._json(200, render_both(svg, width))
        except Exception as exc:  # never take the server down on one bad render
            self._json(500, {"error": "render failed: %s" % exc})


def main():
    ap = argparse.ArgumentParser(description="microsvg playground server")
    ap.add_argument("--port", type=int, default=8765, help="port (default 8765)")
    args = ap.parse_args()

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True
    url = "http://127.0.0.1:%d" % args.port
    print("microsvg playground -> %s" % url)
    print("  renderer: %s" % OURS_BIN)
    print("  reference: %s" % (shutil.which("resvg") or "resvg (NOT on PATH)"))
    print("  examples: %s" % SVG_DIR)
    print("  Ctrl-C to stop.")
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping.")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
