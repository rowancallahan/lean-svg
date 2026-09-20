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
they do not, computed in the page from the two PNGs). Underneath: a timing strip
(`microsvg N ms · resvg M ms · size W×H`), the last ten renders as plain text, and the
fraction of pixels that match exactly, within 8, and within 32 (max channel difference
over RGBA), the mean absolute difference, and how long each renderer took. Any stderr
from either renderer appears in a red box.

## Render at the displayed size

The four tiles sit in a dashed box you can **resize by dragging its bottom-right
corner**; it also follows the window. A `ResizeObserver` watches the microsvg tile,
and 150 ms after the size settles the page POSTs `/render` again with `width` set to
that tile's pixel width (32-2048 px), so both rasterizers are re-run at exactly the
size you are looking at. The current width is shown next to the buttons, and the
microsvg caption carries `W×H · N ms` for the render on screen. **Reset size** drops
back to the full column width.

Images are displayed 1:1. **Zoom 2×** doubles them with `image-rendering: pixelated`
so anti-aliasing seams are visible; it only changes the display, not the render (the
browser tile is vector, so it is re-rasterized crisply at 2x rather than pixel-doubled).

## Picking, editing, drawing

- The **Examples** strip at the top shows a browser-rendered thumbnail of every file in
  `tests/svg/`; click one to load it, or use **←** / **→** to step through them (arrow
  keys are ignored while a text field has focus). The dropdown underneath does the same
  thing and is kept in sync.
- Edit the source and press **Render**, or Ctrl/Cmd+Enter.
- Use the **Draw** panel (polygon, freehand, circle, rect) to append shapes to the
  source; each finished shape triggers a render. "Clear drawing" resets the source to
  a blank 200x200 SVG.
- The draw canvas takes its pixel size from the current SVG's `width`/`height` (falling
  back to the `viewBox`, then to 200x200) and is only scaled for display, so a point
  clicked on it is written into the source unchanged. If the SVG's `viewBox` rescales
  the user space relative to `width`/`height`, the drawn coordinates are in the
  `width`/`height` space, not the viewBox's.

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
