# T98 — Font fallback with a warnings file  (branch `claude/feat-warnings`)

Rowan's decision: when a `font-family` is not available, fall through to
Noto Sans (today some such text, e.g. `text/font-family/source-sans-pro.svg`,
renders blank) **and report it as a warning**. The program then has a third
outcome besides success and failure: success with warnings.

Design (Rowan's words: "only two files are written, the PNG and the warning
file"):
- The pure renderer returns its warnings (bounded list of short messages,
  deduplicated, e.g. `font-family "Source Sans Pro" not available; used Noto
  Sans`) alongside the image.
- The effect layer (`LeanSvg/Effect.lean`, the `Prog` free monad) gets the
  output needed to write them: when there is at least one warning, write
  `<output>.warnings.txt` next to the PNG with the same no-clobber rule as the
  PNG (`.writeNew`; refuse if it exists, checked before anything is written).
  No warnings: no second file. Exit code 0 in both success cases; print a
  one-line note on stderr when a warnings file was written.
- Keep every existing theorem, updated to the new op: the program writes at
  most these two paths, never overwrites, and depends on `[propext]` only
  (`scripts/check-theorems.sh`, `tests/check_invariants.py`, which currently
  expects exactly three effects: update it deliberately and say so).
  Proofs may change to cover the new op; never weaken a statement.
- Scope of warnings for now: missing font family only (design it so other
  skipped features can report later; list candidates in your report).

Measure the font-family files (`text/font-family/*`) against resvg where
rated correct. Add a test for the warnings file (present / absent /
no-clobber) in `tests/`.

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

**Fallback.** A `font-family` that selects no embedded font now draws in Noto
Sans instead of being skipped. This covers an unknown name, a CSS generic, a
suite-only family such as `Source Sans Pro`, an unquoted name that svgtypes
rejects (`Mplus 1p`), and no `font-family` at all (usvg's default is "Times
New Roman"). `Svg.resolveFontFamily` is unchanged. `Style.fontAvailable` now
controls only whether a warning is raised, not whether the text is drawn
(`Svg.textShapes`, both `Text.Ev.text` sites). `Style.fontFamilyRaw` keeps the
value as written, for the message.

**Warnings (pure).** The new `LeanSvg/Warn.lean` holds the messages. `Warn.add`
drops duplicates and keeps at most `maxWarnings` = 32 entries. Each quoted
payload is printable ASCII (other bytes become `?`), cut to 80 bytes. One line
per message:
`font-family "Source Sans Pro" not available; used Noto Sans`.
`textShapes` returns its warnings as a fifth tuple component,
`interpretWith` collects them into `Doc.warnings`, and
`renderWithWarnings : Options → ByteArray → Except String (ByteArray × Array String)`
returns them with the PNG. `render` is now `(·.1) <$> renderWithWarnings`, so
every other caller is unchanged.

**Effect layer (`LeanSvg/Effect.lean`).** `Op` gains `warningsExists` and
`writeWarnings bytes`, so there are **five effects** now, not three.
`tests/check_invariants.py` was updated deliberately to expect exactly
`{readInput, outputExists, warningsExists, writeOutput, writeWarnings}`. The
warnings path is `Prog.warnPath out = out ++ ".warnings.txt"`, e.g.
`a.png.warnings.txt`. `renderProgram` reads the input, checks the PNG path,
then checks the warnings path. If **either** exists it refuses before writing
anything. This includes a render that would have no warnings, so a stale
warnings file never sits next to a fresh PNG. Otherwise it writes the PNG,
then the warnings text only if it is non-empty. It returns whether it wrote
the warnings file. `execIO` uses `.writeNew` (O_EXCL) for both writes.
`Main.lean` exits 0 in both success cases and prints
`lean-svg: warnings written to <path>` on stderr when the file was written.

**Theorems.** All are kept and all depend on `[propext]` only:
- `runFS_frame`: now allows both `out` and `warnPath out` to change (new
  hypothesis `q ≠ warnPath out`).
- `runFS_input_only`: also depends on whether `warnPath out` exists (new
  hypothesis `hwout`). The program can observe that now, so the old
  statement would be false.
- `renderProgram_spec`: the full case split described above.
- `renderProgram_no_clobber`: statement unchanged.
- `renderProgram_error_no_write`: statement unchanged. Its `hout` is now
  unused and is kept as `_hout`.
- `renderProgram_ok_output`: needs `fs (warnPath out) = none` as well, because
  the program now also refuses when that path exists.
- `renderProgram_ok_frame`: needs `q ≠ warnPath out` as well.

New theorems: `warnPath_ne` (proved through the byte list, since the library's
length lemmas bring in `Classical.choice`/`Quot.sound`),
`renderProgram_no_clobber_warnings`, `renderProgram_ok_warnings`,
`renderProgram_ok_no_warnings`, and `renderProgram_never_overwrites` (every
path the program changes was absent before). The changed hypotheses were
needed because the program changed: without them the old statements would be
false. None of these changes is a relaxation made for convenience.

**Harnesses.** `run_tests.py`, `run_corpora.py`, `run_tiles.py` and
`run_sizes.py` also delete `<png>.warnings.txt` before re-rendering to a fixed
path. Without this, no-clobber would make the second run refuse.
`run_adversarial.py` allows `out.png.warnings.txt` as the one extra file.

**Text layout performance (`LeanSvg/Text.lean`).** Default-family text used to
be skipped. Now that it is drawn, `gen/text_1mb.svg` timed out at 120 s. The
cause was an old problem: `Text.layout`'s per-cluster glyph placement compiled
to a closure that captured the run buffers, so every cluster's
`curCmds ++ cmds` copied the whole run. The cost was quadratic in chunk
length: 20k characters took 30 s. That block now runs in its own `Id.run`.
The output is unchanged (no score or tile changed). 20k characters now take
1.7 s and `text_1mb` takes 12.9 s. The diff is mostly re-indentation of about
90 lines.

**Test.** `tests/check_warnings.py` runs the built binary and checks:
- present: the file is written, duplicates are removed, and the stderr note
  is printed;
- absent: no second file and nothing on stderr;
- bounded: 40 distinct families give 32 lines;
- no-clobber: an existing warnings file, or an existing PNG, gives exit 1 and
  nothing is written.

## Skipped, and why

- **No `tests/svg/98_*.svg`.** `run_tests.py` compares against live resvg,
  which draws nothing for a missing family, so a fallback test file would be
  a permanent failure there. The fixtures live inline in
  `tests/check_warnings.py` instead.
- **Warnings from `<pattern>` content text and from nested SVG images**
  (`patternContentShapes`, `Render` line ~633 `interpretWith … nested`) are
  not collected. That text still gets the Noto Sans fallback, but no warning
  is reported for it. Plumbing it through needs a return-type change in
  `patternContentShapes` and in `SvgImage` rendering. Left for a follow-up.
- **The warnings file is not written atomically with the PNG.** The PNG is
  written first. If the exclusive create of the warnings file then fails
  (someone creates it between the check and the write), `execIO` raises, the
  exit code is non-zero, and the PNG already exists. The model does not cover
  this race; it is the same trust boundary `writeOutput` already has.

## Other features that could report later (candidates)

These are all places that skip or substitute today: unsupported filter
primitives (dropped), `feImage` with external hrefs, `<image>` formats that
fail to decode or are refused (budgets), `textPath` in vertical writing mode
(dropped), `text-rendering`, and unsupported CSS properties or selectors.
Others are budgets that truncate silently (`textBudget`, image pixel budget,
`maxLayerDepth` flattening of group layers, `maxClipPaths`), glyphs missing
from every embedded font (`.notdef`), and zoom clamped above 4096×. Each needs
one `Warn.add` at its site plus a way to get the message back to `Doc`.

## Report

Baseline is `65d54da`. Pass = ≥ 99% of pixels within 8, compared against live
resvg 0.48.1 with pinned suite fonts.

| scope | fast 100 px before → after | 200 px before → after |
|---|---|---|
| `text/font-family/` (12) | 10 → 3 | 10 → 3 |
| `text/` (356) | 313 → 303 | 316 → 306 |
| whole suite (1679) | 1543 → 1533 | 1567 → 1557 |

**10 files go from pass to fail at both widths.** All 10 are caused by
Rowan's fallback decision; no other file changed by more than 0.25 points of
within-8.

The 10 files:
- `font-family/{bold-sans-serif, cursive, fantasy, monospace, sans-serif, serif, fallback-1}`
- `writing-mode/{japanese-with-tb, tb-and-punctuation}` and
  `letter-spacing/non-ASCII-character` (all use unquoted `Mplus 1p`, which
  svgtypes rejects)

In every one of them, live resvg draws **nothing** because it finds no font:
`Warning … No match for 'serif' font-family`. The old blank output matched
it; drawing Noto Sans does not. This breaks the common rule "zero pass→fail",
and it follows from the task. The integrator should decide whether those
10 files are re-scored under T100's criteria.

**Against the rated-correct reference.** `results.csv` rates resvg correct
(column `resvg` = 1) on all 12 `text/font-family` files. That rating is for
the suite's own PNGs, which resvg rendered with generic families mapped to
installed fonts. I measured with `--ref suite` over `text/{font-family,
writing-mode,letter-spacing,text,textPath}` (137 files, 200 px), using the old
binary from a worktree and the new one:
- 63 → 63 pass, 0 changes in either direction.
- `text/font-family` fails 9 of 12 both before and after.
- Within-8 moves between −1.9 and +0.9 points per file: fantasy +0.85,
  sans-serif +0.37, the others −0.2 to −1.0. Noto Sans in place of Noto Serif,
  Source Sans Pro, etc. is about as far off in pixels as drawing nothing.

So the fallback does not raise any pixel score. What it adds is visible text
plus a warning instead of a silent blank.

**Other gates.**
- `lake build`: clean, no new warnings.
- `scripts/check-theorems.sh`: `theorems ok`. `SizeBound` was re-proved
  through `renderWithWarnings`, and its statements are unchanged.
- `run_tests.py`: 57/66 → 56/66. Only `41_text_decoration` changed
  (99.58 → 97.97, pass→fail). It uses `font-family="serif"` and now draws
  Noto Sans where resvg draws nothing. This is the same cause as above.
- `run_adversarial.py`: 142/142 clean.
- `run_tiles.py`: 66/66 byte-identical.
- `tests/check_warnings.py`: `warnings ok`.
