# T13 — Playground: re-render on resize, draw, click through examples

## Goal

The playground (`playground/server.py`, `playground/index.html`) already
lets the user pick an example, edit the SVG source, draw shapes, and see
browser / resvg / microsvg / diff tiles with the match score. Make it a
live test bench for the renderer at arbitrary sizes:

1. **Render at the displayed size and re-render on resize.** Put the four
   tiles in a wrapper the user can resize (CSS `resize: both` with a visible
   corner grip, plus responding to window resizes). Observe the microsvg
   tile's pixel width with `ResizeObserver`, debounce ~150 ms, and POST
   `/render` with `width` equal to that pixel width (the server already
   accepts `width`; resvg is invoked with `-w`). Show the current render
   size and the microsvg render time in the caption. Images display 1:1
   (no 2× upscale) in this mode; keep the `image-rendering: pixelated` zoom
   as a toggle ("Zoom 2×").
2. **Click through the examples.** Turn the examples `<select>` into a
   horizontal thumbnail strip (browser-rendered `<img>` of each SVG,
   ~64 px, name underneath) that loads the source on click; keyboard
   left/right also moves between them. Keep the select as a fallback.
3. **Draw** stays as is (Polygon / Freehand / Circle / Rect appending to the
   source and re-rendering), but make the draw canvas the same aspect as the
   current SVG's `width`/`height` (parse them from the source; default
   200×200) so drawn coordinates map 1:1.
4. **Timing strip**: after each render show `microsvg N ms · resvg M ms ·
   size W×H` under the tiles, and keep the last 10 render times in a tiny
   sparkline-free text list (no chart libraries).

Constraints: vanilla JS/CSS only, single `index.html`, no CDN; server stays
stdlib-only; body limit and timeouts unchanged. Work in the main tree
`/Users/rowancallahan/pdf_renderer`, files `playground/index.html`,
`playground/server.py`, `playground/README.md` only. Do not touch Lean
sources, `tests/`, or `.worktrees/`.

## Verify

Start the server on port 8765, load the page in the built-in browser
(or curl `/render` with `width` 300, 700, 1200 and check the returned PNG
sizes), confirm that resizing triggers exactly one re-render after the
debounce (console log count), that the thumbnail strip lists all 20+
examples, and that drawing still appends and re-renders. Stop the server
when done. Append `## Report` with what changed and how you verified.
Commit on `main` is NOT allowed; leave the changes in the working tree.

## Report

### What changed

`playground/index.html` (rewritten in place, still one vanilla file, no CDN) and
`playground/README.md`. `playground/server.py` needed **no change**: it already
accepted `width` and passed `--width` / `-w`; the body limit and the 30 s renderer
timeout are untouched.

1. **Render at the displayed size.** The four tiles now live in
   `div.tilesWrap` (`resize: both; overflow: auto`, dashed border, a grip drawn in
   the bottom-right corner with a non-scrolling `background-image` on top of the
   native corner). A `ResizeObserver` on `#stageOurs` reports the microsvg tile's
   content width, clamped to 32-2048 px and ignored below a 2 px delta; 150 ms after
   the last change the page POSTs `/render` with that `width`. A `window.resize`
   listener feeds the same path (and is the fallback where `ResizeObserver` is
   missing), and a **Reset size** button clears the inline width/height the drag
   leaves behind. Images are sized 1:1 from a `data-base-w` attribute; **Zoom 2×**
   re-scales the same images to 2x with `image-rendering: pixelated` and switches the
   stages to `overflow: auto` without re-fetching. In 1:1 mode the stages are
   `overflow: hidden`, so an inner scrollbar can never feed back into the observed
   width. The microsvg caption reads `W×H · N ms`; the browser (vector) tile is
   displayed at the same width the rasterizers were asked for.
2. **Thumbnail strip.** `/examples` now also builds a horizontal strip of 64 px
   browser-rendered `<img>` thumbnails (inert `data:` URLs, same as the browser tile)
   with the name underneath; click loads the source and renders, ← / → step through
   with wrap-around (ignored while a text field has focus), and the `<select>` is kept
   as a synced fallback.
3. **Draw canvas.** `parseSvgSize()` reads the root `<svg>` `width`/`height`
   (percentages rejected, `viewBox` as fallback, 200x200 default) and
   `syncCanvasToSource()` sets the canvas buffer to exactly that, scaling only the CSS
   box to fit the column, so drawn coordinates go into the source unchanged.
4. **Timing strip.** `microsvg N ms · resvg M ms · size W×H` under the tiles plus the
   last 10 renders as an `<ol>` of plain text. Every issued request logs
   `[playground] render #N (reason) width=W` and bumps `window.__playground.renders`.

### How it was verified

Server on port 8765 (`python3 playground/server.py --port 8765`), page loaded in the
built-in browser; server stopped afterwards.

* `POST /render` by script at three widths on `12_badge.svg`: ours/ref PNG sizes
  `300x300 / 700x700 / 1200x1200`, microsvg 21.4 / 72.2 / 196.0 ms, resvg 6.0 / 10.8 /
  21.4 ms, exact 92.8% / 94.5% / 94.9%.
* **Resize → one re-render.** Driving `tilesWrap.style.width` through 12 steps 25 ms
  apart (a grip drag) moved `__playground.renders` 4 → 5: exactly one request, logged
  `render #5 (resize) width=411`, captions/timing `411×411 · 56 ms`. Clicking
  **Reset size** likewise gave exactly one: 18 → 19, `render #19 (resize) width=453`.
  Toggling Zoom 2× and back added zero renders (images 1146px = 2x573, then 573px).
* **Thumbnail strip.** 20 thumbnails (all of `tests/svg/`), selection highlight and the
  fallback `<select>` stay in sync; clicking `05_transform.svg` loaded it and rendered
  at 279 px; → then ← ← walked 05 → 06 → 04.
* **Draw.** In Rect mode a drag on the canvas (SVG 300x300) appended
  `<rect x="64" y="43" width="156" height="158" fill="#e63946"/>` — the 60 px drag
  mapped to 156/158 user units, i.e. 1:1 — and triggered exactly one render
  (`render #18 (draw) width=573`). Sampling the same pixel in all three tiles returned
  `rgb(230,57,70)`, so browser, resvg and microsvg all picked the new element up;
  within-32 stayed at 99.90%.
* Server log: 22 `POST /render`, no tracebacks.

### Caveats

* Drawn coordinates are in the `width`/`height` space; an SVG whose `viewBox` rescales
  the user space (e.g. `09_viewbox.svg`, 200x150 over a 0 0 100 100 box) will place a
  drawn shape at the scaled position. Noted in the README.
* The render width is clamped to 2048 px so a wild drag cannot start a huge render;
  the server's own 1-8192 range is unchanged.
* With both rows of tiles rendered 1:1 the wrapper usually needs scrolling (it is
  620 px tall by default) — that is what the resize handle is for.
* ← / → are captured on `document` (and `preventDefault`ed) whenever focus is not in a
  text field, so they step examples instead of scrolling the page horizontally.
* No Lean sources, `tests/`, `.worktrees/` or git state were touched; nothing committed.
