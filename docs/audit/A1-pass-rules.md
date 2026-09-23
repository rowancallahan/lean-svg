# A1 — audit: what counts as a pass

Sources: `linebender/resvg` @ `v0.48.1` (tag, commit `68b14c4c`), cloned to a
scratch dir per the task's rules; `linebender/resvg-test-suite` @ the commit
already vendored at `tests/corpora/resvg-test-suite` (`d8e06433`, 2024-10-29,
untagged — the suite has no version tags, `cloud-setup.sh` just clones
default-branch HEAD). Everything below is measured against our real
`tests/svg/*.svg` and `tests/corpora/resvg-test-suite`, resvg/usvg 0.48.1 as
installed by `cloud-setup.sh`, `.lake/build/bin/lean-svg` from a clean
`lake build` on this branch.

## TL;DR

- resvg's own CI is a **bit-almost-exact regression test against its own
  previous output**, not a correctness test against an independent oracle.
  It renders at width 300, compares to PNGs checked into the `resvg` repo
  itself (not `resvg-test-suite`), and requires **zero pixels** to differ by
  more than 1 level per channel. It is closer to "did anything change" than
  "is this correct".
- `resvg-test-suite`'s per-test PNG (used by `tools/vdiff` as the "Reference"
  backend a human compares everything else against) is, empirically, **also
  resvg's own rendering**, not an independent ground truth, despite the
  suite's README saying "this is how the SVG files should be rendered". Live
  resvg 0.48.1 reproduces it almost exactly (median within-8 99.87%) for
  files the suite's own `results.csv` already calls "resvg correct" — that's
  the signature of a shared origin, not of two independent implementations
  agreeing.
- Our tolerance (8 levels / 99% of pixels) is **much looser** than resvg's
  own bar. Tightening to resvg's own bar (tol 1, 100%) on the exact same
  renders drops our pass rate on the resvg corpus from 91.8% to 56.5%. That
  comparison isn't apples-to-apples either (see §4), but the direction and
  size of the gap is real and worth knowing.
- Scoring resvg-correct files against the suite's checked-in PNG instead of
  live resvg (implemented as `--ref suite`, §3) does **not** produce a
  usable number at the widths we actually test (100/200 px): the suite ships
  one fixed-resolution PNG per file (mostly 500×500) and resampling it down
  swamps the signal — pass rate swings from 7.5% at width 100 to 0.2% at
  width 200 on the *same 1679 files*, purely from resampling artifacts. At
  the suite's own native resolution (no resampling) it's usable and gives
  real information (§2), but that's not a width our harness renders at.
- Recommendation: **keep live resvg as the default reference.** `--ref
  suite` is now available for targeted, native-resolution spot checks (e.g.
  "did I just regress vs. what this test intended, independent of the
  current resvg build") but should not replace the default and should never
  be read at non-native widths.
- One real gap, not previously surfaced anywhere in our reports: our
  headline "N% pass" already means "N% match live resvg", including on the
  96 files (of 1679) the suite's own human review calls "resvg known wrong".
  Matching those is copying a bug, not correctness. `tests/score_known.py`
  exists to split this out but isn't part of the default `run_corpora.py`
  summary — see §5.

---

## 1. How resvg's own test harness decides pass/fail

`crates/resvg/tests/integration/main.rs` (function `render_inner`,
`get_diff`, `is_pix_diff`) plus `crates/resvg/tests/gen-tests.py`, which
generates `crates/resvg/tests/integration/render.rs`: one `#[test]` per SVG
file (1721 of them under `crates/resvg/tests/tests/`, six excluded via an
`IGNORE` list — timeouts, invalid-size files, one SIMD-nondeterministic
gradient test), each body exactly:

```rust
#[test] fn shapes_rect_ex_values() { assert_eq!(render("tests/shapes/rect/ex-values"), 0); }
```

`render()` → `render_inner(name, TestMode::Normal)`:

- **Width.** `size = tree.size().to_int_size().scale_to_width(IMAGE_SIZE)`
  with `const IMAGE_SIZE: u32 = 300`. Every "Normal"-mode test renders at
  **300 px**, regardless of the SVG's own viewBox (all suite files use a
  fixed 200×200 viewBox, so this is always a 1.5× scale-up). Two other
  modes exist and are used by a handful of `extra/*` tests: `Node` (render
  one element at its own bounding-box size, no fixed width) and `Extra(scale)`
  (render at an explicit scale factor, e.g. `render_extra_with_scale(name,
  4.0)` for antialiasing-at-different-scales tests). The vast majority of
  tests use `Normal` / 300 px.
- **Reference image.** `tests/{name}.png` — a path *inside the `resvg` repo
  itself* (`crates/resvg/tests/tests/**/*.png`), **not**
  `resvg-test-suite`'s PNGs. `crates/resvg/tests/README.md` says this
  explicitly:

  > `resvg-test-suite` is the source of truth... `resvg/tests/svg` directory
  > contains the exact copy of `resvg-test-suite/svg`... The major
  > difference is `png` directories. `resvg-test-suite/png` contains
  > reference image. This is how the SVG files should be rendered. While
  > `resvg/tests/png` contains PNGs rendered by the resvg itself and used
  > only for regression testing.

  So by resvg's own documentation, its CI is explicitly a **regression**
  test (did resvg's output change since these PNGs were last regenerated
  with `MAKE_REF=1 cargo test`), and the suite's PNGs are a separate,
  supposedly-more-authoritative thing that resvg's CI does not use at all.
- **Comparison.** `get_diff` walks every pixel; `is_pix_diff` with
  `DIFF_THRESHOLD: u8 = 1`:
  ```rust
  if pixel1.a == 0 && pixel2.a == 0 { return false; }   // both fully transparent: always equal
  different |= pixel1.r.abs_diff(pixel2.r) > threshold;  // ditto g, b, a
  ```
  i.e. a pixel counts as different if **any** channel (R, G, B, or A) differs
  by more than 1 level (diff ≥ 2), except both-fully-transparent pixels are
  always treated as equal regardless of their RGB (relevant because
  `demultiply_alpha` divides by alpha to undo premultiplication, so a=0
  pixels get whatever `0.0/0.0` rounds to, which isn't guaranteed
  consistent across implementations — the special case papers over that).
  `assert_eq!(render(name), 0)` then requires the total count of differing
  pixels to be **exactly zero**. There is no percentage tolerance at all:
  one pixel over the line and the test fails.
- **What actually runs in CI:** `.github/workflows/main.yml` runs `cargo
  test --all --release`, i.e. exactly these tests, nothing looser.

Net effect: resvg's CI answers "did this platform/toolchain/compiler
reproduce this exact renderer's own bytes from last time, at 300 px, to
within ±1 level of channel noise" — a **regression** oracle using resvg
itself as its own ground truth, not a correctness oracle using
`resvg-test-suite`'s PNGs (which it never reads).

## 2. What `results.csv` means, and how it was produced

`resvg-test-suite/README.md`: `results.csv` — "results of manual testing via
`tools/vdiff` of the resvg test suite". `tools/vdiff` is a Qt GUI
(`tools/vdiff/src/*.cpp`) that renders every test SVG through nine
backends — `Reference, Chrome, Firefox, Safari, Resvg, Batik, Inkscape,
Librsvg, SvgNet, QtSvg` (`tests.h`) — side by side, and a human clicks a
pass/fail/crashed verdict per backend per test, which is what's stored in
`results.csv`.

`Render::renderReference` (`tools/vdiff/src/render.cpp:80`):

```cpp
QImage Render::renderReference(const RenderData &data)
{
    const QFileInfo fi(data.imgPath);
    const QString path = fi.absolutePath() + "/" + fi.completeBaseName() + ".png";
    Q_ASSERT(QFile(path).exists());
    ...
    QImage img(path);
    if (img.size() != targetSize) img = img.scaled(targetSize, ...);
    return img.convertToFormat(QImage::Format_ARGB32);
}
```

The "Reference" backend a human compares everything else against is simply
**the checked-in PNG next to each test's SVG** (`tests/<path>.png`), loaded
from disk — nothing is rendered for it. That PNG is what the suite ships as
"how the file should look", and it's what our `--ref suite` (§3) uses.

**Where did that PNG come from?** `git blame`/`git log --follow` on a sample
file (`filters/enable-background/accumulate.png`, added in commit
`f027973`, "Added new 'enable-background' attribute tests", by
`razrfalcon@gmail.com` — resvg's own author) doesn't say what tool produced
it; there's no generator script in the suite (`check.py` only lints SVG
style rules, `stats.py` only builds the pass-rate chart). Reizner
(RazrFalcon) both wrote resvg and maintains this suite, and the workflow
`tools/README.md` describes is: render every backend, eyeball them next to
whichever one looks most spec-correct, pick/adjust a reference PNG, then use
`vdiff` to mark each backend Passed/Failed/Crashed against it. Nothing there
*guarantees* the reference PNG is resvg's own output rather than an
independently touched-up image — but the measurement below says it
overwhelmingly is:

**Measurement.** For every file in `resvg-test-suite/tests/` with a rating
in `results.csv`'s `resvg` column, render live resvg 0.48.1 at the suite
PNG's own native resolution (`-w <suite PNG width>`, so **no resampling** on
either side) and score it against that PNG with our metric (tol 8,
threshold 99%):

| `results.csv` `resvg` rating | n | live resvg passes (≥99%@tol8) | median within-8 |
|---|---:|---:|---:|
| `1` — resvg correct | 1520 | 1209 (79.5%) | 99.873% |
| `2` — resvg known wrong | 95 | 12 (12.6%) | 88.250% |
| `0` — unrated | 61 | 5 (8.2%) | 72.685% |

(1676 of 1679 files scored; 3 dropped for a missing/unreadable render or
title mismatch between the CSV and the file tree.)

Two things follow from this table:

1. **The suite PNGs are resvg's own historical renders, not an independent
   oracle.** A median within-8 of 99.87% on the "resvg correct" bucket, with
   four out of five such files still clearing our fairly loose 99%/tol-8 bar
   at *native resolution with zero resampling*, is what you get when the
   same renderer produced both images at different points in time — an
   independent implementation (a different browser engine, say) essentially
   never lands that close by chance across 1520 files. The 20.5% of
   "resvg correct" files that *don't* clear 99% are best read as version
   drift (font hinting, antialiasing, gradient math tweaks) across the many
   resvg releases between when each PNG was captured and 0.48.1 — not as
   1209 genuine correctness confirmations and 311 correctness regressions.
2. **The suite PNG is a stale target for "known wrong" and "unrated"
   files.** Only 12.6% / 8.2% of those match live resvg even at native
   resolution — meaning current resvg mostly doesn't reproduce its own old
   (flagged-wrong, or never-rated) answer any more either. Scoring lean-svg
   against the suite PNG for these files wouldn't be "scoring against
   ground truth" or "scoring against resvg" — it'd be scoring against a
   snapshot that even resvg itself has moved away from, in an unknown
   direction (could be a fix, could be a different bug).

## 3. `--ref suite`: implemented, and what changes

Added `--ref {resvg,suite}` to `tests/run_corpora.py` (default `resvg`,
unchanged behaviour). `--ref suite` scores against
`<svg>.with_suffix(".png")` — the suite's own checked-in PNG — instead of
live resvg. Since that PNG is a single fixed resolution per file (1657 of
1679 are 500×500, 20 are 500×250, 2 are 400×400 — 2.5× and 2× the tests'
fixed 200×200 viewBox respectively), it's resampled with `PIL.Image.LANCZOS`
to whatever `--width` the run uses. Only the `resvg` corpus has these PNGs;
`--ref suite` drops `simple-icons`/`feather` from the run with a warning.
Output CSVs get a `_suite` suffix (`resvg_direct_suite.csv`) so they never
clobber the default-ref CSVs, and `--ref` defaults to `resvg` everywhere, so
**default behaviour (`run_tests.py`, and `run_corpora.py` without `--ref`)
is byte-for-byte unchanged.**

Full `resvg` corpus (1679 files), both routes, `tol 8` / `threshold 0.99`:

| width | ref | route | pass | pass% (all) | pass% (rendered) |
|---|---|---|---:|---:|---:|
| 100 | resvg (default) | direct | 1521 | 90.6% | 91.0% |
| 100 | resvg (default) | usvg | 1238 | 73.7% | 73.9% |
| 100 | suite | direct | 126 | 7.5% | 7.5% |
| 100 | suite | usvg | 124 | 7.4% | 7.4% |
| 200 | resvg (default) | direct | 1542 | 91.8% | 92.2% |
| 200 | resvg (default) | usvg | 1266 | 75.4% | 75.5% |
| 200 | suite | direct | 4 | 0.2% | 0.2% |
| 200 | suite | usvg | 4 | 0.2% | 0.2% |

The suite-ref numbers are not a fidelity signal at these widths — they're a
resampling artifact. Isolated check, one file
(`shapes/rect/ex-values.svg`, an ordinary passing file under the default
ref):

```
suite PNG (500x500, native) vs. live resvg -w 500 (no resampling):  within-8 99.8%
suite PNG resampled to 200x200 (LANCZOS)  vs. live resvg -w 200:    within-8 92.6%
```

Same file, same renderer, same SVG — comparing at native resolution vs.
comparing after resampling the reference costs 7 points of within-8 on its
own, before lean-svg is even involved. And the corpus-wide effect is worse
than a fixed penalty: pass rate at width 100 (7.5%) and width 200 (0.2%) for
the *same 1679 files* differ by 35×, because 500→200 is a non-integer
(2.5×) downscale ratio that produces different resampling-phase artifacts
per file than 500→100's clean 5× reduction, and most files' true within-8
sits close enough to the 99% line that resampling noise alone decides which
side they land on. `--ref suite` is only a meaningful comparison at (or very
near) each file's native resolution, which §2's measurement uses and this
option, run at an arbitrary `--width`, does not.

**Recommendation:** don't switch the default. Live resvg remains the right
reference for "does lean-svg match resvg 0.48.1", which is the stated spec
target (`tasks/README.md`: "match resvg/usvg 0.48.1"), and matching a
frequently-stale historical snapshot instead would trade a well-defined
target for an undefined one. `--ref suite` stays available for the narrow
case it's actually good for: a manual, native-resolution spot check on a
specific file (`--width <that file's PNG width>`) when you want to know
whether a divergence is "we disagree with current resvg" or "we and current
resvg both disagree with what this test originally intended" — cross-check
against `results.csv`'s rating first, since for `2`/`0` files that intent
is itself in question (§2).

## 4. Is our tolerance stricter or looser than resvg's?

Much looser, but the two bars measure different things (regression vs.
cross-implementation match) so "how much looser" is informative, not a
verdict on us. Sensitivity table, `resvg` corpus, direct route, width 200,
live-resvg reference (default), 1679 files (1672 rendered, 4 unsupported,
3 not attempted at this route... totals below use "of 1679"):

| tol (levels) | threshold | pass | pass% (all) | Δ vs. our default |
|---:|---:|---:|---:|---:|
| 1 | 99% | 1487 | 88.6% | −3.2 pt |
| 2 | 99% | 1530 | 91.1% | −0.7 pt |
| 4 | 99% | 1539 | 91.7% | −0.1 pt |
| **8** | **99%** | **1542** | **91.8%** | **(our default)** |
| 16 | 99% | 1560 | 92.9% | +1.1 pt |
| 32 | 99% | 1562 | 93.0% | +1.2 pt |
| 8 | 90% | 1634 | 97.3% | +5.5 pt |
| 8 | 95% | 1619 | 96.4% | +4.6 pt |
| **8** | **99%** | **1542** | **91.8%** | **(our default)** |
| 8 | 99.9% | 1433 | 85.3% | −6.5 pt |
| 8 | 100% | 1048 | 62.4% | −29.4 pt |
| 1 | 100% (resvg's own bar) | 949 | 56.5% | −35.3 pt |

Reading it: our pass count is fairly insensitive to the *tolerance level*
(1→32 only moves the needle 4.4 points — most disagreements are either tiny
antialiasing noise well under tol 1, or large enough that no reasonable tol
saves them) and highly sensitive to the *threshold*, especially near 100%
(99%→100% costs 29 points, because at width 200 almost every file has a
handful of stray edge pixels somewhere and "zero pixels may differ" is a
fundamentally different, much harsher bar than "at most 1% of pixels may
differ"). Applying resvg's literal bar (tol 1, 100%) to our renders against
live resvg drops us to 56.5% — but remember resvg's own 0% figure on this
axis is "0 differing pixels between two renders of the same code" (a
regression test), not "0 differing pixels between two independent
renderers" (which is what we're measuring here); no independent renderer
should be expected to clear that bar against resvg, so 56.5% isn't a
finding about lean-svg's quality so much as a demonstration that resvg's
own bar is not designed to be applied cross-implementation at all.

## 5. Places this could be inflating (or obscuring) the numbers

- **Known-resvg-bugs count as passes, and this isn't visible in the default
  report.** 96 of 1679 resvg-test-suite files are rated `resvg known wrong`
  in `results.csv`; matching resvg on those means reproducing a bug, not
  correctness. `tests/score_known.py` already exists to split
  correct/known-wrong/unrated pass rates apart, but it's a separate script
  you have to remember to run — `run_corpora.py`'s own `summary.md` reports
  one blended pass rate that silently includes those 96 files as ordinary
  passes/fails. Suggest folding `score_known.py`'s breakdown into
  `summary.md`'s resvg-corpus section so the headline number always comes
  with its correct/known-wrong/unrated split next to it, instead of needing
  a second script run to notice.
- **Two routes, one headline risk.** `direct` (91.8% at width 200) and
  `usvg` (75.4%) differ by 16 points; anyone quoting "our resvg-suite pass
  rate" without saying which route is already picking the flattering one.
  Not a bug in the harness — both numbers are reported — but worth being
  explicit about in anything that repeats a single "N%" figure.
- **`pass% (rendered)` vs. `pass% (all)`.** Currently only 4-7 of 1679 files
  are unsupported/timeout on the resvg corpus, so the two figures are
  within half a point of each other today and this isn't currently doing
  any real work — but it's a structural soft spot: a renderer can improve
  `pass% (rendered)` by refusing to render (erroring out on) the files it's
  worst at, since those get removed from that denominator entirely rather
  than counted as failures. Worth watching as the unsupported count changes
  rather than acting on now.
- **External-resource stripping (30 files) and font pinning are already
  their own audit (A2)** — flagging only that both change what the
  *reference* image is (stripped hrefs; suite's bundled fonts), which is a
  legitimate policy choice already noted per-row (`note` column) but is
  another way "pass" can mean something narrower than "renders this file
  correctly" without it being visible in the headline number.
- **Nothing found that looks like accidental/unintended inflation** — no
  sampling bias (the icon corpora use a fixed seed, reported in
  `summary.md`; the resvg corpus isn't sampled at all by default), no
  silently-dropped files (every status, including every failure mode, is
  counted in `pass% (all)`'s denominator), and the 99%/tol-8 bar itself is
  a stated, visible design choice (`run_corpora.py`'s own summary text
  spells out both numbers), not a hidden one.

## Files changed

- `tests/run_corpora.py` — added `--ref {resvg,suite}` (default `resvg`,
  behaviour unchanged); `render_one_suite`, `load_suite_ref`,
  `SUITE_REF_CORPUS`; wired through `run_corpus_route`,
  `write_worst_composites`, `main`, and the `summary.md` reference-text.

## What I could not do / did not do

- Did not implement DTD-entity support, external-resource loading changes,
  or anything else outside this audit's scope — none of the invariants or
  the task asked for it.
- Did not fold `score_known.py`'s breakdown into `run_corpora.py`'s
  `summary.md` (§5's suggestion) — that's a real code change beyond "audit
  and report", left for Rowan to prioritize or fold into a follow-up task.
- The 3-file discrepancy in §2's measurement (1679 rated files, 1676
  scored) wasn't root-caused; likely one file with a title in `results.csv`
  that doesn't exactly match its path, or a PNG that failed to decode. Small
  enough not to affect any conclusion above.
