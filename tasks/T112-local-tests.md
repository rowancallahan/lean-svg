# T112 — Audit the 17 failing local tests in tests/svg  (branch `claude/fix-local-tests`)

`python3 tests/run_tests.py` passes 63/80. The failures include
`92_basic_shapes` (64% within-8), `92_css_units` (89%), `99_feoffset_subregion`
(85%), `90_filter_rotate` (85%), `44_turbulence` (73%), `40_feimage`,
`41_text_decoration`, and others (run it to get the list).

For each failing file decide, with images (white-composited) and the usvg
source: (a) our bug, (b) resvg's bug (then check Chromium, and say which is
right), or (c) a test that exercises something deliberately unsupported.
Fix (a) where small. Do not edit the test SVGs to make them pass unless the
SVG itself is invalid; if so, say why. Report a table: file, class, cause,
action.

---

## Round 7 rules (read with the common rules below)

- **Short task, hard timebox: about 2 hours of work.** Fix what is clearly
  ours and bounded; for anything bigger, write down the cause, the fix you
  would make and its size in the report, push, and end. Do not start
  rewrites.
- **No speed work.** Do not optimise or restructure hot paths; Rowan will
  run the speed phase later. A fix must not slow the suite down noticeably
  (`scratchpad`-style timing: `run_corpora.py` wall time within ~5%).
- **Pass criteria** (`tests/criteria.csv`, `docs/DECISIONS.md`): a file's
  reference is resvg where resvg is correct, Chromium where resvg is wrong
  and Chromium is right, otherwise Rowan's verdict. Do not change
  `criteria.csv` or `realworld_verdicts.csv`; if you believe a file's
  reference is wrong, say so in the report with evidence.
- **Behaviour that must not change:** one input file read; at most the PNG
  and (with `--warnings`) `<out>.warnings.txt` written, no-clobber; nothing
  on stdout/stderr; exit codes as in `docs/DECISIONS.md`; no external
  resource ever loaded. `tests/run_adversarial.py` must stay all clean.
- **Real-world corpus vs Chromium:**
  `python3 tests/run_corpora.py --corpus realworld --ref chrome --out /tmp/rw --no-worst`
  (Chromium is preinstalled; `tests/render_chrome.py` renders references).
  When you look at our PNGs, composite them on white first: they are
  transparent, and an image viewer shows transparency as black.
- Fonts: only permissively licensed fonts (OFL, Apache, Bitstream Vera or
  equally permissive), verified upstream, licence text in `LeanSvg/Fonts/`,
  credits in `NOTICE` and README "Licensing and credits". Keep the binary
  under 75 MB (now ~46 MB).

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

## Report

Scored against resvg (pinned to the suite's font dir) and against headless
Chromium at the same width (images white-composited, ours | resvg | Chromium |
diff). Chromium's font set here is DejaVu/WenQuanYi/IPA only (no Noto Sans,
Tinos, Arimo, Mplus, Noto CJK), so it is only a layout check for text files.
`o-r` / `o-c` / `r-c` = fraction of pixels differing by >8 between ours,
resvg and Chromium.

Classes: **a** our bug, **b** resvg wrong (Chromium noted), **c** oracle
cannot represent it (fonts / deliberately different reference).

| file | before | after | class | cause | action |
|---|---|---|---|---|---|
| 106_soft_hyphen | 98.45 | **99.93 PASS** | a | Non-shaped path kerned a character against the default-ignorable after it (U+200B/U+2060), so `zero​width` lost the o/w kern (~0.3 px shift). HarfBuzz skips ignorables when pairing. | **Fixed** (`Text.lean`, kern pair skips following ignorables); new `112_ignorable_kern.svg` |
| 12_badge, 14_flower_transforms, 15_spiral_stroke, 16_stress_2000 | 98.6 / 98.6 / 97.5 / 97.5 | same | a (not small) | Edge anti-aliasing only: 0 px differ by >64 (16: 15 px), within-32 ≥ 99.86. Our AA/stroker is not bit-exact with tiny-skia (hairline path, f32 flattening; see T1). | None. Fix = bit-exact tiny-skia stroke/AA port; large, speed-sensitive (T1 doubled render time). |
| 92_basic_shapes | 64.36 | same | b | usvg ignores CSS basic shapes in `clip-path` (only `url()`), draws unclipped. o-c 0.008. | Reference should be Chromium. |
| 92_css_units | 88.98 | same | b | usvg has no CSS Values 4 units (vw, vmin, ch, cap, lh, rem, ...), so those rects drop. Chromium draws them; residual o-c 0.068 is font-relative units under Chromium's different font. | Reference should be Chromium / Rowan. |
| 99_feoffset_subregion | 84.67 | same | b | resvg does not clip feOffset to its subregion. o-c 0.000. | Reference should be Chromium. |
| 102_invalid_paint_transform | 75.90 | same | b | resvg uses identity for a singular gradient/pattern transform; Chromium paints nothing (DECISIONS, T102). o-c 0.002. | Reference should be Chromium. |
| 90_filter_rotate | 89.26 | same | b | resvg filters rotated elements axis-aligned (DECISIONS, T90). o-c 0.018. | Reference should be Chromium. |
| 44_turbulence | 74.35 | same | b | resvg does not rotate turbulence with the element (T90). The rotated square matches Chromium; the rest is noise-level. | Reference should be Chromium. |
| 40_feimage | 97.46 | same | b | resvg clips the rotated `f3` feImage to a sliver (axis-aligned region, T90); o-c 0.016. Chromium draws that square crisp (it appears to drop the referenced element's own blur); ours keeps the blur, as usvg's model does. | Reference should be Chromium except that square: Rowan's verdict. |
| 101_spotlight_cone | 95.12 | same | b | resvg's hard cone edge; Rowan chose the suite/Skia soft fade (DECISIONS). o-r 0.049, o-c 0.031. | Reference should be the soft edge (Chromium). |
| 102_vertical_text | 97.28 | same | b/c | Intentional T102 choices: rtl vertical run ends at its y (Chromium's placement); x/y list per grapheme (suite PNG; resvg and Chromium go per code point); negative font-size draws nothing (Chromium falls back to 16 px). | Rowan's verdict (already recorded under T102). |
| 101_xml_lang | 95.40 | same | c | Row 3 (`zh-Hans` / `ko`) picks Noto Sans SC / KR by language; resvg ignores `xml:lang` and its font dir has only Mplus 1p for CJK. Chromium here lacks those fonts. | Rowan's verdict. |
| 106_font_families | 90.81 | same | c | The file says so itself: resvg's pinned font dir has none of these families (DejaVu, Tinos, Arimo, Cousine, CMU, STIX). | Needs Chromium with our fonts, or Rowan's verdict. |
| 41_text_decoration | 98.60 | same | c | `font-family="serif"` row: resvg's font dir has no serif match, draws nothing; since T106 we map serif → Tinos and draw it, like Chromium. 99.92 if that row is masked. The SVG comment ("draws nothing") is stale since T106. | Reference should be Chromium for that row. SVG not edited (it is valid). |

Summary: 17 files: 1 real bug fixed (now passes); of the 16 still failing,
4 are our AA mismatch (not small), 9 are resvg
wrong where we follow Chromium or a recorded decision, 3 are oracle font
limits. `criteria.csv` lists all local files as `reference=resvg`; for the
b/c rows above that reference is wrong (evidence: o-c vs o-r numbers). Not
changed, per the rules. `106_soft_hyphen` and `112_ignorable_kern` have no
`criteria.csv` row.

### Verification

- `run_tests.py`: 63/80 → 65/81 (106_soft_hyphen 98.45 → 99.93; new
  112_ignorable_kern 99.85). No other file changed (the change only
  affects text containing default-ignorables; only 106 has any).
- resvg suite, 100 px: 1543 pass before and after, 0 files moved > 0.1.
- resvg suite, 200 px: 1567 pass before and after, 0 files moved > 0.1.
- Real-world vs Chromium: 261/848 pass before and after, no score change;
  wall time 303.9 s → 303.5 s.
- `lake build` clean, no warnings; `check-theorems.sh`: theorems ok;
  `run_adversarial.py` 170/170 clean; `run_tiles.py` 81/81 byte-identical.
