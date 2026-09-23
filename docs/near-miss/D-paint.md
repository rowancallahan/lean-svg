# D-paint — diagnosis of the 90–97% paint near-misses

Diagnose-only, per `tasks/D-paint.md`. No renderer code was changed on this
branch; two lines were edited temporarily in a throwaway `git worktree`
(`/tmp/lsv-exp`, never committed, deleted after use) purely to measure the
effect of a candidate fix before writing it down — see Group A below.

Reference source used: `resvg`/`usvg` 0.48.1, cloned locally at
`/tmp/resvg` (`git clone --depth 1 --branch v0.48.1
https://github.com/linebender/resvg`), plus the `usvg` CLI (already on
`PATH` from `scripts/cloud-setup.sh`) to dump the simplified,
text-to-path, fully-resolved SVG usvg actually hands to the rasteriser —
this is what pins down the exact gradient boxes below, not guesswork.

No other branch touching `LeanSvg/PatternRender.lean`, `LeanSvg/Shader.lean`
or the pattern/text corpus files was visible in `git branch -a` at the time
of this diagnosis (only `origin/claude/research-d-paint` itself); if another
agent lands fixes here concurrently, re-run the two repro commands below
before trusting these numbers.

Repro (all 7 files, 200 px, tol 8):

```bash
export PATH=$HOME/.elan/bin:$PATH
lake build
resvg -w 200 --skip-system-fonts --use-fonts-dir tests/corpora/resvg-test-suite/fonts \
  tests/corpora/resvg-test-suite/tests/<path>.svg /tmp/ref.png
.lake/build/bin/lean-svg tests/corpora/resvg-test-suite/tests/<path>.svg /tmp/ours.png --width 200
```

scored with `tests/run_tests.py`'s `compare()` (max-channel delta, tol 8,
threshold 0.99). **Pitfall found while writing this up:** re-using the same
output filename across a Python loop that calls `resvg` then `lean-svg` in
sequence occasionally reads back a stale/mismatched pair of PNGs on this
machine (file-write-visibility race, cause not fully isolated) — every
number below comes from a run using a **unique output path per file**;
an earlier run reusing one shared path produced silently wrong (much lower)
scores that did not reproduce once filenames were made unique. Worth keeping
in mind for any future scripted D-* diagnosis.

## Per-file diagnosis

### `paint-servers/pattern/nested-objectBoundingBox.svg` (0.958)

- **Cause:** Group A (tile resampling), see below. Diff is a fine grid of
  1–5-level seams following every checkerboard/gradient edge inside the
  tile, exactly the signature of nearest-neighbour vs. bicubic tile
  sampling. One extra, smaller finding specific to this file: at
  `(x=80, y=100)` (200 px render) resvg has no coverage
  (`ref=[0,0,0,0]`) but lean-svg draws a partial-coverage pixel
  (`ours=[0,0,0,64]`) just past the right edge of the small
  `patternContentUnits="objectBoundingBox"` rect — a ~½-pixel edge-rounding
  difference in the nested content-scale transform chain
  (`LeanSvg/PatternRender.lean:265-279`, `contentMat`/`tileRootMat`) versus
  usvg's floating-point equivalent. Not independently verified as a second
  bug distinct from Group A; re-check once Group A is fixed, it may vanish
  on its own (bicubic resampling would smear this single stray pixel back
  into the general 1-5 level noise floor).
- **Code location:** `LeanSvg/PatternRender.lean:264` (sampler choice),
  `:265-279` (nested content-unit scaling).
- **Proposed fix:** Group A's fix (below).
- **Size:** see Group A.

### `paint-servers/pattern/recursive-on-child.svg` (0.927)
### `paint-servers/pattern/self-recursive-on-child.svg` (0.912)
### `paint-servers/pattern/self-recursive.svg` (0.912)

- **Cause:** Group A (tile resampling). These three render their pattern
  tile at (very close to) 1:1 device-pixel scale with no rotation, which
  makes them the cleanest evidence for Group A: at 1:1 axis-aligned scale,
  nearest-neighbour sampling of our own tile bitmap is pixel-identical to
  the tile bitmap itself (no resampling error possible), so **100% of the
  measured diff at these three files is attributable to resvg's mandatory
  resampling doing something lean-svg does not replicate**, not to any
  difference in what gets rasterised into the tile. (`self-recursive.svg`
  and `self-recursive-on-child.svg` also exercise the pattern-fill cycle
  guard — `LeanSvg/PatternRender.lean`'s module doc, lines 15–33,
  `patternFuel := 6` at line 57 — but the cycle handling itself is not the
  source of the mismatch: both land on visually correct, geometrically
  identical content to resvg's cycle-break-to-`fill:none`, confirmed by
  sampling matching stroke colours at matching positions in both renders.
  `recursive-on-child.svg`'s mutual A→B→A cycle is bounded the same way,
  and the module doc already flags that this does not reproduce usvg's
  first-reference-wins asymmetry on a mutual cycle — worth a follow-up
  adversarial test once Group A is fixed, but not the cause of *this*
  file's score: its diff is the same thin-seam pattern as the others.)
- **Code location:** `LeanSvg/PatternRender.lean:264`.
- **Proposed fix:** Group A's fix (below).
- **Size:** see Group A.

### `paint-servers/pattern/transform-and-patternTransform.svg` (0.906)

- **Cause:** Group A (tile resampling), the worst of the five because the
  element's own `transform="rotate(-30, 110, 70)"` and the pattern's
  `patternTransform="rotate(30)"` are *supposed* to cancel to axis-aligned
  in principle, but do not exactly cancel in lean-svg's Q16.16 fixed-point
  (residual `m.b`/`m.c` are near-zero but not exactly zero), so this file
  is already on the `bicubic := true` branch of
  `LeanSvg/PatternRender.lean:264` today — meaning its score is a direct,
  unmixed read of how far lean-svg's own `sampleBicubic`
  (`LeanSvg/PatternRender.lean:106-145`) diverges from tiny-skia's, with no
  nearest-vs-bicubic confound. Its low score is the strongest single data
  point that the bicubic kernel itself (not just the nearest/bicubic
  *choice*) needs work.
- **Code location:** `LeanSvg/PatternRender.lean:106-145` (`sampleBicubic`),
  `:264` (already selects bicubic here).
- **Proposed fix:** Group A's fix (below).
- **Size:** see Group A.

### `painting/fill/radial-gradient-on-text.svg` (0.946)
### `painting/stroke/radial-gradient-on-text.svg` (0.944)

- **Cause:** Group B (text bounding box for `objectBoundingBox` paint
  servers), below.
- **Code location:** `LeanSvg/Shader.lean:941` (`Grad.build`), `:997`
  (`tightBox cmds`), `LeanSvg/Shader.lean:278` (`tightBox`),
  `LeanSvg/Render.lean:284` (call site, `s.cmds` is the glyph outline),
  `LeanSvg/Svg.lean:3866-3875` (`tbox`, the *other* place a text element's
  object bounding box gets computed, for clip/mask/filter — same bug,
  different call site).
- **Proposed fix:** Group B's fix (below).
- **Size:** MEDIUM.

## Group A — pattern tile resampling (nearest vs. bicubic)

**Root cause.** resvg always renders a pattern's tile to a small `Pixmap`
and samples it back with `tiny_skia::FilterQuality::Bicubic`,
unconditionally, for every pattern fill and stroke — confirmed in the
vendored source:

```
/tmp/resvg/crates/resvg/src/path.rs:61-67   (fill_path,   Paint::Pattern arm)
/tmp/resvg/crates/resvg/src/path.rs:101-107 (stroke_path, Paint::Pattern arm)
```

both construct `tiny_skia::Pattern::new(pixmap, SpreadMode::Repeat,
FilterQuality::Bicubic, opacity, ts)`. `LeanSvg/PatternRender.lean`'s own
module doc (lines 40-49) already knows this ("every pattern fill is highp
there") but the code only turns on its own bicubic path
(`LeanSvg/PatternRender.lean:118-145`, `sampleBicubic`) when the combined
`ctm · patternTransform` has a rotation or skew component:

```
LeanSvg/PatternRender.lean:264
  let bicubic := !(m.b == 0 && m.c == 0 && m.a > 0 && m.d > 0)
```

For every axis-aligned, unrotated pattern (4 of the 5 files here) this
picks nearest-neighbour (`LeanSvg/PatternRender.lean:152-154`,
`sampleAt`/`texelAt`) instead. Nearest sampling leaves every antialiased
edge *inside* the tile (stroke lines, checkerboard boundaries, the nested
gradient rect) exactly as hard as the tile's own rasterisation, where
resvg's bicubic resample softens it by roughly one texel's worth in every
direction — which is exactly the thin, grid-aligned seam pattern visible
in `D-paint.png` for all five pattern files, and exactly why the affected
pixel count is large (7k-18k / 40k px) but the typical delta is small
(mean_abs 1.9-4.9, mostly clustered at delta 1-5 per the histogram below)
except at hard diagonal edges.

**This is not a one-line fix.** To check, the condition at line 264 was
changed to `let bicubic := true` in a throwaway `git worktree`
(`/tmp/lsv-exp`, reverted and removed, nothing committed) and the four
axis-aligned files re-measured with the same script, same `tol=8`:

| file | nearest (current) | forced bicubic (experiment) |
|---|---|---|
| nested-objectBoundingBox.svg | **0.9575** | 0.8692 |
| recursive-on-child.svg | **0.9272** | 0.8020 |
| self-recursive.svg | **0.9122** | 0.7631 |
| transform-and-patternTransform.svg | 0.9064 (already bicubic, unchanged) | 0.9064 |

Forcing bicubic on made every axis-aligned file **worse**, not better,
some dramatically so. Since resvg is *always* bicubic and lean-svg's
current nearest sampling already tracks it to 91-96%, lean-svg's own
`sampleBicubic` (the 16-tap separable kernel, `bicubicNear`/`bicubicFar` at
lines 106-111, the premultiplied-colour taps at 138-144) must itself
diverge from tiny-skia's `bicubic`/`sampler_4x4` by more than nearest
sampling does — plausibly in how it weights or unpremultiplies colour
across a coverage discontinuity inside the tile (a texel that is fully
covered next to one that is fully transparent, e.g. every tile edge),
which is precisely where `transform-and-patternTransform.svg` (already
on the bicubic path today, unaffected by this experiment) also underperforms.
The module doc's own framing of this as "at most one level of rounding,
already accepted" undersells it: once bicubic is the *only* path (matching
resvg unconditionally), this stops being a rounding footnote and becomes
the whole story for every pattern fill in the corpus, passing or not.

**Proposed fix, in order:**
1. Audit `sampleBicubic` (`LeanSvg/PatternRender.lean:106-145`) against
   tiny-skia's actual `bicubic_near`/`bicubic_far`/`sampler_4x4` C/Rust
   reference (vendored at
   `/tmp/resvg`'s `tiny-skia-path`/`tiny-skia` dependency, or
   `~/.cargo/registry/src/*/tiny-skia-*`), tap weight by tap weight, and in
   particular the coverage/premultiplied-alpha handling across a
   fully-opaque/fully-transparent texel boundary — the accepted-gap doc
   comment (lines 40-49) is the right place to start since it already
   names the suspect (F32 vs. the ordinary integer composite).
2. Once `sampleBicubic` reproduces tiny-skia closely on a few synthetic
   axis-aligned cases (e.g. a plain two-colour checkerboard tile at 1:1
   scale — the cleanest possible test, no confounds), flip
   `LeanSvg/PatternRender.lean:264` to always `true`, matching resvg's
   unconditional `FilterQuality::Bicubic`, and delete the now-dead
   nearest-sampling path (`texelAt`/`sampleAt`'s nearest branch can either
   stay as bicubic's degenerate case or be removed).
3. Re-run the full `tests/run_corpora.py --dir paint-servers/pattern`
   (and ideally the whole resvg-suite `direct` route) before merging —
   nearest sampling today "accidentally" scores well on many
   already-passing pattern tests (1:1, unrotated cases, which are common),
   so this is a real behaviour change across every pattern fill in the
   renderer, not a local patch.

**Size: MEDIUM-LARGE.** Step 1 is the open-ended part (a numeric kernel
bug with no located root cause yet); steps 2-3 are small once step 1 is
verified. Shared cause, touches one file (`PatternRender.lean`) but
affects the renderer's entire pattern-fill path, so the regression-testing
cost is real.

## Group B — text bounding box for `objectBoundingBox` paint servers

**Root cause, pinned down exactly.** For an `objectBoundingBox` gradient
(or pattern) applied to a `<text>` element, usvg does **not** use the tight
bounding box of the rendered glyph outlines. Its own source says so
outright:

```
/tmp/resvg/crates/usvg/src/text/layout.rs:404-410  (fn convert_span)
    // We have to calculate text bbox using font metrics and not glyph shape.
    if let Some(r) = NonZeroRect::from_xywh(0.0, -cluster.ascent, advance, cluster.height()) {
```

i.e. per glyph cluster it builds a box `(0, -ascent, advance_width,
ascent+descent)` from **font metrics** (not the glyph's ink outline),
unions these across the whole `<text>` (not per-`tspan>` — confirmed
separately in A2/earlier diagnosis notes: usvg's `paint_server.rs:662-665`
says "tspan doesn't have a bbox and uses the parent text bbox"), and that
union is `text.bounding_box`, the box fed into every
`objectBoundingBox`-relative paint on that text.

Confirmed numerically with `usvg`'s own CLI (already installed,
`--skip-system-fonts --use-fonts-dir tests/corpora/resvg-test-suite/fonts
<file> -c`), which resolves `objectBoundingBox` into an absolute
`gradientTransform` before handing off to rendering — so its matrix *is*
usvg's actual computed bbox, no guessing required:

```
fill:   gradientTransform="matrix(153.6 0 0 108.96 23.200005 34.480003)"
        font-size 80, baseline y="120"
        => bbox y: [34.48, 143.44], height 108.96
        => ascent = 120 - 34.48 = 85.52  (85.52/80 = 1.069 em)
        => descent = 143.44 - 120 = 23.44 (23.44/80 = 0.293 em)

stroke: gradientTransform="matrix(115.2 0 0 81.72 42.4 45.86)"
        font-size 60, baseline y="110"
        => ascent = 110 - 45.86 = 64.14  (64.14/60 = 1.069 em)
        => descent = 45.86+81.72-110 = 17.58 (17.58/60 = 0.293 em)
```

The ascent/descent fractions (1.069 em / 0.293 em) match exactly across
both files at two different font sizes — this is Noto Sans's real
hhea/OS2 ascent+descent, a fixed font property, not noise. Compare to the
actual rendered ink extent of the glyphs (measured directly from the
resvg reference PNGs, alpha-mask bounding box, 200 px render, frame
border excluded): fill case ink is `y:[63,120]` (height 57, vs. usvg's
108.96 — **1.9× smaller**); stroke case ink is `y:[65,112]` (height 47,
already including 4px of stroke padding, vs. usvg's 81.72 — **1.7×
smaller**). Horizontally the two are close (ink width ~151-117px vs.
usvg's advance-based 153.6/115.2px, within a few percent — advance width
and ink width are naturally close for a short string with no unusual
kerning, so the x-axis mismatch is a minor, secondary correction next to
the y-axis one).

lean-svg instead computes this box purely from the glyph ink outline:
`LeanSvg/Shader.lean:997`, `tightBox cmds` (defined `:278`, an exact
per-Bezier-extremum tight box — correct in isolation, and correct for
ordinary shapes, which is why the general gradient-on-shape corpus scores
~99% — but `cmds` here, from `LeanSvg/Render.lean:284`'s
`Grad.build st.defs i s.cmds gctm ...`, is `s.cmds`: the flattened *glyph
outline* commands for a text run, not a font-metrics box). Concretely,
because our gradient's effective box is ~1.7-1.9× shorter vertically than
resvg's, the same on-screen distance from the gradient's centre maps to
a much larger fraction of the (too-small) radius, so lean-svg's
radial gradient goes from white to black roughly 1.5-2× faster than
resvg's as you move away from centre — verified pixel-by-pixel (e.g. fill
case, `x=100,y=105`: resvg reads a mid-grey 127, lean-svg reads
near-black 44, while the alpha/coverage at that exact pixel is identical
between the two renders — 191 both — confirming the antialiasing/rasterising
of the glyph itself is fine and the *only* thing wrong is which colour the
gradient shader reads there).

The *same* bug exists a second time, independently, for clip-path/mask/
filter `objectBoundingBox` references on text: `LeanSvg/Svg.lean:3866-3875`
builds `tbox := shs.foldl (fun b sh => Box.union b (cmdsBox sh.cmds)) none`
— again the ink union, not the font-metrics box — feeding `uses[..].bbox`,
`maskUses[..].bbox` and filter `pf'.bbox`. This diagnosis task's file list
doesn't include a text+clip/mask/filter near-miss, so it wasn't chased
further, but a fix should plausibly cover both call sites from one shared
helper, and it is worth a quick corpus check afterward (`--dir
masking/clipPath`, `--dir masking/mask`, `--dir filters` restricted to
text-bearing files) in case it silently helps or hurts cases not on this
list.

**Proposed fix:**
1. Font ascent/descent-per-run metrics already exist in this codebase
   (`LeanSvg/Font.lean`, `LeanSvg/Baseline.lean` — used for baseline
   positioning today), so this is wiring, not new font-metrics code.
2. Add a text-specific bounding-box computation: for the whole `<text>`
   element (not per-run/per-`tspan`, matching usvg's "tspan uses the
   parent text bbox" rule), union each run's `(runBaselineY - ascent,
   runBaselineY + descent)` for the y-extent (`ascent`/`descent` scaled by
   that run's own font-size) with the existing ink-based x-extent (or,
   for closer parity, each run's total glyph-advance width — the smaller,
   secondary correction noted above).
3. Thread this box to the two call sites that currently use
   `cmdsBox`/`tightBox` on text: give `Svg.Shape` (or a parallel array
   keyed like `patternContent`) an optional override box populated only
   for text-derived shapes, and have `LeanSvg/Shader.lean:997`'s `tightBox
   cmds` and `LeanSvg/Svg.lean:3874`'s `cmdsBox sh.cmds` prefer it when
   present. Every non-text shape keeps today's behaviour exactly (override
   is `none`), so this is additive and low-risk outside text.
4. Re-run `tests/run_corpora.py --dir painting --dir masking --dir
   filters` (files with text) plus the text-specific directories, to
   catch any of today's *passing* text+paint-server/clip/mask/filter
   tests that were passing by coincidence and might shift.

**Size: MEDIUM.** Root cause and the exact numbers are fully pinned down
(no more investigation needed); the work is plumbing a new box through
`Shape`/`Grad.build`/`Svg.lean`'s three consumers and re-verifying the
text-bearing corpus, not algorithm design.

## Summary table (largest group first)

| group | files | shared cause | size |
|---|---|---|---|
| A — pattern tile resampling | `nested-objectBoundingBox.svg`, `recursive-on-child.svg`, `self-recursive-on-child.svg`, `self-recursive.svg`, `transform-and-patternTransform.svg` (5) | lean-svg samples a pattern's rendered tile with nearest-neighbour whenever the combined transform is axis-aligned (`PatternRender.lean:264`); resvg always uses bicubic (`FilterQuality::Bicubic`, unconditional, `path.rs:61-67/101-107`). Confirmed non-trivial: forcing bicubic on today makes fidelity *worse* (0.96→0.87, 0.93→0.80, 0.91→0.76), so lean-svg's own `sampleBicubic` kernel (`:106-145`) has a separate, real bug that must be fixed before the condition can simply be flipped. | MEDIUM-LARGE |
| B — text bbox for objectBoundingBox paint | `painting/fill/radial-gradient-on-text.svg`, `painting/stroke/radial-gradient-on-text.svg` (2) | usvg computes a `<text>` element's object bounding box from font ascent/descent metrics (`layout.rs:404-410`, confirmed 1.069 em ascent / 0.293 em descent, matching exactly across two files/font-sizes via `usvg`'s own resolved `gradientTransform` output), not from glyph ink outlines; lean-svg's `tightBox`/`cmdsBox` (`Shader.lean:997`, `Svg.lean:3874`) use the ink outline, giving a vertical extent 1.7-1.9× too small and a radial gradient that darkens 1.5-2× too fast away from centre. | MEDIUM |

`docs/near-miss/D-paint.png`: for each of the 7 files, `resvg | lean-svg |
diff` (diff panel red-tinted, gain ×4, matching `tests/run_tests.py`'s own
`DIFF_GAIN`/`diff_panel`), labelled with its within-8 score, stacked
top to bottom in the file order above.
