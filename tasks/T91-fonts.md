# T91 — broader script coverage with embedded OFL fonts  (branch `claude/feat-fonts`)

Rowan's decision (`docs/DECISIONS.md`): add fonts so non-Latin text renders.
Budget **up to 50 MB total added**, and **only fonts under the same licence
as the current embedded ones (SIL OFL 1.1, e.g. Noto)**. Emoji: not now.

Order:
1. **Cyrillic and Greek** first (Noto Sans covers them; extend the current
   subsets or embed the full Latin/Greek/Cyrillic Noto Sans regular, bold,
   italic). These should reuse the existing glyf parser as is.
2. **Other scripts by reach**: CJK, Devanagari, Arabic, Hebrew, Thai, etc.
   Measure each: file size, glyph format (`glyf` vs `CFF`/`CFF2`: our parser
   reads `glyf` only; prefer `glyf` builds of Noto where they exist),
   and whether it needs shaping (Arabic joining forms, Indic reordering).
   Implement what fits the rules; for scripts that need shaping, embed the
   font and render unshaped only if the output is still recognisably right,
   otherwise document and stop — do not write a shaper in this task.
3. **Font fallback**: when the requested family lacks a glyph, fall back
   through the embedded fonts in a fixed order (usvg does fallback; match
   its rules where they apply).

**Hard requirements:**
- The parser stays total (`LeanSvg/Font.lean`): fuzz every new font file
  like `tests/fuzz_font.py`, and check glyph outlines against fontTools like
  `tests/check_font.py`.
- **Build time and binary size.** Fonts are currently embedded as Lean
  source (`LeanSvg/Fonts/*.lean`). 50 MB of Lean byte-array literals may make
  `lake build` impractically slow or huge. Measure first with one large font;
  if it is bad, find a better embedding that stays pure and has no runtime IO
  (e.g. generating a compact representation, or compile-time inclusion) and
  document the choice. If nothing works within the rules, stop and write up
  the options for Rowan.
- Record each font's name, version, licence and source URL in a `NOTICE`
  or `LeanSvg/Fonts/README.md`, and keep the OFL licence text in the repo.
- Measure against the suite's text directories and the three files in
  `docs/resvg-wrong/R4-text-layout.md` group A (Cyrillic/CJK) before/after.
- No change to the effect layer; `render` stays pure.

---

## Common rules (every lean-svg agent)


**Branches (Rowan's rule).** Push only to the one branch this task names.
The integrator merges it into `claude/beautiful-brown-nd2o1h` and then
deletes it, so do not create any other branch, tag or pull request. You may
use subagents inside your own session for research or parallel work; they
must not push anywhere; you collect their work into your branch.

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

### What was implemented

**Fonts** (all SIL OFL 1.1; names, versions, sources and sizes in
`LeanSvg/Fonts/README.md`; licence texts in `LeanSvg/Fonts/LICENSE-OFL*.txt`;
`NOTICE` and `README.md` updated). Fallback order, as in `LeanSvg/FontSet.lean`:

| # | Module | Scripts | Embedded bytes |
|---|---|---|---:|
| 0–2 | NotoSans, NotoSansBold, NotoSansItalic (now the full cmap, not Latin subsets) | Latin, Greek, Cyrillic | 736,884 |
| 3 | Mplus1p (the test suite's own Japanese font) | kana, JIS kanji, Latin | 1,728,720 |
| 4 | NotoSansSC (wght=400 instance) | Chinese, kana | 10,370,644 |
| 5 | NotoSansKR (wght=400 instance) | Hangul, Hanja | 5,743,856 |
| 6–9 | NotoSansThai, Armenian, Georgian, Ethiopic (wght=400 wdth=100) | those scripts | 489,612 |
| | **Total** (was 96,928) | | **19,069,716** |

All ten are `glyf` fonts; the existing parser reads them unchanged. The
variable Google Fonts builds are pinned to one static instance with
`fontTools.varLib.instancer` (`--instance` in the generator); the parser
ignores `gvar`, and the SC/KR default instance is Thin (wght=100), so
instancing is required, not optional.

**Scripts measured and not embedded** (documented and stopped, per the task):

| Script | Candidate | Format | Needs | Decision |
|---|---|---|---|---|
| Arabic | Amiri (suite), 537 KB | glyf | joining forms (GSUB) + RTL bidi | not embedded: unshaped LTR isolated forms are not recognisably right |
| Hebrew | Noto Sans Hebrew, 113 KB | glyf | RTL bidi | not embedded: reversed word order without bidi (bidi scope is an open question for Rowan) |
| Devanagari | Noto Sans Devanagari (suite), 191 KB | glyf | reordering (`ि`), conjuncts | not embedded: pre-base vowel sign lands after its consonant |
| Emoji | Noto Color Emoji | CBDT | colour bitmaps | not now (Rowan) |
| Japanese/Traditional Chinese | Noto Sans JP 9.6 MB / TC 11.9 MB | glyf (variable) | — | skipped: Mplus 1p and Noto Sans SC already cover kana and most Traditional characters |

Thai, Armenian, Georgian and Ethiopic render recognisably unshaped: Thai
marks have zero advance and outlines placed over the preceding consonant (checked
in the font: e.g. U+0E31 spans x −331…42 with advance 0); stacked tone marks
overlap slightly where GPOS would lower them.

**Embedding (build time, binary size).** Measured first with one large font:
Mplus 1p (1.75 MB) as T25's hex chunks built in 1.1 s (`.olean`) + 0.14 s
(C), so Lean string-literal chunks scale fine. Kept that scheme but switched
the encoding from hex (2× in the binary) to base64 (4/3×):
`Font.base64Decode` (total; stops at the first invalid quad; allocation-free
digit decoding, which cut Hangul first-use cost from ~270 ms to ~95 ms). No
runtime IO; `render` stays pure. Measured after:

| | before | after |
|---|---:|---:|
| font data | 96,928 B | 19,069,716 B |
| `LeanSvg/Fonts/*.lean` | 196 KB | 25.5 MB |
| `lean-svg` binary | 11,173,256 B | 36,785,320 B |
| rebuild of all 10 font modules (olean + C) | — | 3.2 s wall (SC alone: 2.0 s + 0.3 s) |
| `.lake/build` for the fonts | — | 27 MB olean + 50 MB IR/C |

Per render, a font is decoded and parsed only when a character needs it
(coverage strings decide fallback without decoding). Measured whole-process
time at natural size, 3 runs: Latin/Cyrillic 15–38 ms (as before), Thai/
Armenian/Georgian/Ethiopic 15–23 ms, Japanese (Mplus 1p) 40–80 ms, Korean
~95 ms, Chinese (Mplus 1p then SC) 160–290 ms. Decoding only the needed
glyphs of a CJK font would cut that; not done here.

**Font fallback** (`Text.assignFonts`, usvg `shape_text` +
`default_fallback_selector`): per chunk, for each distinct span base font,
the base font keeps every character it maps; for the first missing
character, the first not-yet-tried font in `FontSet` order that maps it is
tried; if it maps every character of the chunk it replaces them all (so
"Tokyo 東京 AVA" is drawn entirely in Mplus 1p, as resvg does), else it fills
what it can and the loop repeats. A character no font maps keeps the base
font's `.notdef`. Kerning applies only between two glyphs that the same
base-font shaping pass took from the same font (a bold tspan inside regular
text still kerns against its neighbours, `text-shaping-across-multiple-tspan-2`).
The glyph's own font gives its outline, advance, vertical centring and metric
box; the span's base font gives baseline and decoration metrics.
usvg's style filter (skip a face only when style, weight *and* stretch all
differ) never excludes anything here, since every face has normal stretch.

**`font-family`** (`Svg.resolveFontFamily`) now returns a `FontSet` index:
any embedded family name selects its font ("Noto Sans" then picks
regular/bold/italic by weight/style as before). A family installed in the
suite's font directory but not embedded (`suiteOnlyFamilies`: Source Sans
Pro, Amiri, Noto Serif, …) ends the search with "no drawable font", as
before for Source Sans Pro. New: an unquoted name with a word starting with
a digit (`font-family="Mplus 1p"`) is rejected outright, matching svgtypes'
parse error → usvg's Times New Roman default (the suite's
`japanese-with-tb.svg` etc. depend on this; resvg logs "Failed to parse
font-family value").

**Parser hardening** (`LeanSvg/Font.lean`; the parser must stay total and
bounded). Fuzzing Noto Sans KR found a mutant (head table offset → 0) that ran
out the 20 s timeout: with `endPtsOfContours` going back down, the
contour-grouping loop re-copied up to 10 000 points per contour for 25 603
contours. Fixes: `parseSimpleGlyph` rejects non-increasing end points (the spec
requires strictly increasing; no embedded glyph changes, `check_font --all`
still 0 mismatches), and composite resolution now threads a shared
component budget (`compositeBudget` = 256 visits; the most any embedded font
needs is 21) plus a 40 000-point cap, because fuel 8 × 64 components per level
was 64^8 calls. The size cap in `Font.parse` rose from 8 MiB to 16 MiB for
Noto Sans SC (10.4 MB).

### Verification

- `lake build`: no errors, no warnings. `bash scripts/check-theorems.sh`:
  `invariants ok`, `theorems ok`.
- `tests/check_font.py --all --via-embedded` for all ten modules (every cmap
  codepoint: glyph id, advance, contours, kerning): 0 mismatches
  (2791/2791/2791/8331/30890/23174/424/428/507/858 glyphs), `--metrics` 0
  mismatches for all ten; the original `NotoSans-Regular.ttf --all` also 0.
- `tests/fuzz_font.py --iters 1000 --seed 91` on each of the ten subsets with
  a probe string in its script: 0 violations (after the fix above; 1 timeout
  on Noto Sans KR before it).
- `python3 tests/run_tests.py`: 59 existing files byte-for-byte the same
  scores; new `tests/svg/91_fonts.svg` (Cyrillic, bold Greek, italic
  Cyrillic, kana/kanji fallback, mixed chunk, quoted `'Mplus 1p'`, combining
  marks) 99.862% within-8, passes (56/60, the same 4 old failures).
- `python3 tests/run_adversarial.py`: 136/136 clean. `python3 tests/run_tiles.py`:
  60/60 byte-identical.

### Corpus (resvg suite, direct route)

| | 100 px pass | 200 px pass |
|---|---:|---:|
| before | 1553 / 1679 | 1578 / 1679 |
| after | 1558 / 1679 | 1583 / 1679 |
| `text/*` | 300 → 305 / 356 | 304 → 309 / 356 |

Zero pass→fail at either width. Every file outside the list below keeps its
exact score (all Latin text is byte-identical). At 200 px:

| file | within-8 before | after | |
|---|---:|---:|---|
| text/text/xml-lang=ja.svg | 85.80% | 99.90% | fail → pass |
| text/text/escaped-text-4.svg | 97.67% | 100.00% | fail → pass |
| text/text/complex-graphemes.svg | 98.08% | 99.59% | fail → pass |
| text/text/complex-graphemes-and-coordinates-list.svg | 98.09% | 99.99% | fail → pass |
| text/text/complex-grapheme-split-by-tspan.svg | 96.16% | 99.19% | fail → pass |
| text/text/rotate-with-multiple-values-and-complex-text.svg | 92.71% | 97.74% | fail |
| text/text/zalgo.svg | 93.69% | 96.05% | fail |
| text/alignment-baseline/hanging-on-vertical.svg | 97.83% | 98.53% | fail |
| text/writing-mode/mixed-languages-with-tb.svg | 97.98% | 97.18% | fail |
| text/writing-mode/tb-with-rotate.svg | 97.83% | 96.74% | fail |

The two drops: `font-family="'Mplus 1p', Amiri"` now resolves to the embedded
Mplus 1p, so the Japanese and Latin are drawn (before, nothing was), but the
Arabic part needs Amiri, which is not embedded, so it stays blank and the
`text-anchor="middle"` chunk is narrower than resvg's. The remaining text
failures here are combining-mark positioning (GPOS mark attachment) and
upright CJK in vertical text (`unicode_vo`), both outside this task.

`docs/resvg-wrong/R4-text-layout.md` group A: `xml-lang=ja.svg` and
`complex-graphemes-and-coordinates-list.svg` now pass (the latter's second
`y` still applies to the combining breve, as resvg's does); the three emoji
files are unchanged (emoji: not now).

### Files

`LeanSvg/FontSet.lean` (new: the font list, family lookup), `LeanSvg/Text.lean`
(`baseFont`, `assignFonts`, per-character font in layout), `LeanSvg/Svg.lean`
(`resolveFontFamily` → index, `Style.fontFamily`, `SpanProps.family`),
`LeanSvg/Font.lean` (base64 + coverage decoding, parser hardening, 16 MiB
cap), `LeanSvg/Fonts/*` (regenerated/new modules, README, licences),
`FontDump.lean` (`--embedded` any module), `tests/gen_font_module.py`
(base64, coverage, `--instance`, `--header`), `tests/svg/91_fonts.svg`,
`NOTICE`, `README.md`, `ROADMAP.md`.

### Open

- CJK first-use cost (100–300 ms per render) could drop by decoding only the
  glyphs a document uses instead of the whole font.
- Arabic/Hebrew/Devanagari need a shaper and bidi; the fonts are small
  (under 0.6 MB each) once that exists.
- `lean-svg`'s binary is now 36.8 MB; if that matters more than script
  reach, Noto Sans SC (13.8 MB of it) is the one to reconsider.
