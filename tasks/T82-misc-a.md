# T82 — pattern text child, mask opacity, stroke-width percentage  (branch `claude/fix-misc-a`)



## How to work (research first)

1. **Diagnose first (keep it short).** Render each file below with
   `.lake/build/bin/lean-svg` and with `resvg -w 200`, look at both PNGs and a
   diff, find the root cause in our code, and find how resvg/usvg 0.48.1
   handles it in the Rust source.
2. **If the fix is small and safe**, implement it, verify it with the rules
   below, and push.
3. **If it is not**, do not force it: write the diagnosis (root cause, the
   relevant usvg/resvg code, the proposed fix and its risks, rough size) into
   your task file's `## Report`, and push only that.
Either way the report must name the root cause of every file below.

Files (within-8 at 200 px):

- `paint-servers/pattern/text-child.svg` (0.615)
- `masking/mask/with-opacity-3.svg` (0.888)
- `painting/stroke-width/percentage.svg` (0.760)

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
3. Full corpus with delta table (the fast 100 px pass), and ALSO the default
   200 px pass that is the headline number: run the same command without
   `--fast` into `/tmp/base200` before editing and `/tmp/after200` after, and
   compare. Zero pass→fail at either width.
   Fast:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/<task number>_<feature>.svg` (use your
   task number as the file number, e.g. `71_image_gif.svg`, so files never
   collide) exercising the feature
   if it fits the local corpus style 

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

---

## Report

### `painting/stroke-width/percentage.svg` — fixed

**Root cause.** `stroke-width` was parsed with `parseLengthAll` (`LeanSvg/Svg.lean`),
which explicitly rejects a `%` value (`Fixed.lean`'s `parseLength`: `else if
at' bs j == 37 then none`). A rejected value keeps the style's default
(`strokeWidth := 256`, i.e. 1 px), so `stroke-width="10%"` on a 200×200
viewport silently rendered as a 1 px stroke instead of 20 px.

usvg resolves `stroke-width` through `resolve_valid_length` →
`units::convert_length` (`crates/usvg/src/parser/units.rs`): `AId::StrokeWidth`
is not one of the axis-specific ids (`Width`/`Height`/`X`/`Y`/…), so its `%`
falls to the catch-all arm, `convert_percent(length, vb_diag)` with
`vb_diag = sqrt((vb.w² + vb.h²)/2)` — the same "viewport diagonal" resolution
already implemented for `stroke-dasharray`/`stroke-dashoffset`/
`letter-spacing`/`word-spacing` (`Svg.viewportDiag`, used with
`parseDashLengthAll`).

**Fix.** `stroke-width` now uses that same `parseDashLengthAll st.fontSize
(viewportDiag st.pctRefW st.pctRefH) v`, which resolves `em`/`ex` against the
real font size and `%` against the viewport diagonal, then clamps to `≥ 0` as
before (`LeanSvg/Svg.lean`, one line). No new module needed — this reuses an
existing, already-verified length parser.

### `paint-servers/pattern/text-child.svg` — fixed

**Root cause.** `Pat.build` (`LeanSvg/PatternRender.lean`) decides the tile
raster's per-axis scale as the norm of each *column* of `m = ctm · patternTransform`:
`sx16 = √(a²+b²)`, `sy16 = √(c²+d²)`. tiny-skia 0.12's actual
`Transform::get_scale` (`path/src/transform.rs`, vendored copy at
`/tmp/tiny-skia-src` for this task) takes the norm of each *row* instead:
`x_scale = √(sx²+kx²) = √(a²+c²)`, `y_scale = √(ky²+sy²) = √(b²+d²)`, where
tiny-skia's `(sx, kx, ky, sy)` are this project's `(a, c, b, d)`
(`Transform::map_point`: `x' = sx·x + kx·y + tx`, `y' = ky·x + sy·y + ty`,
matching `Mat.apply`'s `a c e; b d f` exactly). Row- and column-norms
coincide for a pure rotation (both are orthonormal there), which is why
`with-patternTransform.svg`/`transform-and-patternTransform.svg`
(`rotate(30)`, already in the corpus and already passing) never exposed this.
They diverge for a `patternTransform` with an actual shear — `skewX`/`skewY`
— such as `text-child.svg`'s `skewX(10)`, where the column-norm formula
hands the tile the *wrong axis's* scale (confirmed by bisection: a pure
`rotate()` patternTransform scored 0.9998 within-8 before this fix, a
non-uniform `scale()` with no shear scored 1.0 (nearest-sampling path, not
affected), and every `skewX`/asymmetric-shear variant I constructed dropped
to 0.83–0.85 before the fix and 0.999–1.0 after).

**Fix.** Swapped the pairing to match `get_scale`: `sx16 = √(a²+c²)`,
`sy16 = √(b²+d²)` (`LeanSvg/PatternRender.lean`, two lines, `Pat.build`). This
only changes behaviour when `patternTransform`/the CTM has a genuine shear
(`b ≠ 0` or `c ≠ 0` in a way that is not a pure rotation); every axis-aligned
pattern (the overwhelming majority of the corpus and of real documents) has
`sx16`/`sy16` computed from `(a,0)`/`(0,d)` either way, so the fix is a no-op
there — confirmed by the full-corpus delta table below (only the two target
files moved).

Also pinned the resvg reference to the suite's own fonts
(`--skip-system-fonts --use-fonts-dir tests/corpora/resvg-test-suite/fonts`)
while diagnosing: without it, the sandbox's resvg has no "Noto Sans" and
silently drops the `<text>` child, while this renderer's own font table
always has it, which looked like a second bug (a diff shaped exactly like
the word "Text" tiled across the pattern) until re-running with fonts pinned
made it disappear. `tests/run_tests.py`/`run_corpora.py` already pin fonts
this way, so this was only a hazard in my own by-hand `resvg` invocations,
not in the actual scoring harness.

### `masking/mask/with-opacity-3.svg` — diagnosed, not fixed

**Root cause.** Not a masking bug: reproduces with a plain gradient-filled
rect and a group `opacity`, no `<mask>` at all —

```svg
<linearGradient id="lg1">
  <stop offset="0" stop-color="white" stop-opacity="0"/>
  <stop offset="1" stop-color="black"/>
</linearGradient>
<rect x="20" y="20" width="160" height="160" fill="url(#lg1)" opacity="0.5"/>
```

scores 0.98 within-8 against resvg on its own (200 px), with diffs of 16–20
concentrated where alpha is small (e.g. `ref [235,235,235,13]` vs
`ours [255,255,255,12]`). This is `DESIGN.md` §3.9's own documented,
authorised trade: `opacity < 1` opens a real layer (`groupBegin`/`groupEnd`),
composited with the integer `Canvas.compositeNormal` shortcut rather than the
`F32` emulation of tiny-skia's highp `SourceOver`, which "differs from the
f32 pipeline by at most 1 of 255" *in premultiplied terms*. A gradient from
`stop-opacity="0"` sweeps through very low alpha, and unmultiplying a
premultiplied colour that is off by 1 at alpha≈12–16 (`255/13 ≈ 20`) turns
that single documented unit of premultiplied error into the 16–20 swings
`tests/run_tests.py`'s straight-alpha comparison sees. `with-opacity-3.svg`
stacks two such layers (the mask content rect's own `opacity="0.5"`, then the
masked rect's `opacity="0.5"`) plus the mask's luminance step (another
premultiply/demultiply through `F32`, `Mask.lumaF32`), each of which can push
more pixels into that low-alpha amplification regime — bisected with
`/tmp/diag/variants/v1..v4` (isolating: outer opacity alone → 0.996; rect's
own opacity alone → 0.952; gradient+opacity with no mask at all → 0.98; solid
colour+opacity, no gradient → exact); confirms the mask itself contributes
nothing beyond what plain nested `opacity` already costs.

**Why not fixed here.** The only real fix is running every `normal`-mode
layer composite through the exact `F32` pipeline instead of
`compositeNormal`'s integer shortcut — reverting the perf win `DESIGN.md`
§3.9 documents as "the project's only deliberate fidelity trade, authorised
for this one mode" (6.4× slower, "the largest remaining cost in the
renderer"). That is a global, performance-sensitive change to
`Canvas.compositeLayer`'s hot path, not a local one, and risks every other
file whose score currently depends on that speed/precision trade-off. Out of
scope for a "small and safe" fix under this task; flagging for a
dedicated task instead.

### Verification

| check | result |
|---|---|
| `lake build` | ok, no errors, no new warnings |
| `scripts/check-theorems.sh` | `theorems ok` |
| resvg corpus, `--fast` (100 px, 1679 files) | before 1521 pass / after 1522 pass; 0 pass→fail; `percentage.svg` 0.760→1.000 (fail→pass), `text-child.svg` 0.507→0.930 (still fail at 100 px — font hinting at this size is coarser for both renderers, but +42 points) |
| resvg corpus, full 200 px (1679 files) | before 1542 pass / after 1544 pass; **0 pass→fail**; `percentage.svg` 0.760→1.000 (fail→pass), `text-child.svg` 0.615→0.996 (fail→pass) |
| `run_tests.py` | 46/50 → 46/50 (same 4 pre-existing failures, `12_badge`/`14_flower_transforms`/`15_spiral_stroke`/`16_stress_2000`, all unrelated to this task); no file's score dropped; new `82_stroke_pct_pattern_skew` scores 0.99997 |
| `run_adversarial.py` | 116/116 clean, before and after |
| `run_tiles.py` | 50/50 byte-identical |

New test: `tests/svg/82_stroke_pct_pattern_skew.svg` (a `stroke-width="10%"`
rect and a `patternTransform="skewX(15)"` pattern whose content overflows its
tile, the same shape of bug as `text-child.svg`).

Files changed: `LeanSvg/Svg.lean` (`stroke-width` parsing, 4 lines),
`LeanSvg/PatternRender.lean` (`Pat.build`'s tile scale, 2 lines + comment),
`tests/svg/82_stroke_pct_pattern_skew.svg` (new).
