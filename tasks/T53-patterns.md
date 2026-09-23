# T53 — `pattern` paint servers

## Spec implemented

`fill`/`stroke="url(#p)"` naming a `<pattern>` element, matching usvg's
`crates/usvg/src/parser/paint_server.rs` (`convert_pattern`/`to_user_coordinates`)
for semantics and resvg's `crates/resvg/src/path.rs::render_pattern_pixmap`
for rasterisation:

- `patternUnits` (`objectBoundingBox` default) / `patternContentUnits`
  (`userSpaceOnUse` default), independently.
- `x`/`y`/`width`/`height` as numbers, percentages, or lengths, resolved the
  same way gradient coordinates are (`Grad.LenPct`'s convention), but at a
  wider internal scale (`Pat.coordScale`, see below) so an
  `objectBoundingBox` fraction survives being multiplied by a large bounding
  box without rounding error turning into a whole device pixel of drift.
- `viewBox` + `preserveAspectRatio` (all nine alignments, `meet`/`slice`,
  `none`), reusing the tight-bounding-box/bbox-transform machinery
  `Grad`/`Shader.lean` already has for gradients.
- `patternTransform` (the element's own attribute only — usvg never inherits
  it through `href`, unlike every other pattern attribute here).
- `href`/`xlink:href` inheritance of every attribute above and of content: a
  bounded chain (fuel 8, same constant as `Grad.hrefFuel`), a self- or
  origin-reference stops it exactly as usvg's `HrefIter`, and content comes
  from the first link (self first) that has any children of its own, usvg's
  `find_pattern_with_children`.
- Zero-size (after the chain resolves `width`/`height`, before any
  `objectBoundingBox` scaling) and a zero-area referencing shape under
  `objectBoundingBox` both degrade to "not rendered" — never the paint's
  `url()` fallback, matching usvg's own rule for the same case on a gradient.
- Nested patterns within bounds: a pattern's content can paint with another
  pattern (`pattern-on-child`), including a cycle (`self-recursive`,
  `recursive-on-child`), bounded by `Pat.patternFuel` (6) rather than a
  visited set — see "Known gaps" below for exactly what that does and does
  not reproduce.
- Sampling quality: nearest for the common case, bicubic (tiny-skia's own
  sixteen-tap filter, ported into the same `F32` IEEE emulation
  `Canvas.compositeBlend` already carries) whenever the combined
  `ctm · patternTransform` is not a pure positive, unrotated scale-then-
  translate — `PatternRender.lean`'s header works through why that is
  exactly resvg's own `Transform::is_translate` downgrade rule, from the
  matrix's own coefficients rather than a float round-trip.
- Tile surfaces are capped (`Pat.maxTileDim` = 2048, `Pat.maxTilePixels` =
  1048576): a tile that would round to 0 pixels or past either cap paints
  nothing rather than allocating. Both directions are exercised by new
  adversarial cases (below).

### Files

- `LeanSvg/Pattern.lean` (new, imported by `Svg.lean`): `RawDef`/`Resolved`/
  `Defs`, `href` resolution, and the pure geometry (`absRect`, `viewBoxMat`) —
  no dependency on `Svg.Node`, mirroring `Shader.lean`'s split for gradients.
- `LeanSvg/PatternRender.lean` (new, imported by `Render.lean` only): tile
  rasterisation and the per-pixel sampler (`Canvas.fillMaskPattern`). This
  had to be a second module rather than living entirely in `Pattern.lean`:
  drawing a pattern's content needs `Svg.Node`/`Svg.Style`, which would make
  `Svg.lean` depend on itself if it lived in the module `Svg.lean` imports.
  Its header explains the recursion this forces (`Pat.build`'s only
  recursive call, folded into one function rather than split across
  `build`/`drawOneShape` so Lean sees it as ordinary structural recursion on
  `fuel`, not a `mutual` block needing a hand-written termination proof).
- `LeanSvg/Svg.lean`: `Paint.pattern`, `Style.patterns : Pat.Defs`,
  `resolvePaint`'s extra lookup, `parsePatternDef`/`parsePatCoordFine`/
  `parsePreserveAspectRatio`, `defsScan`'s pattern collection (raw attrs +
  `hadChildren`), `patternContentShapes` (a `textShapes`-style bounded
  mini-walk that collects one `<pattern>`'s own children into `Doc.nodes`'
  shape, reusing `applyEffective` for the cascade), and `interpret`'s glue
  (`patTable` built alongside `gradTable`, `patternContent` collected after
  the main walk, both attached to the final `Doc`).
- `LeanSvg/Render.lean`: one added match arm in `drawShape`'s paint dispatch,
  calling `Pat.build` exactly where `Grad.build` is called for a gradient.

### The one numeric bug worth writing down

`objectBoundingBox`'s fraction is usually small (`0.05`–`0.2` in this
task's own corpus) and gets multiplied by a bounding box that can be large
(hundreds of user units). Parsing that fraction straight to 16.16 (as
`Svg.parseCoord16` does, correctly, for gradients) and *then* multiplying by
the box quantises it before the multiplication ever happens: `0.05` rounds
to `3277/65536 = 0.050003…` at 16.16, which sounds negligible until it is
multiplied by a bounding box a hundred-odd units across and the whole thing
repeats every tile — `patternUnits=objectBoundingBox` (bbox 160×70, tile
32×14) came out with every tile boundary shifted a whole device pixel from
resvg's own `f32` (whose rounding error there is nine orders of magnitude
smaller). `Svg.parsePatCoordFine` parses at `Pat.coordScale` (2^32) instead,
and `Pat.absRect` combines the bounding-box multiply and the return to 16.16
in one rounded division, so there is exactly one rounding step between the
decimal in the file and the device pixel, same as gradients have — see
`Pattern.lean`'s `coordScale` doc comment for the worked numbers.

## Skipped, and why

- **`clip-path` on pattern content.** `patternContentShapes` parses it into
  `Style.clipRef` like anywhere else, but nothing consumes it — no entry
  ever reaches `Doc.uses`, so it is silently ignored. None of this task's
  corpus needs it; adding it properly would mean threading `Clip.lean`'s
  cache through the tile renderer too.
- **Dashed strokes in pattern content.** `PatternRender.drawContentShape`
  strokes every subpath as a single stroke a plain outline, never splitting
  it by `stroke-dasharray`. Not exercised by the corpus.
- **`<switch>` and a nested nested `<pattern>` as content, inside
  `patternContentShapes`.** Both fall through to "unknown element, drop the
  subtree" there. A `<pattern>` nested in another's markup still gets its
  own top-level slot and content array (every raw pattern is walked from its
  own event index by the same loop that walks top-level ones), so it is
  only the specific case of `<pattern>` *directly inside* another pattern's
  own content that is dropped, and no corpus file does that.
- **Recursion is fuel-bounded, not a visited set.** usvg's own cache makes a
  pattern currently being resolved answer "unresolvable" if referenced again
  (a classic grey-node cycle guard), which is order-dependent on a mutual
  cycle: `recursive-on-child.svg`'s two patterns reference each other, and
  usvg's result is asymmetric — whichever is referenced *first* from the
  main document gets the richer tile, the other gets nothing, because the
  first one's build is still in flight when the second is reached.
  Reproducing that exactly needs real memoised recursion with a
  currently-building marker; `PatternRender.build`'s `fuel : Nat` decrement
  is deliberately simpler (see the module's header comment for why: a
  higher-order "pass the drawing function itself down as a callback and let
  it recurse" design either needs a hand-written well-founded recursion
  proof across two mutually recursive functions or risks Lean rejecting it
  outright, for three test files' worth of exactness). The bound still
  *rejects* every cycle in this corpus (self-recursive, self-recursive-on-
  child, recursive-on-child all terminate, cleanly, well under the fuel),
  it just does not reproduce usvg's specific asymmetric answer, so those
  three score around 91–93% within 8 rather than passing. Documented, not
  silently wrong: `PatternRender.lean`'s header spells out the exact
  divergence.
- **A handful of corpus files remain close but not over the 99% line**
  (`nested-objectBoundingBox` 95.8%, `out-of-order-referencing` 98.9%,
  `tiny-pattern-upscaled` 96.8%, `transform-and-patternTransform` 90.6%,
  `text-child` 64.6%). Spot-checked visually — the first four are pixel-
  perfect or very close by eye (checked side by side), the numeric gap
  reads as accumulated anti-aliasing-edge disagreement across many small
  repeated tiles rather than a positional or colour bug: this renderer's
  pattern fills stay on the ordinary integer `Canvas.blendOver`/`div255`
  composite pipeline (`PatternRender.lean`'s header explains the trade), one
  level looser than resvg's own highp `f32` pipeline (every pattern fill is
  highp there, since `SpreadMode::Repeat` has no lowp implementation
  either), and `transform-and-patternTransform` in particular composes a
  `rotate(-30)` element transform with a `rotate(30)` `patternTransform`
  that cancel *exactly* in this renderer's fixed-point trig but not in
  resvg's `f32`, so the two pick different sides of the nearest-vs-bicubic
  threshold for the same file. `text-child` (`patternTransform="skewX(10)"`
  content that also overflows its own tile, `<rect width="100">` inside a
  `width="40"` pattern) is the one case I could not get closer within the
  time this task budgeted; it did not reveal an obvious single bug under
  inspection and is left as a known gap rather than guessed at further.

## Report

### Corpus (`paint-servers/pattern`, `--width 100`, `tests/run_corpora.py`)

| | before | after |
|---|---|---|
| within-8 pass | 4/31 | 22/31 |

### Whole `resvg` corpus (same route, `--compare` against the pre-edit baseline)

| | before | after |
|---|---|---|
| within-8 pass | 835/1679 | 850/1679 |

25 files newly pass (all `pattern`-adjacent: the `paint-servers/pattern`
files above plus `painting/{fill,stroke,fill-opacity,stroke-opacity}/*-
pattern*.svg` and `painting/context/with-pattern-on-marker.svg`). **10 files
newly fail**, and every one of them is the same coincidence: an invalid
`feConvolveMatrix` config under `filters/feConvolveMatrix/` (missing
`kernelMatrix`, wrong value count, zero/negative `order`, out-of-range
`targetX`, `divisor=0`) that also happens to use a `<pattern>` fill. resvg
refuses to render the referencing element for these (an invalid filter
primitive, by spec, makes the effect undefined — resvg's answer is nothing),
which used to *coincidentally* match this renderer's old output (pattern
unsupported → also nothing), for an entirely unrelated reason. Now the
pattern fill correctly renders, and the mismatch is exposed: this renderer
has no `filter` support at all (`DESIGN.md` §3.3, pre-existing and out of
this task's scope) and does not hide an element on an unevaluable filter
reference, so it now shows the pattern where resvg shows nothing.

I looked at fixing this (treating any `filter="url(#id)"` reference as
"hide the element", matching SVG's own error-handling rule for a filter
effect that cannot be evaluated) and reverted it: `0/1679` — checked wrong
the first time I read that number off the CSV — is not how many filter
tests currently pass; a large fraction of `filters/*` already scores 100%
by relying on this renderer's "ignore `filter`, render unfiltered" fallback
resembling several *valid* filters' actual output closely enough. Trying the
blanket rule turned 10 fixed regressions into **45**, net worse. I did not
find a narrower rule (e.g. specifically validating `feConvolveMatrix`'s own
attributes) worth the scope for this task, so these 10 are left as a
documented, understood exception to "zero regressions": not a bug in the
pattern implementation, a pre-existing gap it happens to newly expose.

### Local suites

- `tests/run_tests.py`: 23/27 → 24/28 (new `47_pattern.svg`, 99.07% exact /
  99.93% within 8 against resvg; the 4 pre-existing failures are unchanged,
  same scores).
- `tests/run_adversarial.py`: 61/61 → 64/64 clean, 0 violations. Two new
  cases: `pattern_tiny_tile_huge_canvas.svg` (a `0.0001`×`0.0001` tile
  repeated across a 4000×4000 canvas rounds to a 0×0 device tile and must
  paint nothing rather than divide by zero or loop per repeat) and
  `pattern_huge_tile.svg` (one pattern whose own `width`/`height` alone
  exceed `maxTilePixels`, one whose modest `width="4" height="4"` is blown
  up past it by `patternTransform="scale(100000)"` alone) — both render in
  under 20 ms and produce a fully transparent fill where the tile is
  rejected, confirmed by pixel inspection, not just "did not crash".
- `tests/run_tiles.py`: 27/27 → 28/28 byte-identical, including the new
  `47_pattern.svg` — patterns correctly use the same `(ox, oy)`
  viewport-origin folding gradients already had, so a pattern fill in a
  `--viewport` tile samples the same tile pixel a full render would.
- `scripts/check-theorems.sh`: `theorems ok`, unchanged (`proofs/
  SizeBound.lean` reasons about the output canvas, which patterns never
  touch — a tile canvas is a separate, independently-capped allocation).
- `lake build`: no errors, no new warnings.

## Verification commands run

```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst        # baseline
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after3 --no-worst \
  --compare /tmp/base/resvg_direct.csv
python3 tests/run_tests.py
python3 tests/run_adversarial.py
python3 tests/run_tiles.py
bash scripts/check-theorems.sh
lake build
```
