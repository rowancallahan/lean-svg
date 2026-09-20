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
- Corpus now **18/22** at the strict bar. Failing: 12_badge, 14_flower,
  15_spiral, 16_stress (all < 1 pt short, curve/stroke antialiasing).

Design decisions today: fonts ship embedded (OFL Noto Sans subsets) and the
TrueType parser is a pure total function `bytes → outlines`, so the effect
layer and theorems do not change; reading system fonts is a PLAN M11 TODO
(a future `Op.readFont` under one fixed directory). Fan-out rule: Sonnet
agents for scoped, mechanically checked tasks; at most 2 Opus at once; Opus
agents may spawn Sonnet helpers. **Rowan asked for no new Opus agents
(usage) and a break once the in-flight work lands.**

## In flight at the pause (worktrees under `.worktrees/`, branch per task)

| task | model | branch | what | merge check |
|---|---|---|---|---|
| T23 dashes | Opus | `t23-dashes` (base c0d4fe4) | `Geom.dashPoly`, one call in `Render.drawShape` | painting/stroke-dasharray, dashoffset slices; run_tests no regression |
| T25 fonts | Sonnet | `t25-fonts` | `MicroSvg/Font.lean` pure total TrueType parser, embedded Noto Sans subsets, `fontdump` exe, fontTools oracle + fuzz | 0 mismatches vs fontTools, fuzz clean, corpus byte-identical |
| T27 switch | Sonnet | `t27-switch` | `<switch>`, `systemLanguage`, required* in `interpret` | structure/switch ≥10/13, systemLanguage ≥8/10 |
| T29 CSS | Sonnet | `t29-css` | `MicroSvg/Css.lean` (simplecss subset), `<style>` integration in `interpret`, `tests/CssTests.lean` `#guard`s | structure/style ≥13/16 |
| T30 quadratics | Sonnet | `t30-quads` | `PathCmd.quadTo` + tiny-skia `QuadraticEdge` rule; `Q`/`T` no longer elevated | no file drops > 0.02; usvg-route medians not lower |
| T24b | Sonnet | `t24b-transform-origin` | `transform-origin`, percent root `width`/`height` | structure/transform-origin ≥80%, structure/svg up |

If a report arrives after the break, merge with:
```bash
git merge --no-edit <branch> && lake build && \
  python3 tests/run_tests.py | tail -3 && \
  python3 tests/run_tiles.py | tail -1 && \
  python3 tests/run_adversarial.py | tail -1
```
T27 and T29 both edit `interpret`; expect a small conflict on the second
merge (resolve by keeping both pre-passes). Unfinished agents: resume from
the task file and worktree with the same model.

## Next steps after the break (no new Opus until usage allows)

1. Merge whatever landed; refresh corpora numbers with
   `python3 tests/run_corpora.py --fast --out tests/out/corpora-fast`.
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
