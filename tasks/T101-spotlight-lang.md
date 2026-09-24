# T101 — Spotlight soft cone edge; font choice by `xml:lang`  (branch `claude/fix-spotlight-lang`)

Rowan's decisions (docs/DECISIONS.md, 2026-09-24):

1. **`feSpotLight` cone edge:** follow the suite's reference PNGs, which fade
   the light smoothly at the `limitingConeAngle` edge (Skia's anti-aliasing),
   instead of resvg's hard edge. Files: `filters/feSpotLight/*` (in
   particular `limitingConeAngle-anti-aliasing.svg` and the
   `limitingConeAngle=±30` files). Judge with `run_corpora.py --ref suite`
   on `filters/feSpotLight` and `filters/feDiffuseLighting`/`feSpecularLighting`
   where they use spot lights. Files resvg is rated correct on that stop
   matching resvg because of this are expected; list each with its suite
   score before and after. Integer arithmetic only, as elsewhere.
2. **Font choice by language tag:** when a Han character falls back to an
   embedded CJK font, pick by the nearest `xml:lang`/`lang`: `ja` → Mplus 1p,
   `ko` → Noto Sans KR, otherwise Noto Sans SC (today's behaviour).
   Target: `text/text/xml-lang=ja.svg` (Chromium reference). No new fonts.

Check `tests/score_criteria.py` before/after (Chromium CSV via
`run_corpora.py --ref chrome`). Add `tests/svg/101_*.svg` cases.

---

## Common rules (every lean-svg agent)

### Conduct (Rowan's rules for every agent, read first)

- **One app.** The whole job is making lean-svg good. Work only inside this
  repository's checkout. Anything outside it is a red flag: do not read,
  write or delete files elsewhere except the scratch/tool dirs the setup
  script uses (`~/.elan`, `~/toolchains`, cargo/pip caches, `/tmp`).
- **Network: only what the task needs.** Cloning the resvg source/test suite,
  installing the pinned toolchain and packages, and reading documentation or
  GitHub issues is fine. Nothing else: no SSH, no uploading data anywhere, no
  contacting services the task does not need, no account or credential use.
- **Git: your branch only.** Commit often (small commits make rollback easy)
  and push only to the one branch your task names. No force-push, no pushing
  to `main` or any other branch, no deleting branches, no pull requests
  unless your task says so.
- **No drastic actions.** Editing files in this repo that are committed and
  can be rolled back is fine. Big or irreversible commands are not: no
  `rm -rf` outside your own build/output dirs, no system changes, no killing
  processes you did not start, no changing CI or repo settings unless the
  task says so. If something gets really difficult or seems to need a
  drastic step, stop, write down what you would need and why in your task
  file's report, push that, and end: the integrator will ask Rowan.


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

## Spec implemented

1. **Spotlight cone edge** (`LeanSvg/Filter/Lighting.lean`, `coneFade`): Skia's
   `SkSpotLight::lightColor`. With `limitingConeAngle` set, `c = cos(angle)`,
   `m = -L·S`: `m < c` → black (unchanged); `c ≤ m < c + 0.016` → the light
   factor `m^se` is multiplied by `(m - c) · (1/0.016)`; above that unchanged.
   Same binary32 emulation (`F32`, integer only) as the rest of the file.
   Without `limitingConeAngle` nothing changes.
2. **Font by language tag** (`Svg.langOf`, `Style.lang`, `SpanProps.lang`,
   `Text.assignFonts`, `FontSet.mplus1p/notoSansSC/notoSansKR`): `xml:lang`
   and `lang` are inherited through the style cascade; primary subtag, ASCII
   case-insensitive; `xml:lang=""` resets. When the first still-missing
   character of a chunk is Han (U+3400–4DBF, 4E00–9FFF, F900–FAFF,
   20000–3134F), the tag's font is tried first: `ja` → Mplus 1p,
   `ko` → Noto Sans KR, any other tag → Noto Sans SC. The rest of usvg's
   fallback loop (whole-chunk replacement etc.) is unchanged. Fallback is
   resolved per (base font, tag) pair within a chunk.

## Skipped / decisions taken

- **Untagged Han text keeps today's order (Mplus 1p first), not Noto Sans SC.**
  I tried the literal "no tag → SC": it breaks local `91_fonts` (0.9989 →
  0.9732) and `94_font_speed` (0.9980 → 0.9354), which go pass → fail vs resvg,
  and `text/writing-mode/japanese-with-tb.svg` drops vs the suite PNG
  (97.96 → 95.63). The task also says "(today's behaviour)", so untagged text
  is unchanged. Rowan to confirm; switching it is a one-line change in
  `assignFonts` (`| _ => none` → SC).
- **The Chromium reference can't judge `ja`.** The container's headless
  Chromium has one CJK font, so all three lines of `xml-lang=ja.svg` come out
  in the same (Chinese-style) face. The target only improves where our font
  now matches it (the `zh-HANT` line → SC).
- Chromium also treats `limitingConeAngle` 0 or |angle| > 90 as 90° (Blink
  `fe_lighting.cc`) and so fades near 90° when no cone is given. Not done: the
  task names only the cone edge, and `limitingConeAngle=0.svg` is rated
  resvg-correct.
- `tests/criteria.csv` still judges `limitingConeAngle=±30.svg` against resvg.
  Per the decision they should now be judged against the suite PNG. I left the
  generated criteria file for the integrator/T100 so this diff stays small.
- A CSS declaration `style="lang: ja"` is also accepted, because it goes
  through `applyProp` like `xml:space`. Chromium does not accept it. Harmless.

## Report

Files: `LeanSvg/Filter/Lighting.lean`, `LeanSvg/Text.lean`, `LeanSvg/Svg.lean`,
`LeanSvg/FontSet.lean`, `tests/svg/101_spotlight_cone.svg`,
`tests/svg/101_xml_lang.svg`.

Checks: `lake build` clean, no new warnings; `check-theorems.sh`:
`invariants ok`, `theorems ok`; `run_adversarial.py` 149/149 clean;
`run_tiles.py` 73/73 byte-identical.

**Suite PNG (`--ref suite`, 200 px, whole suite)**: 4 fail → pass, 0 pass → fail.

| file | before | after |
|---|---|---|
| filters/feSpotLight/limitingConeAngle-anti-aliasing.svg | 98.576 | 100.000 |
| filters/feSpotLight/limitingConeAngle=-30.svg | 98.576 | 100.000 |
| filters/feSpotLight/limitingConeAngle=30.svg | 98.576 | 100.000 |
| filters/feSpotLight/complex-transform.svg | 96.751 | 99.104 |
| text/text/xml-lang=ja.svg | 91.038 | 91.362 |

No other file in `filters/feSpotLight`, `feDiffuseLighting` or
`feSpecularLighting` moved (the spot-light files in the last two have no
`limitingConeAngle`).

**vs resvg, 200 px (headline)** 1576 → 1572 pass. These pass → fail, all
expected by the decisions:

| file | before | after | suite before → after |
|---|---|---|---|
| filters/feSpotLight/limitingConeAngle-anti-aliasing.svg | 100.000 | 98.585 | 98.576 → 100.000 |
| filters/feSpotLight/limitingConeAngle=-30.svg | 100.000 | 98.585 | 98.576 → 100.000 |
| filters/feSpotLight/limitingConeAngle=30.svg | 100.000 | 98.585 | 98.576 → 100.000 |
| text/text/xml-lang=ja.svg (criteria: chrome) | 99.895 | 96.365 | 91.038 → 91.362 |

`complex-transform.svg` 55.425 → 55.642. Nothing else moved > 0.1.
Fast (100 px): the same four files pass → fail (100 → 98.68; xml-lang
99.85 → 95.49); nothing else.

**vs Chromium (`--ref chrome`)**: `limitingConeAngle{-anti-aliasing,=30,=-30}`
98.323 → 99.020 (fail → pass); `complex-transform` 95.352 → 98.270;
`xml-lang=ja.svg` 86.062 → 86.520 (still fails; see above). `feImage/recursive-links-2`
and `self-recursive` also moved (−10.1 / +3.0), but our renders are identical
(unchanged vs resvg and vs suite). The Chromium reference varies from run to
run on recursive `feImage`.

**`score_criteria.py`** (resvg 200 px + chrome CSV + local JSON): total pass
1547 → 1545; resvg-rated 1528 → 1526, chrome-rated 19 → 19. The −2 are
`limitingConeAngle=±30.svg`, still rated resvg in `criteria.csv` (see above).
They pass against the suite PNG and Chromium.

**`run_tests.py`** (local, vs resvg): no existing file changes pass/fail;
`49_lighting` 1.0000 → 0.9934 (still passes, its spot light has a 35° cone).
New `101_spotlight_cone` 0.9512 and `101_xml_lang` 0.9540 fail vs resvg by
design (resvg has the hard edge and ignores `xml:lang`). The 62 → 60 pass count
is only these two new files: the baseline rendered them with the old binary.
