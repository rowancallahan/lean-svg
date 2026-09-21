#!/usr/bin/env python3
"""Local web playground for lean-svg.

Serves a single-page UI that renders an SVG three ways (browser, resvg,
lean-svg) and diffs the two rasterizers.

Run:  python3 playground/server.py [--port 8765]
Then open http://127.0.0.1:8765

Also serves drop.html (playground/drop.html): a drag-and-drop page backed by
POST /api/render, a second, stricter endpoint that renders one file at a time
and optionally compares it against resvg.

Safety notes:
  * Binds to 127.0.0.1 only.
  * The submitted SVG is only ever written to a temp file and handed to the
    two renderer subprocesses as a file path. Nothing inside it is executed,
    interpreted, or echoed back into a shell (no shell=True anywhere).
  * Request bodies are capped at 2 MB; subprocesses are capped at 30 s.
  * /api/render additionally caps the SVG at 8 MB, the width at 4096, and the
    subprocess timeout at 20 s; no path or filename supplied by the client is
    ever used to build a filesystem path (temp files use fixed names).
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
INDEX_HTML = os.path.join(HERE, "index.html")
DROP_HTML = os.path.join(HERE, "drop.html")
SVG_DIR = os.path.join(REPO, "tests", "svg")
OURS_BIN = os.path.join(REPO, ".lake", "build", "bin", "lean-svg")
FONTS_DIR = os.path.join(REPO, "tests", "corpora", "resvg-test-suite", "fonts")

MAX_BODY = 2 * 1024 * 1024  # 2 MB
TIMEOUT = 30  # seconds per renderer

# /api/render (playground/drop.html) limits — kept separate from the
# /render limits above so tightening one never accidentally loosens the
# other.
API_MAX_SVG = 8 * 1024 * 1024  # 8 MB, the SVG text itself
API_MAX_BODY = API_MAX_SVG + 64 * 1024  # + slack for JSON/multipart overhead
API_MAX_WIDTH = 4096
API_TIMEOUT = 20  # seconds per renderer

# tests/run_tests.py's compare() is reused for the exact/within-8 metrics on
# playground/drop.html when it (and numpy/PIL) are importable; otherwise the
# metrics are simply omitted.
try:
    sys.path.insert(0, os.path.join(REPO, "tests"))
    from run_tests import compare as _oracle_compare
except Exception:
    _oracle_compare = None


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
    tmpdir = tempfile.mkdtemp(prefix="lean-svg-playground-")
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
                "lean-svg binary not found at %s (run `lake build`)" % OURS_BIN,
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


def _run_api(cmd, out_path, timeout):
    """Run one renderer for /api/render.

    Returns a dict with png bytes (or None), a short error summary, the full
    stderr text, the exit code (None if the process never produced one),
    and elapsed milliseconds. Kept separate from `_run` above (used by the
    older /render endpoint) so the two endpoints' error shapes can evolve
    independently.
    """
    start = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        ms = (time.perf_counter() - start) * 1000.0
        return {"png": None, "error": "timed out after %d s" % timeout, "stderr": "", "exit_code": None, "ms": ms}
    except FileNotFoundError:
        ms = (time.perf_counter() - start) * 1000.0
        return {"png": None, "error": "not found on PATH: %s" % cmd[0], "stderr": "", "exit_code": None, "ms": ms}
    except OSError as exc:
        ms = (time.perf_counter() - start) * 1000.0
        return {"png": None, "error": "failed to launch: %s" % exc, "stderr": "", "exit_code": None, "ms": ms}
    ms = (time.perf_counter() - start) * 1000.0

    stderr = (proc.stderr or b"").decode("utf-8", "replace")
    if proc.returncode != 0 or not os.path.exists(out_path):
        err = stderr.strip()
        if not err:
            err = (proc.stdout or b"").decode("utf-8", "replace").strip()
        if not err:
            err = "exited with status %d" % proc.returncode
        if not os.path.exists(out_path) and proc.returncode == 0:
            err = err or "renderer produced no output file"
        return {"png": None, "error": err, "stderr": stderr, "exit_code": proc.returncode, "ms": ms}

    with open(out_path, "rb") as fh:
        png = fh.read()
    return {"png": png, "error": None, "stderr": stderr or None, "exit_code": proc.returncode, "ms": ms}


def _api_result_json(result):
    return {
        "png": base64.b64encode(result["png"]).decode("ascii") if result["png"] else None,
        "error": result["error"],
        "stderr": result["stderr"],
        "exit_code": result["exit_code"],
        "ms": round(result["ms"], 2),
    }


def _compare_pngs(ours_png, ref_png, tol=8, gain=8):
    """exact / within-8 percentages plus an x8-gain red diff PNG, via Pillow.

    Returns (metrics_dict_or_None, diff_png_bytes_or_None).
    """
    try:
        import io

        import numpy as np
        from PIL import Image
    except ImportError:
        return None, None

    try:
        a = np.asarray(Image.open(io.BytesIO(ours_png)).convert("RGBA"), dtype=np.int16)
        b = np.asarray(Image.open(io.BytesIO(ref_png)).convert("RGBA"), dtype=np.int16)
    except Exception:
        return None, None

    same_size = bool(a.shape == b.shape)
    h = min(a.shape[0], b.shape[0])
    w = min(a.shape[1], b.shape[1])
    if h == 0 or w == 0:
        return {"exact": 0.0, "within8": 0.0, "same_size": same_size}, None
    ours_c = a[:h, :w, :]
    ref_c = b[:h, :w, :]

    if _oracle_compare is not None:
        raw, d = _oracle_compare(ref_c, ours_c, tol)
        metrics = {"exact": raw["exact"], "within8": raw["within"]}
    else:
        delta = np.abs(ours_c.astype(np.int32) - ref_c.astype(np.int32))
        d = delta.max(axis=2)
        total = float(d.size)
        metrics = {
            "exact": float((d == 0).sum()) / total,
            "within8": float((d <= tol).sum()) / total,
        }
    metrics["same_size"] = same_size

    v = np.clip(d.astype(np.int32) * gain, 0, 255).astype(np.uint8)
    panel = np.full(d.shape + (3,), 255, dtype=np.uint8)
    panel[:, :, 1] = 255 - v
    panel[:, :, 2] = 255 - v
    buf = io.BytesIO()
    Image.fromarray(panel, "RGB").save(buf, format="PNG")
    return metrics, buf.getvalue()


def _parse_multipart(body, content_type):
    """Minimal multipart/form-data reader: {field name -> bytes value}.

    Supports plain `curl -F name=value` and `curl -F name=@file` fields.
    Returns None if `content_type` carries no boundary.
    """
    m = re.search(r'boundary="?([^";]+)"?', content_type or "")
    if not m:
        return None
    boundary = ("--" + m.group(1)).encode("utf-8")
    fields = {}
    for chunk in body.split(boundary):
        chunk = chunk.strip(b"\r\n")
        if not chunk or chunk == b"--":
            continue
        header_blob, sep, value = chunk.partition(b"\r\n\r\n")
        if not sep:
            continue
        name_m = re.search(r'name="([^"]*)"', header_blob.decode("utf-8", "replace"))
        if not name_m:
            continue
        fields[name_m.group(1)] = value.rstrip(b"\r\n")
    return fields


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
    server_version = "lean-svg-playground"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s %s\n" % (self.command or "-", fmt % args))

    def _send(self, code, body, ctype, extra_headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
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
        elif path == "/drop.html":
            try:
                with open(DROP_HTML, "rb") as fh:
                    self._send(200, fh.read(), "text/html; charset=utf-8")
            except OSError:
                self._send(500, "drop.html not found", "text/plain; charset=utf-8")
        elif path == "/examples":
            self._json(200, list_examples())
        elif path == "/healthz":
            self._json(200, {"ok": True})
        else:
            self._send(404, "not found", "text/plain; charset=utf-8")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/render":
            self._handle_render()
        elif path == "/api/render":
            self._handle_api_render()
        else:
            self._send(404, "not found", "text/plain; charset=utf-8")

    def _handle_render(self):
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

    def _handle_api_render(self):
        """POST /api/render — one file at a time, for playground/drop.html.

        Body is either a JSON object `{svg, width?, background?, compare?}`
        or a `multipart/form-data` form with the same field names (so a
        plain `curl -F svg=@file.svg -F width=300 ...` works too).

        On success with `compare` unset/false: 200, `Content-Type:
        image/png`, the raw PNG bytes, with `X-Render-Ms` / `X-Exit-Code`
        headers. On a renderer failure: 422 JSON `{error, stderr,
        exit_code}`. On a bad request: 400; oversized body: 413.

        With `compare` true: 200 JSON `{ours, resvg, diff, metrics}` where
        `ours`/`resvg` are `{png, error, stderr, exit_code, ms}` (png is
        base64 or null) and `diff`/`metrics` (base64 PNG / {exact, within8})
        are present only when both renders produced decodable PNGs.
        """
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0:
            self._json(400, {"error": "bad Content-Length"})
            return
        if length > API_MAX_BODY:
            # The body is never read, so drop the connection rather than let
            # its leftover bytes be parsed as the next keep-alive request.
            self.close_connection = True
            self._json(413, {
                "error": "request body too large (limit %d MB)" % (API_MAX_BODY // (1024 * 1024))
            })
            return

        raw = self.rfile.read(length) if length else b""
        content_type = self.headers.get("Content-Type", "")

        if content_type.startswith("multipart/form-data"):
            fields = _parse_multipart(raw, content_type)
            if fields is None:
                self._json(400, {"error": "malformed multipart/form-data body"})
                return
            svg_bytes = fields.get("svg") if "svg" in fields else fields.get("file")
            svg = svg_bytes.decode("utf-8", "replace") if svg_bytes is not None else None
            width_raw = fields.get("width")
            width_raw = width_raw.decode("utf-8", "replace") if width_raw is not None else None
            background_raw = fields.get("background")
            background_raw = (
                background_raw.decode("utf-8", "replace") if background_raw is not None else None
            )
            compare_raw = fields.get("compare")
            compare = compare_raw is not None and compare_raw.decode("utf-8", "replace").strip().lower() in (
                "1", "true", "on", "yes",
            )
        elif content_type.startswith("application/json") or not content_type:
            try:
                payload = json.loads(raw.decode("utf-8")) if raw else {}
            except (ValueError, UnicodeDecodeError) as exc:
                self._json(400, {"error": "invalid JSON: %s" % exc})
                return
            if not isinstance(payload, dict):
                self._json(400, {"error": "expected a JSON object"})
                return
            svg = payload.get("svg")
            width_raw = payload.get("width")
            background_raw = payload.get("background")
            compare = bool(payload.get("compare"))
        else:
            self._json(400, {"error": "unsupported Content-Type: %s" % content_type})
            return

        if not isinstance(svg, str) or not svg.strip():
            self._json(400, {"error": "missing 'svg' string"})
            return
        if len(svg.encode("utf-8")) > API_MAX_SVG:
            self._json(413, {"error": "'svg' exceeds %d MB limit" % (API_MAX_SVG // (1024 * 1024))})
            return

        width = None
        if width_raw not in (None, "", 0, "0"):
            try:
                width = int(width_raw)
            except (TypeError, ValueError):
                self._json(400, {"error": "'width' must be an integer"})
                return
            if not (1 <= width <= API_MAX_WIDTH):
                self._json(400, {"error": "'width' must be between 1 and %d" % API_MAX_WIDTH})
                return

        background = None
        if background_raw not in (None, ""):
            if not isinstance(background_raw, str) or len(background_raw) > 64:
                self._json(400, {"error": "'background' must be a short color string"})
                return
            background = background_raw

        tmpdir = tempfile.mkdtemp(prefix="lean-svg-drop-")
        try:
            # Fixed filenames under our own tmpdir: nothing from the client
            # ever reaches the filesystem as a path or filename.
            in_path = os.path.join(tmpdir, "input.svg")
            with open(in_path, "w", encoding="utf-8") as fh:
                fh.write(svg)

            ours_out = os.path.join(tmpdir, "ours.png")
            ours_cmd = [OURS_BIN, in_path]
            if width:
                ours_cmd += ["--width", str(width)]
            if background:
                ours_cmd += ["--background", background]
            ours_cmd.append(ours_out)

            if not os.path.exists(OURS_BIN):
                ours = {
                    "png": None,
                    "error": "lean-svg binary not found at %s (run `lake build`)" % OURS_BIN,
                    "stderr": "",
                    "exit_code": None,
                    "ms": 0.0,
                }
            else:
                ours = _run_api(ours_cmd, ours_out, API_TIMEOUT)

            if not compare:
                if ours["png"] is None:
                    self._json(422, {
                        "error": ours["error"],
                        "stderr": ours["stderr"],
                        "exit_code": ours["exit_code"],
                    })
                else:
                    self._send(200, ours["png"], "image/png", extra_headers={
                        "X-Render-Ms": "%.2f" % ours["ms"],
                        "X-Exit-Code": str(ours["exit_code"]),
                    })
                return

            ref_out = os.path.join(tmpdir, "ref.png")
            ref_cmd = [shutil.which("resvg") or "resvg", in_path]
            if width:
                ref_cmd += ["-w", str(width)]
            if background:
                ref_cmd += ["--background", background]
            if os.path.isdir(FONTS_DIR):
                ref_cmd += ["--skip-system-fonts", "--use-fonts-dir", FONTS_DIR]
            ref_cmd.append(ref_out)
            ref = _run_api(ref_cmd, ref_out, API_TIMEOUT)

            metrics, diff_png = (None, None)
            if ours["png"] and ref["png"]:
                metrics, diff_png = _compare_pngs(ours["png"], ref["png"])

            self._json(200, {
                "ours": _api_result_json(ours),
                "resvg": _api_result_json(ref),
                "diff": base64.b64encode(diff_png).decode("ascii") if diff_png else None,
                "metrics": metrics,
            })
        except Exception as exc:  # never take the server down on one bad render
            self._json(500, {"error": "render failed: %s" % exc})
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description="lean-svg playground server")
    ap.add_argument("--port", type=int, default=8765, help="port (default 8765)")
    args = ap.parse_args()

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True
    url = "http://127.0.0.1:%d" % args.port
    print("lean-svg playground -> %s" % url)
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
