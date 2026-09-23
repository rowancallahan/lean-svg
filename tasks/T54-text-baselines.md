# T54 — text baselines  (branch `claude/feat-text-baselines`)

Implement `dominant-baseline`, `alignment-baseline` and `baseline-shift`
(`sub`, `super`, lengths, percentages, nested tspans accumulating) exactly as
usvg 0.48.1 does (`crates/usvg/src/text/layout.rs`, search `baseline`).
The font metrics needed (ascender, descender, x-height, cap height, ideographic
etc. — whatever usvg reads from the font, typically OS/2 and hhea tables,
with its fallbacks) must come from `LeanSvg/Font.lean`; extend the parser
there totally and add a check to `tests/check_font.py` against fontTools.
Target: `text/dominant-baseline` (18/21), `text/alignment-baseline` (16/19),
`text/baseline-shift` (14/22). Code in `LeanSvg/Text.lean` or a new module.

Another agent (T55) is working on other text features in `Text.lean`
concurrently; keep your change focused on baseline offsets so merges are easy.

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

---

## What was implemented

`crates/usvg/src/text/layout.rs`'s `resolve_baseline` / `dominant_baseline_
shift` / `alignment_baseline_shift` / `resolve_baseline_shift`, and
`crates/usvg/src/parser/text.rs`'s `convert_baseline_shift`, ported in full:

- **`LeanSvg/Font.lean`** (extended, not rewritten): a minimal `OS/2` table
  scan (tag `0x4F532F32`), plus `skrifa::Metrics::new`'s line-metrics
  algorithm (the one usvg actually gets `ResolvedFont.ascent`/`descent`
  from) — `OS/2.sTypoAscender/Descender/LineGap` when `fsSelection`'s
  `USE_TYPO_METRICS` bit (`0x0080`) is set, else `hhea.ascender/descender/
  lineGap`, with `OS/2`'s typo-then-Windows pair as the fallback for the
  (essentially never hit by a real font) case where `hhea`'s own pair is
  `(0, 0)`. Also: `xHeight` (`OS/2.sxHeight`, version ≥ 2, else `round((ascent
  - descent) * 0.45)`, Firefox's fallback, which usvg copies), `capHeight`
  (`OS/2.sCapHeight`, version ≥ 2, else `0` — unused by any formula here,
  kept for the oracle and future use), and `subscriptOffset`/
  `superscriptOffset` (`OS/2.ySubscriptYOffset`/`ySuperscriptYOffset`, or
  `unitsPerEm * 5` / `round(unitsPerEm * 2.5)` with no `OS/2` table at all —
  usvg's generic Inkscape/librsvg-derived fallback). A new `Font.
  unitsToFx16` scales a font-units metric by `size/unitsPerEm` into 16.16
  fixed point, the precision `Text.layout` already carries pen positions in.
  All of it degrades to the pre-existing `hhea`-only numbers when `OS/2` is
  missing or truncated — no new rejection path, matching the "a feature
  that is not supported should degrade, not error" invariant.

- **`LeanSvg/Baseline.lean`** (new module, deliberately not more of
  `Text.lean`, which T55 also touches concurrently): one `AlignmentBaseline`
  type serving both `dominant-baseline` and `alignment-baseline` (usvg
  itself funnels every `DominantBaseline` variant into the
  `AlignmentBaseline` formula), `AlignmentBaseline.shift16` (the
  `alignment_baseline_shift` formula, 16.16), and `resolveBaseline16`
  (`resolve_baseline`, combining it with `baseline-shift`'s accumulated
  length/`sub`/`super` contributions).

- **`LeanSvg/Text.lean`**: `SpanProps` gained `dominantBaseline`/
  `alignmentBaseline`/`baselineShiftPx`/`baselineShiftSub`/
  `baselineShiftSuper`; `layout`'s glyph-placement loop calls
  `resolveBaseline16` once per glyph and adds the result to the pen `y`
  *only* for that glyph's own outline — it does not feed back into `x`/`y`/
  `lastX`/`lastY`, matching usvg's `span_ts.pre_translate(0, shift)` being a
  rendering-only transform layered on top of already-computed advances.

- **`LeanSvg/Svg.lean`**: two new ordinary CSS-inherited `Style` fields,
  `dominantBaseline`/`alignmentBaseline` (`applyProp` cases; `dominant-
  baseline="no-change"`, and any other unrecognised token, is a no-op —
  see below). `baseline-shift` is deliberately **not** a `Style` field or an
  `applyProp` case: `textShapes` keeps a small parallel stack, `bsStack`
  (`Fx × Nat × Nat` — accumulated length, `sub` count, `super` count),
  seeded at `(0, 0, 0)` for the `<text>` element itself and pushed to only
  by a `tspan`'s (or `a`'s) own `baseline-shift` attribute
  (`baselineShiftDelta`, a new helper next to `spanPropsOf`). This is what
  makes `baseline-shift` reset on every element and accumulate only through
  explicit `tspan` nesting, instead of inheriting like every other property
  here.

### The one usvg quirk this task did not fully reproduce

`dominant-baseline`/`alignment-baseline` are non-inheritable `AId`s in usvg:
`SvgNode::find_attribute` on one only checks the node's own attribute or its
*direct* parent's, not the whole ancestor chain (`no-change`'s special case
walks one *further* level on top of that). This renderer instead treats
them as ordinary always-inherited `Style` fields (nearest ancestor's own
value wins, full chain) — much simpler, and `no-change` falls out for free
as "don't override" (`applyProp`'s catch-all). The two models coincide on
every file actually in `tests/text/dominant-baseline` and `tests/text/
alignment-baseline` (each only ever sets the property on a run's own
element or its immediate parent), so this did not cost a single test, but a
pathological document (value set three ancestor levels up, with nothing on
the levels in between) would render differently than real usvg. Documented
rather than fixed, given the effort/benefit here.

### `baseline-shift="inherit"`

Falls to `baselineShiftDelta`'s catch-all (a not-a-number, not-`sub`,
not-`super` token → contributes nothing), which happens to be exactly
right: usvg's own `convert_baseline_shift` treats any string that is not
literally `"sub"`/`"super"` — `"inherit"` included — as `BaselineShift::
Baseline`, a no-op contribution. `tests/text/baseline-shift/inheritance-3.svg`
and `nested-with-baseline-{1,2}.svg` pin this down; no special case needed.

### Skipped

- Vertical writing mode and `textPath` interaction with baselines (`hanging-
  on-vertical.svg`, `middle-on-textPath.svg`, `two-textPath-with-middle-on-
  first.svg`): out of scope — `writing-mode`/`textPath` are not implemented
  at all yet (T50/T56).
- `text/dominant-baseline/use-script.svg` and `hanging.svg` (which is also
  `font-family="Noto Sans Devanagari"`, not embedded): fail on the missing
  glyphs, not the baseline math — `use-script` itself maps to `auto`
  (unsupported, matching usvg's own comment "UB").
- Composite-glyph point-matching args and `GSUB`/variable-font `MVAR`
  deltas remain out of `Font.lean`'s scope (pre-existing, unrelated to this
  task); the embedded Noto Sans subsets are static (non-variable) fonts, so
  `MVAR` never applies to them regardless.

## Report

Baseline (before this task, `git stash` back to the unmodified tree),
`python3 tests/run_corpora.py --fast --corpus resvg --route direct --out
/tmp/base --no-worst`: 835/1679 (49.7%) pass at width 100. `python3
tests/run_tests.py`: 23/27 gallery files pass (the 4 failures are
pre-existing, unrelated to text).

Target directories, before → after (`--dir text/<name>`, same harness):

| directory | before | after | target |
|---|---|---|---|
| `text/dominant-baseline` | 3/21 (14%) | **19/21 (90%)** | 18/21 |
| `text/alignment-baseline` | 3/19 (16%) | **16/19 (84%)** | 16/19 |
| `text/baseline-shift` | 8/22 (36%) | **22/22 (100%)** | 14/22 |

All three targets met or exceeded. Remaining `dominant-baseline`/
`alignment-baseline` failures are the out-of-scope ones listed above
(vertical writing mode, `textPath`, an unembedded font) — every failure
*this task* could plausibly fix is fixed.

Full corpus, before → after (`--compare` against the pre-change baseline
CSV): **835 → 878 pass (+43), 0 newly failing**. `python3
tests/run_tests.py`: 24/28 (added `tests/svg/33_baselines.svg`, itself
99.88% exact / 100% within-32; the other 4 failures are the same
pre-existing, unrelated ones, at identical scores). `python3
tests/run_adversarial.py`: 62/62 clean. `python3 tests/run_tiles.py`:
28/28 byte-identical. `bash scripts/check-theorems.sh`: `theorems ok`
(unchanged axiom lists). `lake build`: no errors, no new warnings.

`tests/check_font.py --metrics`, against every `.ttf` in `tests/corpora/
resvg-test-suite/fonts/` (17 files) and the three embedded Noto Sans
subsets (`--embedded NAME`, matching their un-subsetted source `.ttf`'s
metrics exactly, since subsetting does not touch `head`/`hhea`/`OS/2`):
**0 mismatches** on every font whose outlines `Font.parse` already accepts
(16/17 — `NotoColorEmoji.ttf` is a colour/bitmap font `Font.parse` already
rejects as not `glyf`-based TrueType, unrelated to this task).
