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
