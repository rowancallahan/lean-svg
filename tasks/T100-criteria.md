# T100 — Our own pass/fail criteria per file  (branch `claude/feat-criteria`)

Rowan wants lean-svg judged by its own per-file criteria, not "matches
resvg" everywhere. The rule, in order:

1. If resvg is rated correct for the file (`results.csv` column `resvg` = 1),
   check against resvg.
2. Else if Chromium is rated correct (column `chrome` = 1), check against
   Chromium (`tests/render_chrome.py`; `run_corpora.py --ref chrome`).
3. Else the file needs a human check.

Build:
- `tests/criteria.csv`: one row per suite file (and per `tests/svg/*.svg`,
  whose reference today is resvg), with `reference` = `resvg` | `chrome` |
  `human`, and why.
- `tests/human_verdicts.csv`: Rowan's verdicts for the `human` rows
  (`file,verdict,note`, verdict `pass`/`fail`), initially empty, plus
  `tests/make_human_review.py` that writes a static HTML page (ours | suite
  PNG | Chromium side by side) for the unreviewed `human` rows, so Rowan can
  fill the CSV.
- `tests/score_criteria.py`: reads a `--ref resvg` run CSV and a `--ref
  chrome` run CSV (and the verdicts), prints pass counts per reference kind
  and overall, lists failures, exits non-zero on failures only with
  `--strict`.
- Document it in `tests/README` or `DESIGN.md` (short) and report the first
  full numbers in your task file.

Python only; no renderer changes. Use the existing pass criterion (≥99% of
pixels within 8 levels) unless there is a strong reason; say if Chromium
needs a looser one (anti-aliasing differs) and measure it.

## Report

**Files (Python only, no `LeanSvg/*.lean` touched):**

- `tests/make_criteria.py` (new) — builds `tests/criteria.csv` from
  `tests/corpora/resvg-test-suite/results.csv` (rule in order: resvg `1`
  &rarr; `resvg`; else chrome `1` &rarr; `chrome`; else `human`) plus one
  `resvg` row per `tests/svg/*.svg`.
- `tests/criteria.csv` (new, generated) — 1745 rows: 1522 `resvg`, 45
  `chrome`, 112 `human` (resvg-test-suite, 1679 files) + 66 `resvg` (local
  `tests/svg/*.svg`).
- `tests/human_verdicts.csv` (new) — header only (`file,verdict,note`), no
  rows yet; Rowan fills it by hand.
- `tests/make_human_review.py` (new) — renders ours / suite PNG / Chromium
  for every unreviewed `human` row (skips files already in
  `human_verdicts.csv`) and writes a static `tests/out/human_review/
  index.html`. Smoke-tested with `--limit 3` (see below).
- `tests/score_criteria.py` (new) — scores `tests/criteria.csv` against a
  `run_corpora.py --ref resvg` CSV, a `--ref chrome` CSV, an optional
  `run_tests.py results.json` (for the local `resvg`-reference rows), and
  `tests/human_verdicts.csv`; prints per-reference-kind and overall pass
  counts and a failure list; `--strict` exits 1 if anything scored fails
  (an unreviewed `human` row never trips it).
- `DESIGN.md` — new short §6 "Per-file pass criteria (T100)" documenting
  the above and the Chromium-tolerance finding.

**Verification (all before writing tooling, all still pass after — no
renderer code changed):**

```
lake build                        # clean, no new warnings
bash scripts/check-theorems.sh    # theorems ok
python3 tests/run_tests.py        # 57/66 (pre-existing local failures, unrelated to this task)
python3 tests/run_adversarial.py  # 142/142 clean
python3 tests/run_tiles.py        # 66/66 byte-identical
```

No `tests/svg/<n>_<feature>.svg` was added: this task adds scoring
tooling, not a renderer feature, so there is nothing new to exercise in
the fidelity corpus.

**Chromium tolerance measurement** (the 45 `chrome`-reference files, width
200, tol 8, threshold 0.99 — same knobs as the resvg reference):

| criterion | pass |
|---|---|
| within-8, &ge;99% (current, unchanged) | 18/44 |
| within-32, &ge;99% | 23/44 |
| within-8, &ge;95% | 31/44 |
| within-8, &ge;90% | 37/44 |

(44 scored + 1 `size_mismatch`, `structure/svg/not-UTF-8-encoding.svg`.)
Loosening tolerance alone barely moves it; most failures are text
(RTL/bidi, emoji, `font-weight: 650`, `tspan` + filter/mask/opacity) where
Chromium's own font substitution/hinting/subpixel AA differs from
resvg/lean-svg's, not a few stray seam pixels — so a blanket looser number
would forgive real bugs about as often as it forgives noise. Left the
criterion unchanged; this is exactly what the `human` bucket is for.

**First full numbers** (`python3 tests/score_criteria.py --resvg-csv
<full resvg-suite --ref resvg CSV, width 200> --chrome-csv <chrome+human
target files --ref chrome CSV, width 200> --local-json tests/out/
results.json`):

```
== per reference kind ==
  resvg   1588 file(s)  pass 1517  fail  71  missing   0  unreviewed   0  (pass rate of scored: 95.5%)
  chrome    45 file(s)  pass   18  fail  27  missing   0  unreviewed   0  (pass rate of scored: 40.0%)
  human    112 file(s)  pass    0  fail   0  missing   0  unreviewed 112  (pass rate of scored: -)

== overall ==
  total 1745  pass 1535  fail 98  missing 0  unreviewed 112  (pass rate of scored: 94.0%)
```

(`resvg` bucket = 1522 resvg-suite + 66 local; the resvg-suite-only slice
is 1460/1522 = 95.9% by itself, local is 57/66 — both pre-existing, no
renderer change here.) `human`'s 112 files are all `unreviewed`:
`tests/human_verdicts.csv` starts empty by design (Rowan fills it with
`tests/make_human_review.py`'s page), so this run reports 0 pass/0 fail
for that bucket rather than guessing.

Under the old "always resvg" scoring, the 157 chrome+human files would
either be scored against a resvg that is itself rated wrong/unrated for
them (misleading) or not scored at all. Under T100's rule they get a
better reference where one exists (chrome, 45 files) and an honest
"needs a human" bucket where none does (112 files), instead of being
silently folded into the overall resvg pass rate either way.

Reproduce:
```
python3 tests/make_criteria.py > tests/criteria.csv
python3 tests/run_corpora.py --corpus resvg --route direct --ref resvg \
    --out /tmp/crit_resvg --no-worst
python3 -c "
import csv
rows = [r for r in csv.DictReader(open('tests/criteria.csv'))
        if r['corpus']=='resvg-suite' and r['reference'] in ('chrome','human')]
with open('/tmp/chrome_human_target.csv','w',newline='') as fh:
    w = csv.DictWriter(fh, fieldnames=['corpus','route','file','status'])
    w.writeheader()
    for r in rows:
        w.writerow({'corpus':'resvg','route':'direct','file':r['file'],'status':'fail'})
"
python3 tests/run_corpora.py --ref chrome \
    --failing-from /tmp/chrome_human_target.csv --out /tmp/crit_chrome --no-worst
python3 tests/run_tests.py   # writes tests/out/results.json
python3 tests/score_criteria.py --resvg-csv /tmp/crit_resvg/resvg_direct.csv \
    --chrome-csv /tmp/crit_chrome/resvg_direct.csv --local-json tests/out/results.json
```

**Not done / left for Rowan:** the 112 `human` rows are unreviewed —
`tests/human_verdicts.csv` is intentionally empty. Run
`python3 tests/make_human_review.py` (needs the lean-svg binary built) and
fill `tests/human_verdicts.csv` by hand from the generated page.

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
