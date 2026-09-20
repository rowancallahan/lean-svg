# microsvg playground

A local, no-dependency web UI for comparing **microsvg** against **resvg** on any SVG
you type or draw.

## Run

```sh
python3 playground/server.py          # or: --port 9000
```

Then open <http://127.0.0.1:8765>.

The server binds to `127.0.0.1` only and uses the Python standard library (numpy and
Pillow are used for the diff metrics if they are importable; without them, the images
still render and only the metrics are omitted).

## Prerequisites

- `.lake/build/bin/microsvg` — build it with `lake build` if it is missing.
- `resvg` on `PATH` — the reference renderer.

## What you see

Four tiles: the **browser's** own rendering of the SVG source, **resvg (reference)**,
**microsvg (ours)**, and a **diff** (white where the two rasterizers agree, red where
they do not, computed in the page from the two PNGs). Underneath: the fraction of
pixels that match exactly, within 8, and within 32 (max channel difference over RGBA),
the mean absolute difference, and how long each renderer took. Any stderr from either
renderer appears in a red box.

Images are shown at 2x with `image-rendering: pixelated` so anti-aliasing seams are
visible, capped at the tile width.

- Pick a file from the **Examples** dropdown (everything in `tests/svg/`).
- Edit the source and press **Render**, or Ctrl/Cmd+Enter.
- Use the **Draw** panel (polygon, freehand, circle, rect) to append shapes to the
  source; each finished shape triggers a render. "Clear drawing" resets the source to
  a blank 200x200 SVG.

## Endpoints

| Method | Path        | Description |
| ------ | ----------- | ----------- |
| GET    | `/`         | the UI |
| GET    | `/examples` | `[{name, source}]` for every `tests/svg/*.svg` |
| POST   | `/render`   | `{"svg": "...", "width": 256}` → base64 PNGs, per-renderer errors and timings, and the metrics |

The submitted SVG is written to a temp directory and passed to the two renderers as a
file path; nothing in it is ever executed or interpolated into a shell, the temp
directory is always removed, request bodies are capped at 2 MB, and each renderer is
given 30 seconds. In the browser tile the SVG is loaded as an `<img>` data URL, so
scripts inside it cannot run in the page.
