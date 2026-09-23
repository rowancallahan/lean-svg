# T64 — structure and shapes tail, round 2  (branch `claude/feat-structure-tail-2`)

Round 1 (T58) and nested svg (T48), use/symbol (T47) have landed. Remaining
failures in the latest run: `structure/svg` 10/42, `transform-origin` 6/23,
`shapes/path` 7/57, `painting/stroke` 4/20, `painting/fill` 3/60,
`painting/overflow` 4/5, `masking/mask` 4/39, `masking/clipPath` 1/52,
`masking/clip` 1, `structure/style`, `structure/defs`. Triage (run these dirs
with composites, read T47/T48/T49/T58 reports for what they deferred and
why), then fix the biggest shared causes, matching resvg 0.48.1.
Skip anything needing images, filters, markers, patterns or text: other
agents own those concurrently.

---

## Common rules (every lean-svg agent)

You are one of ~15 agents working in parallel on lean-svg, a total, float-free
SVG→PNG renderer in Lean 4 whose output is compared against resvg 0.48.1.
An integrator merges all branches afterwards, so **keep your diff small and
local**: prefer new functions/new modules (`LeanSvg/<Feature>.lean`, imported
from `LeanSvg.lean`) over rewriting shared code in `Svg.lean` / `Render.lean`.
No drive-by refactors, renames or reformatting of code you do not need.

**Setup (first thing):** `bash scripts/cloud-setup.sh` then
`export PATH=$HOME/.elan/bin:$PATH`. It installs Lean from the GitHub release,
resvg/usvg 0.48.1, numpy/pillow and the resvg test suite under
`tests/corpora/resvg-test-suite`, and builds. Read `tasks/README.md`,
`DESIGN.md` and the relevant parts of `SPEC.md` before editing.

**Invariants (hard, from tasks/README.md):** no `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing, `Float`; loops over finite ranges or
structurally decreasing fuel; hot loops in `Nat`; no new build warnings;
`LeanSvg/Effect.lean` untouched unless your task is about it; no IO outside
`Effect.lean`. Code should fail loudly rather than silently: prefer
rejecting/asserting over swallowing errors, but a feature that is not
supported should degrade exactly as it does today (skip), not error.

**Reference behaviour:** match resvg/usvg 0.48.1. The Rust source is the spec
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`
into a scratch dir; `crates/usvg/src/parser/*` and `crates/resvg/src/*`).

**Baseline first, before any edit:**
```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
python3 tests/run_tests.py
```

**Verification before you push (all must hold):**
1. `lake build` — no errors, no new warnings.
2. `bash scripts/check-theorems.sh` prints `theorems ok`. Note
   `proofs/SizeBound.lean` reasons about `render`; if your change breaks it,
   fix the proof, do not delete or weaken it.
3. Full corpus with delta table:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/NN_<feature>.svg` exercising the feature
   if it fits the local corpus style (pick an unused number; collisions with
   other agents are resolved by the integrator).

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

## Implementation

Triaged all 11 target directories with `tests/run_corpora.py --fast --corpus
resvg --route direct` (width 100), then read every non-`pass` row. Almost the
entire remaining tail in every directory is out of scope, untestable, or a
poor size/risk tradeoff (see "Skipped"); one shared cause was in scope and
fixed:

1. **`objectBoundingBox` paint fallback on a degenerate-bbox shape**
   (`painting/stroke/gradient-with-objectBoundingBox-and-fallback-on-lines.svg`).
   usvg's `has_bbox` check (SVG 1.1 §7.11, `convert_path` in
   `parser/converter.rs`): a shape whose own path has zero width or zero
   height (a horizontal or vertical `line`) cannot be painted by an
   `objectBoundingBox` paint server, so `resolve_fill`/`resolve_stroke` use
   the `<fallback>` from `url(#id) <fallback>` instead — decided once, from
   the shape's own untransformed geometry, independently of whatever the
   paint server itself does. This codebase's `resolvePaint` (`Svg.lean`)
   turns a resolvable `url(#id)` straight into `Paint.gradient idx`,
   discarding the fallback colour permanently — there was no code path left
   that could ever paint it. Added the fallback as a second field,
   `Paint.gradient idx fallback` (three call sites: `resolvePaint` itself,
   and the two matches in `Svg.lean`/`Render.lean` that only needed
   `.gradient i _` since they never touched it), and — once a shape's `cmds`
   are known but before they're used for rendering — compute `hasBbox` from
   `cmdsBox cmds` (already used elsewhere for `objectBoundingBox` framing)
   and swap `st.fill`/`st.stroke` for the fallback when the paint is an
   `objectBoundingBox` gradient and `hasBbox` is false. This is deliberately
   separate from `Grad.build`'s existing `Built.skip` (a singular
   `gradientTransform`, decided at render time): that case still paints
   nothing, matching resvg's tiny-skia raster path, which has no fallback of
   its own.

### Skipped (out of scope, untestable, or not a good size/risk tradeoff)

- `structure/svg/{attribute-value,elements}-via-ENTITY-reference*.svg` (4
  files): DTD internal-subset `<!ENTITY>` expansion. `LeanSvg/Xml.lean`'s own
  module doc states this is deliberate: "No DTD internal subset ... This
  removes entity expansion attacks (billion laughs) and external entities
  (XXE) by construction; there is no code path that could expand an entity."
  Reintroducing entity expansion to pass 4 test files would undo a documented
  security invariant, not fix a bug.
- `structure/svg/{negative-size,zero-size,not-UTF-8-encoding}.svg`: `status
  ref_failed` — resvg itself errors out on these (`SVG has an invalid size`,
  `not an UTF-8 encoding`), so there is no reference image to ever match;
  not fixable by construction of the test harness.
- `structure/svg/{mixed-namespaces,xmlns-validation}.svg`: both need real
  XML-namespace-URI resolution (an `xmlns`-overridden default namespace, or a
  prefix bound to the real SVG/xlink namespace, deciding whether an element
  or attribute is "really" SVG). `Xml.lean`'s `localName` only strips a
  prefix textually and every consumer matches on local names — there is no
  namespace concept anywhere in the tree walk. Building one correctly enough
  to matter (every element and attribute, not just these two files) is a
  cross-cutting change to the parser and every dispatch site, out of
  proportion for 2 files.
- `structure/svg/no-size.svg`: no `width`/`height`/`viewBox` at all. usvg
  resolves this by rendering once with a 100×100 fallback viewport, then
  replacing the document's own size with the bounding box of everything just
  rendered (`resolve_svg_size` + `calculate_svg_bbox`) — a second full pass
  requiring a document-wide bounding-box computation before `canvasSetup` can
  even pick `W`/`H`, for one file in the whole corpus.
- `structure/transform-origin/on-{gradient,pattern}-*.svg`, `on-image.svg`,
  `on-text-path.svg` (6 files): `transform-origin` on a paint-server element,
  or needing `pattern`/`image`/`textPath`. Same conclusion as T58, which
  investigated and skipped these for the same reasons; nothing changed.
- `shapes/path/{M-A-s,M-C-S,M-C,M-S-S,M-S,M-T-S,invalid-transform}.svg` (7
  files): re-verified T58's finding — all 7 sit at 97.7–98.8% within-8
  (threshold 99%), alpha-only noise along a sharply-curving stroke edge, a
  rasterizer-fidelity gap in shared curve-flattening/stroke-outline code, not
  a missing feature. Unchanged since T58.
- `painting/stroke/{pattern*,radial-gradient-on-text}.svg`,
  `painting/fill/{pattern-on-shape,pattern-on-text,radial-gradient-on-text}.svg`,
  `painting/overflow/*-on-marker*.svg` (4 files), `masking/clipPath/clip-path-with-transform-on-text.svg`,
  `masking/clip/simple-case.svg`: need `pattern`/`text`/`marker`/`image`,
  explicitly out of scope for this task.
- `masking/mask/with-{grayscale-,}image.svg`: need `<image>`, out of scope.
- `masking/mask/with-opacity-{1,3}.svg`: not a missing feature — sampled
  pixels at identical mask/opacity combinations already match exactly; the
  ~5% of pixels that differ (up to 19/255) are a color/alpha rounding
  mismatch confined to very low mask-alpha pixels (alpha 12–31), where our
  colour channel is off by a few units at an alpha the reference varies
  smoothly and ours does not. That is premultiplied/straight-alpha rounding
  precision in the shared canvas-compositing path (`Canvas.fillMaskShader`
  or the mask-luminance raster), not this task's `mask`/`opacity` feature
  set; touching shared blending code for 2 files, with the "zero
  regressions" gate over the whole corpus, was not attempted.
- `structure/style`, `structure/defs`: already 100% (7/7, 16/16) at the fast
  triage pass — the task description's counts predate T47/T48's merges;
  nothing to fix.

## Report

New test: `tests/svg/34_gradient_fallback.svg` (100.000% exact, PASS) —
a shape with a normal bbox painted by an `objectBoundingBox` gradient next to
a horizontal and a vertical line with the same paint, both of which fall back
to the paint's fallback colour.

Verification (all commands from "Verification before you push"):

- `lake build`: clean, no errors, no new warnings.
- `bash scripts/check-theorems.sh`: `theorems ok`.
- `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after1 --no-worst --compare /tmp/base/resvg_direct.csv`:
  **1 newly passing, 0 newly failing**, 1678 unchanged.
- `python3 tests/run_tests.py`: 30/34 pre-existing local-corpus files
  unchanged (same 4 pre-existing failures as baseline — `12_badge`,
  `14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`, none new, no
  score regressed), plus the new `34_gradient_fallback` at 100.000% (PASS) —
  31/35 overall.
- `python3 tests/run_adversarial.py`: 78/78 clean (was 77/77; +1 for the new
  test file's generated variants).
- `python3 tests/run_tiles.py`: 35/35 byte-identical (was 34/34).

### Whole corpus (resvg, direct route, `--fast`, width 100)

| | before | after |
|---|---|---|
| pass | 1046 / 1679 (62.3%) | 1047 / 1679 (62.4%) |
| med within-8 | 99.950% | 99.950% |
| med exact | 98.620% | 98.620% |

### Target directories (resvg, direct route, `--fast`, width 100)

| directory | files | pass before | pass after |
|---|---|---|---|
| structure/svg | 42 | 32 (76.2%) | 32 (76.2%) — unfixed, see "Skipped" |
| structure/transform-origin | 23 | 17 (73.9%) | 17 (73.9%) — unfixed, see "Skipped" |
| shapes/path | 57 | 50 (87.7%) | 50 (87.7%) — unfixed, see "Skipped" |
| painting/stroke | 20 | 16 (80.0%) | **17 (85.0%)** |
| painting/fill | 60 | 57 (95.0%) | 57 (95.0%) — unfixed, see "Skipped" |
| painting/overflow | 5 | 1 (20.0%) | 1 (20.0%) — unfixed, needs `marker` |
| masking/mask | 39 | 35 (89.7%) | 35 (89.7%) — unfixed, see "Skipped" |
| masking/clipPath | 52 | 51 (98.1%) | 51 (98.1%) — unfixed, needs `text` |
| masking/clip | 1 | 0 (0.0%) | 0 (0.0%) — unfixed, needs `image` |
| structure/style | 16 | 16 (100.0%) | 16 (100.0%) — already full |
| structure/defs | 7 | 7 (100.0%) | 7 (100.0%) — already full |

Net: 1 file newly passing (`painting/stroke`), 0 regressed, across the whole
1679-file corpus and every local/adversarial/tile harness. The remaining tail
in these 11 directories is, file by file, either genuinely out of scope
(`image`/`pattern`/`text`/`marker`), untestable (`ref_failed`), a deliberate
security invariant (DTD entity expansion), or a cross-cutting
namespace-resolution / bounding-box / shared-blending-precision change whose
risk to the "zero regressions" gate was not justified by 1–7 files each — see
"Skipped" for the reasoning per group.
