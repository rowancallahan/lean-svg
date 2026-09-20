# Feature roadmap from the external corpora (2026-09-20)

Source: `tests/out/corpora/summary.md` (T15). 1 679 resvg-test-suite files,
3 461 simple-icons, 287 feather icons; each on two routes: **direct** (our
parser) and **usvg** (usvg pre-processes to micro-SVG, then our renderer).
Pass = ≥ 99% of pixels within 8 levels of resvg.

| corpus | direct | usvg | what the gap is |
|---|---|---|---|
| resvg suite | 24% | 57% | features below; text/markers/CSS are usvg's job |
| simple-icons | 18% | 44% | arcs (direct) and curve flattening (both) |
| feather | 31% | 50% | arcs (direct) and circles/curves (both) |

Rasterizer, blending, strokes, transforms, basic shapes are solid:
`shapes/*`, `painting/stroke-*`, `structure/transform` are 90–100% on both
routes. What is missing is *features*, plus one numeric term.

## Features, ranked by files unlocked (and feasibility)

| # | feature | evidence | files it unlocks | task |
|---|---|---|---|---|
| F1 | **Elliptical arcs `A`/`a`** | simple-icons direct: 2 405/3 461 files have arcs, pass 0.2% vs 57% without; feather 146 files at 0% | ~2 500 | T16 |
| F2 | **tiny-skia cubic subdivision** (flatten curves the way the oracle does) | usvg-route worst files are all curves/circles at 90–95% within-8, `max_d` 64; circles inscribe an ~83-gon | most of the remaining 40–50% of icons | T17 |
| F3 | **Gradients** (linear, radial, stops, units, transform, spread) | paint-servers 7–14%; `url()` renders as none | ~120 + many painting tests | T18 |
| F4 | **`use` / `symbol` / `defs`** references | structure/use 29% direct → 90% usvg; symbol 6% | ~60 direct | T19 |
| F5 | **clipPath** (then mask) | masking 9% / 23% | ~90 | T20 / T21 |
| F6 | **Group opacity as a layer**, `mix-blend-mode`, `isolation` | painting/opacity 44–56%, mix-blend 0% | ~30 | T22 |
| F7 | **`stroke-dasharray` / `dashoffset`** | 29% / 0% | 23 | T23 |
| F8 | [Sonnet-eligible, split into checkable pieces] Small parse/semantics bundle: default size when no `width`/`height`/`viewBox` (resvg: 100×100), `transform-origin`, `paint-order`, `shape-rendering="crispEdges"` (non-AA rasterize), `switch`/`systemLanguage`, nested `<svg>` viewport, `overflow`, `<style>` with type/class/id selectors, all 147 named colours, `color`/`currentColor`, percent lengths on root | dozens of 0–50% directories | T24 |
| F9 | [Sonnet-eligible] Harness: `--failing-from`, `--dir`, `--fast` sizes | needed for fast iteration on failures | T15b |

**Not doing (by design or scope):** text and fonts (use the usvg route),
`image` (no decoders in the trusted base), filters (397 files; a small
subset like feOffset/feFlood/feMerge/feGaussianBlur could come later),
markers and CSS beyond simple selectors (usvg route), DTD internal subsets
(the 4 "unsupported" files are entity tests; rejecting them is the point).

## Waves (disjoint files so agents run in parallel)

- **Wave 1:** T15b (Python), T16 arcs (`Svg.lean` path parser + arc→cubic in
  `Svg.lean`), T17 flattening (`Geom.lean` flatten section), T23 dashes
  (`Geom.lean` new `dashPoly` + one call in `Render.drawShape`).
- **Wave 2:** T19 defs table + `use`/`symbol` (`Svg.lean` interpret), T22
  group-opacity layers (`Render.lean`, `Canvas.lean`), T24 bundle (`Svg.lean`
  parse-level; after T19 to avoid conflicts, or same agent).
- **Wave 3:** T18 gradients (needs the defs table; `Canvas.fillMask` gets a
  paint callback), T20 clipPath (`Raster` mask multiply), T21 mask.

Every task keeps `tasks/README.md` invariants, leaves `Effect.lean`
untouched, and reports `run_tests.py` (no file may regress) plus the
relevant corpora slice at small sizes (`--fast`).
