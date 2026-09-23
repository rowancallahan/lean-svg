# T94 — make embedded fonts fast on first use  (branch `claude/feat-font-speed`)

After T91 (read its report in `tasks/T91-fonts.md`), fonts are embedded as
base64 string chunks and decoded + parsed on first use in each process.
Every CLI run is a new process, so a Chinese render pays it every time:
Korean ~95 ms, Chinese 160–290 ms, versus ~15–38 ms for Latin. Rowan finds
that too slow and allows the **whole program to grow to 50–75 MB** if that
buys speed.

Goal: a render that uses CJK should cost close to a Latin render. Options to
measure (pick by measurement, not by guess):
- store fonts as raw bytes rather than base64 so nothing is decoded at
  runtime (e.g. `ByteArray` literals or a compile-time generated structure),
  checking Lean compile time and binary size;
- precompute what first use builds (cmap lookup tables, glyph offset index,
  hmtx) at build time so a lookup touches only the glyphs a render needs;
- keep per-glyph lazy decoding so a render with 5 CJK characters parses 5
  glyphs, not the font.
Pure, no runtime IO, no FFI; `render` stays a pure function.

**Ownership** (T93 is adding shaping concurrently in new modules
`Bidi.lean`/`Shape.lean`): you own `LeanSvg/Fonts/*`, `LeanSvg/FontSet.lean`,
the embedding/decoding in `Font.lean`, and `tests/gen_font_module.py`. Keep
`Font.lean`'s public glyph/metric API unchanged so T93's code merges
cleanly.

**Hard requirement:** outputs byte-identical to before for the whole corpus
and `tests/svg` (this is a pure speed change): run `tests/run_tests.py`,
`run_tiles.py`, and the corpus before/after and show zero changed pixels.
Report per-script first-use timings (median of 5, whole process) before and
after, build time, and binary size.

---

## Common rules (every lean-svg agent)


**Branches (Rowan's rule).** Push only to the one branch this task names.
The integrator merges it into `claude/beautiful-brown-nd2o1h` and then
deletes it, so do not create any other branch, tag or pull request. You may
use subagents inside your own session; they must not push anywhere.

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

## Report

### What was slow

Before: 747 M instructions for a 7-character Chinese render (Latin: 42 M),
nearly all of it base64-decoding the whole 10.4 MB Noto Sans SC on first
use. With only `glyf` made lazy (step 1 below, first commit), Chinese was
64 M, of which half was still decoding the other tables (loca/hmtx are
240 KB in SC); Korean (102 M) also spent 43 M in the linear format-12 `cmap`
scan (~9 000 groups per lookup); every text render also decodes all coverage
strings once per process (6 M). Module initialisation costs nothing: Lean 4.34 emits
string literals and literal arrays as static data, so the chunk strings are
read in place from the binary.

### What changed

Raw-byte literals were not tried: the chunk strings are already static data,
so reading only the needed bytes out of them removes the decode cost without
growing the binary or the build, whereas a `ByteArray` literal of 10 MB would
be elaborated element by element.

1. **Lazy tail** (first only `glyf`, then also `loca`/`hmtx`/`vmtx`;
   `tests/gen_font_module.py`, `LeanSvg/Fonts/*`): the
   generator rewrites each font so `loca`, `hmtx`, `vmtx`, `glyf` come last
   (table bytes unchanged, only directory offsets move; asserted per table).
   A module holds `front` (every byte before them) and `tail` (the rest), as
   base64 chunks of 15 000 bytes. `--from-module <Name>` re-emits an existing
   module from the bytes it embeds; all ten were regenerated that way (coverage
   strings byte-identical).
2. **`Font.parseEmbedded`** (`LeanSvg/Font.lean`): decodes only `front` (53 KB
   for SC, 146 KB KR, 176 KB Mplus 1p, 56 KB Noto Sans) and parses it with
   `parseSized` (the old `parse` with the font's full size passed in, so the
   tail tables are found); rejects (`none`) a tail that is not where the
   generator puts it or a length that does not fit the chunk count. New Font
   fields `tailChunks`/`tailChunkBytes`/`tailLen` (defaults: empty, so
   `parse` of a whole file is unchanged). `advance` and `locaOffset` read via
   `Font.byteAt`/`tu16`/`tu32`, and `resolvedContours` via
   `Font.glyphRecord`, which decodes just the glyph's `len` bytes
   (`base64Range`, reading the chunk strings in place with `getUTF8Byte`).
3. **Binary-search `cmap`**: `isCmapSorted` is checked once at parse (every
   segment/group `start ≤ end < next start`); when true, `glyphId` uses
   `glyphIdFormat4Sorted`/`glyphIdFormat12Sorted`, otherwise the old linear
   scan. For a sorted, disjoint table the unique match is the first match, so
   results are identical.
4. `base64DecodeInto` reads chunks in place (no `toUTF8` copy) into one
   buffer sized for all chunks.
5. `FontSet.Entry.bytes` → `Entry.font : Unit → Option Font`; `byModule`
   returns the font as the renderer loads it, so `fontdump --embedded` and
   `check_font.py --via-embedded` test the lazy path. `Text.lean`: one line,
   `Font.parse (e.bytes ())` → `e.font ()`.

Public glyph/metric API (`glyphId`, `advance`, `kern`, `outline`,
`rawContours`, metric fields, `parse`) unchanged. **Note for T93/the
integrator:** for an embedded font, `f.data` now holds every table except
`loca`/`hmtx`/`vmtx`/`glyf`; GSUB/GPOS/GDEF/cmap/kern are in `data` at their
directory offsets as before. Code that reads those four tables must use
`Font.byteAt`/`tu16`/`tu32`/`glyphRecord`, not `f.data`.

Not done: `Text.lean`'s per-process coverage decode (6 M instructions, ~1.5
ms, paid by Latin too) is left as is since it lies outside this task's files.

### Verification

- Byte identity: every resvg-suite file and every `tests/svg` file rendered
  by the old and new binary at natural size and `--width 800`: 3478 renders
  (1739 files × 2), **0 differ** (PNG bytes and exit codes).
- `tests/check_font.py <original subset> --all --via-embedded` for all ten
  modules (every mapped codepoint: glyph id, advance, contours, kerning):
  0 mismatches (2791/2791/2791/8331/30890/23174/424/428/507/858); `--metrics`
  0 mismatches for all ten.
- Corpus (resvg, direct): 100 px 1558/1679 → 1558, 200 px 1583/1679 → 1583;
  0 files moved, 0 pass→fail.
- `run_tests.py`: 60 existing files identical scores; new
  `tests/svg/94_font_speed.svg` (kana/kanji from both ends of Mplus 1p's glyph
  list, full-width punctuation, kerned Latin in both fonts) 99.80% within-8,
  passes (57/61, same 4 old failures).
- `run_adversarial.py` 137/137 clean; `run_tiles.py` 61/61 byte-identical;
  `lake build` no warnings; `check-theorems.sh`: `invariants ok`,
  `theorems ok`.

### Timings (whole process, 200×100 px, median of 5, `font-family="Noto Sans"`)

| sample | before | after |
|---|---:|---:|
| no text (rect) | 14.5 ms | 6.8 ms |
| Latin | 11.3 | 8.4 |
| Cyrillic | 11.9 | 8.4 |
| Japanese (Mplus 1p) | 35.4 | 10.8 |
| Chinese (Noto Sans SC) | 147.0 | 9.1 |
| Korean (Noto Sans KR) | 87.7 | 10.6 |
| Thai | 12.3 | 8.9 |
| Armenian | 11.8 | 8.5 |
| Georgian | 12.5 | 8.8 |
| Ethiopic | 16.4 | 11.5 |
| 120 distinct Chinese characters, 400×150 | 203.4 | 55.7 |

(The "no text" row differs only by timer noise between runs; no font is
touched there.) Instructions (callgrind, same samples), before → after: Latin
42 M → 29 M, Japanese 164 M → 42 M, Korean 476 M → 45 M, Chinese 747 M →
37 M. In the 120-character render the font work (front decode + glyph
records) is ~6% of 504 M instructions; the rest is rasterising and
`Text.glyphCmdsLin`.

### Build time and size

- `lean-svg` binary: 36 785 320 → 36 879 424 bytes (+94 KB: the new code
  and chunk-boundary padding; the embedded fonts are the same bytes).
- Font module compile (`lean -c` + `leanc -O3`), old vs new layout, two runs:
  Noto Sans SC 1.6–1.9 s + 0.35–0.40 s both; KR 0.8–1.2 s + 0.25–0.29 s
  both; Mplus 1p 0.45–0.7 s + 0.2 s both. No measurable change.
