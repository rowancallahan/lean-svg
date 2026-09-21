# Session summary — 2026-09-19 → 2026-09-20

## Update 2026-09-20 night: wave 1 landing (main a7053eb, all local, nothing pushed)

Merged today, each after `lake build`, `run_tests` (no regression),
`run_tiles` byte-identical, `run_adversarial` clean, `Effect.lean` untouched:

- **T15 external corpora harness** (`tests/run_corpora.py`; resvg-test-suite
  1 679 files, simple-icons 3 461, feather 287; routes *direct* and *usvg*).
  Baseline at f02dad9: resvg 24%/57%, simple-icons 18%/44%, feather 31%/50%.
  Failure analysis and wave plan in `FEATURES.md`.
- **T15b harness flags**: `--fast` (100/64 px, all cores), `--dir`, `--out`,
  `--failing-from`, `--compare` (same width only!), `--has-arcs`.
- **T17 tiny-skia cubic subdivision** (`Geom.lean` flatten): simple-icons via
  usvg 42.5% → 86.5%; ten corpus files up; 15_spiral −0.03 (quadratic
  elevation, fixed by T30). `ellipsePath` confirmed identical to usvg's.
- **T16 elliptical arcs** (`Svg.lean` `A`/`a` → 90° κ cubics, fixed point, no
  atan2): simple-icons arc files 0.2% → 24.8%, feather arc files 0 → 38.4%,
  non-arc files unchanged; new `tests/svg/22_arcs.svg`. Ceiling for arc files
  is flattening (usvg route reaches 31.6%), not the conversion.
- **T24a** 148 CSS colours (checked vs Pillow, `tests/check_colors.py`),
  `color`/`currentColor`, 100×100 default size. Corpus byte-identical.
- **T23 dashes** (`Geom.dashPoly`, Skia semantics incl. closed-subpath
  merge and zero-length dots): stroke-dasharray/offset slice 5/23 → 11/23,
  the rest flattening-limited or `em`/percent units; new `23_dashes.svg`
  PASS; all other files byte-identical.
- **T30 native quadratics** (`PathCmd.quadTo`, tiny-skia `QuadraticEdge`
  rule, `Q`/`T` no longer elevated): 03_curves +0.33, 12_badge +0.28,
  15_spiral +0.23, everything else byte-identical; 15_spiral now emits
  exactly resvg's 532 segments. Note: `shift==0` bumps to 1 (2 segments),
  as in the Rust, not to a line.
- **T27 switch/conditionals** (`interpret` rewrite, `passesConditions`):
  structure/switch 1/13 → 13/13, systemLanguage 4/10 → 6/10 (rest need
  clipPath, gradients, text). Replicates usvg quirks: unknown tags are not
  switch candidates, `display:none` winner renders nothing, root `<svg>` is
  gated too. Corpus byte-identical.
- **T25 fonts** (`LeanSvg/Font.lean`, pure total TrueType parser: cmap 4/12,
  glyf simple+composite with fuel, hmtx, kern, GPOS pair adjustment;
  `LeanSvg/Fonts/{NotoSans,NotoSansBold,NotoSansItalic}.lean` OFL Latin
  subsets ~32 KB each; `fontdump` debug exe, the only IO, not linked into
  `lean-svg`): exact match vs fontTools on 431/431 subset glyphs ×3 and
  2791/2791 full-font glyphs; fuzz 2000/2000 clean. Renderer untouched.
- **Font demo** (`tests/out/fontdemo/`, built by the scratch script
  `fontdemo.py`; served by `.claude/launch.json` config `reports` on port
  8767): "Hello, fonts! AVAWAY fjord" as paths from `fontdump --embedded`
  vs resvg `<text>` with the same TTF. **Layout is pixel-exact** (resvg on
  our paths == resvg on `<text>`, 100% identical). Our rasteriser on those
  paths: 96.3% exact, and *no* pixels within 1–8, max diff 255 → to
  investigate (flipped `scale(k -k)` transform + native quads? see T31 note).
- **T24b transform-origin + percent root sizes** (`Style.originDx/Dy`,
  `parseTransformOrigin`, `resolveRootSize` shared by `canvasSetup`):
  structure/transform-origin 3/23 → 14/23 (rest need clipPath/gradients/
  text); percentages resolve against the viewport in usvg, not the bbox.
  Corpus byte-identical. Gap: resvg's content-bbox size refit when a root
  dimension falls back to 100×100.
- **T29 `<style>` CSS** (`LeanSvg/Css.lean` simplecss subset: comments,
  @-rules skipped, type/class/id/attr/`:first-child`, descendant/child
  combinators, specificity + source order + `!important`; `Xml.Event.text`
  + total `decodeText` so element text and CDATA reach `interpret`;
  `tests/CssTests.lean` 38 `#guard`s): structure/style 5/16 → 16/16;
  style-attribute 3/4 (`comments.svg` needs comment stripping in the
  `style=""` parser). Merged with T27 by **T29m** (both stacks pushed/popped
  in lockstep). Corpus byte-identical; adversarial now 42 cases.
- Corpus now **19/23** at the strict bar. Failing: 12_badge 98.56, 14_flower
  97.81, 15_spiral 97.48, 16_stress 97.48 (curve/stroke antialiasing).

Design decisions today: fonts ship embedded (OFL Noto Sans subsets) and the
TrueType parser is a pure total function `bytes → outlines`, so the effect
layer and theorems do not change; reading system fonts is a PLAN M11 TODO
(a future `Op.readFont` under one fixed directory). Fan-out rule: Sonnet
agents for scoped, mechanically checked tasks; at most 2 Opus at once; Opus
agents may spawn Sonnet helpers. **Rowan asked for no new Opus agents
(usage) and a break once the in-flight work lands.**

## Paused (Rowan's request, late 2026-09-20)

**Everything landed; no agents running; nothing pending on any branch.**
Worktrees under `.worktrees/` (T16, T17, T23, T24a, T24b, T25, T27, T29,
T30) are all merged and can be removed with `git worktree remove <path>`
(and `git branch -d`) when convenient.

Merge recipe:
```bash
git merge --no-edit <branch> && lake build && \
  python3 tests/run_tests.py | tail -3 && \
  python3 tests/run_tiles.py | tail -1 && \
  python3 tests/run_adversarial.py | tail -1
```
PLAN.md now carries the reviewed "Scoped feature plan" (text, layers,
gradients, clipping, masks, nested svg), approved by Rowan; use it with
FEATURES.md when ordering wave 2.

## Next steps after the break (no new Opus until usage allows)

1. Merge whatever landed; refresh corpora numbers with
   `python3 tests/run_corpora.py --fast --out tests/out/corpora-fast`.
1b. **T31 (Opus when usage allows) edge rounding.** Found via the font demo:
   a plain `<rect x=100 width=300 height=700 transform="translate(20 110)
   scale(0.072 0.072)">` (positive or flipped scale, rect or path, same
   result) differs from resvg on 142 px, all by whole quarter-steps
   (63/96/127/128/176 levels) → one supersample row/column off on straight
   edges at fractional positions. Quads differ by 1/16 steps (15/16/31/32),
   the known flattening residual. Check `Raster.mkEdge` top/bottom rounding
   against tiny-skia `LineEdge::new` (`fdot6::round`, the `(y+32)>>6` rule
   and the `SHIFT` handling in `edge_builder`), and whether tiny-skia takes
   the `fill_rect` exact-area path for rect-shaped paths. Repro SVGs: the
   six cases in the scratch script `fontdemo.py`'s sibling run (see summary
   text above); rebuild with any 0.072-scaled rect. This likely explains a
   chunk of the 12_badge/14_flower/16_stress residual too.
2. Wave 2 (Opus, one at a time): **T19** defs table + `use`/`symbol`
   (`interpret`; after T27/T29), then **T22** group opacity as a layer.
3. Sonnet-eligible leftovers: paint-order and crispEdges (after T23), nested
   `<svg>`/`overflow` (after T19), quadratic outlines from `Font.lean`
   (after T30), `structure/svg/no-size` bbox refit.
4. Wave 3: T18 gradients (needs T19), T20 clipPath, T21 mask.
5. Fonts: T-B text layout and rendering of `text`/`tspan` using `Font.lean`.
6. Theorems: M3 PNG size bound, M3b no-clobber/work bound; M7 lean-zip; M10 Aeneas.

## Earlier today (kept for continuity)

- T6 sorted edge walk, T11 seamless stroker, T12 hairlines, T14 parallel
  bands (`--threads N`, byte-identical), T13 playground (port 8766 via
  `python3 playground/server.py --port 8766`), T8 output path, T10 tile
  culling, T1 AA port, T2 blend, T4/T4m viewport tiles, T5 opacity, T7 fast
  path, T3 size benchmark, harness design (`harness/README.md`, M10 deferred).
- Conventions: `tasks/README.md` rules 8 (multiline shell) and 9 (short
  verification loop); PLAN M3b stronger effect theorems, M6b parallel bands,
  M11 text/fonts.

## How to run

```bash
lake build && make test && make tiles && make adversarial
python3 tests/run_corpora.py --fast --limit 50   # quick corpora sample
python3 playground/server.py --port 8766         # http://127.0.0.1:8766
```

---

## Update 2026-09-21: performance, licensing, and a stopping point (main ecddf8c, pushed)

Public at https://github.com/rowancallahan/lean-svg (renamed from microsvg).

**Performance.** Three wins, in the order they were found:

- **T41 gradients.** `Int.ediv` per channel per pixel in `lerpCh`, not the
  stop search. Bit-exact; 1.05–1.09x on arm64, 1.40x on x86 (ARM divides
  faster).
- **T42 flattening.** The atomic-refcount theory was refuted three ways. The
  real cause was `pack` allocating three GMP bignums per pixel, because
  `Nat`'s `<<<` has no scalar fast path in the Lean runtime (unlike `>>>`,
  `land`, `lor`). confetti 1446 -> 417 ms, stress 3621 -> 976 ms.
- **T44 integer compositing.** `normal`-mode layers moved off the f32
  pipeline to integer source-over, 6.4x per pixel. An authorised fidelity
  trade: `26_layers.svg` alone changes, 3.53% of its pixels, max delta one
  level. Rollback point documented at `Canvas.compositeLayer`.

README timings at 800 px over the day: confetti 232 -> 63 ms, stress
734 -> 242 ms, icons 34 -> 26 ms. **stress at 2000 px with `--threads 4` is
262.2 ms against resvg's 262.2 ms, dead even** over 11 interleaved runs.

**Threading, concluded.** Hardware ceiling measured at 5.23x using fully
independent processes, so the cap is memory bandwidth, not core count. We
reach 3.5x. The gap is load imbalance, slowest band over mean 1.25.
Over-decomposition *hurts* because the per-band cull is a fixed cost every
band pays in full. Recorded as `tasks/T45-someday-hoist-band-culling.md`,
not scheduled: 40-60 lines through the hot path, worth roughly 20%.

**Proof boundary untouched.** `Task.spawn`/`Task.get` are pure, so band
parallelism lives inside `render` and the effect layer never sees threads.
Processes would need new `Op` constructors and would destroy the "exactly two
effects" guarantee. Ruled out deliberately.

**Docs and licensing.** `SPEC.md` added, stating the six theorems in English
alongside the Lean and, in section 4, what is *not* established. README got a
3x3 comparison table using only this project's own artwork, with per-image
timings, and a formal licensing section. `NOTICE` rewritten after an audit
found errors.

**`ROADMAP.md` added** — features left, time estimates, and difficulty
assessments for two candidate theorems (PNG round-trip, and compositor
locality). Read that first when picking this up again.

**State at the stopping point.** 23/27 fidelity, 27/27 tiles byte-identical,
61/61 adversarial clean, theorems `[propext]`. Suite 868/1679 = 51.7%, up
from 24.3%.

**Left for Rowan.** The no-clobber exercise in
`learn/hello-effects/Step3NoClobber.lean`. The T40 Pages site is still a
cloud session on its own branch, not merged, not deployed. Worktree cleanup
needs running locally (the sandbox blocks `.git/worktrees` writes):

```
git worktree prune && git branch -D t16-arcs t17-flatten t18-gradients \
  t23-dashes t24a-basics t24b-transform-origin t25-fonts t27-switch t29-css \
  t30-quads t31-edge-rounding t32-gallery t34-paint-order t36-text t37-dropzone
```
