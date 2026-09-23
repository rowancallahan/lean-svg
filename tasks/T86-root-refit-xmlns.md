# T86 — root svg content-bbox refit, and xmlns validation  (branch `claude/feat-root-refit-xmlns`)

`tasks/T83-misc-b.md` has the diagnosis in its `## Report`:
1. `structure/svg/no-size.svg`: resvg re-fits the canvas to the content's
   bounding box when the root has no usable size. Implement as usvg does,
   keeping every size cap (`maxDim`, `maxPixels`) and the size-bound proof in
   `proofs/SizeBound.lean` valid (the canvas size must still be checked
   before allocation).
2. `structure/svg/xmlns-validation.svg`: usvg only treats elements in the SVG
   namespace as SVG. Track namespaces in `LeanSvg/Xml.lean` (prefix
   declarations, default namespace, scoped per element) as usvg/roxmltree
   does, bounded like everything else, and ignore non-SVG-namespace elements.
   Keep the parser iterative and total, and keep every adversarial case
   clean; add cases for deeply nested namespace declarations.

## Spec implemented

### 1. Root size refit (`LeanSvg/RootFit.lean`, new)

usvg `resolve_svg_size` + `calculate_svg_bbox` (`converter.rs`):

* Condition (`restore_viewbox`): root has no `viewBox`, and `width` or
  `height` is absent or a percentage (absent = `100%`).
* Size = `(bbox.right, bbox.bottom)` of the root's absolute object bounding
  box: every `Node.shape` in the finished `doc.nodes` (markers already
  expanded), flattened in its own space and mapped through its `ctm`. Tight
  bounds, no stroke, no filter/clip region, as `Group::abs_bounding_box`.
* If that box has no positive right/bottom edge (or there is no content), the
  pre-refit size is kept: each side resolved against the 100×100 default.
* The result is written back as explicit `width`/`height` on `doc.root`;
  `viewBox` stays none, so the root transform is still the identity.
* `render` calls `RootFit.apply` after `Marker.expand` and before
  `canvasSetup`, so the `maxDim`/`maxPixels` checks still run on the final
  size before any allocation. `proofs/SizeBound.lean` only needed its
  `canvasSetup` argument updated; `render_output_size_bound` and
  `render_size_le_const` are unchanged in statement.
* This also makes `width="N"` with no height/viewBox render (it used to fail
  with "cannot determine image size"); usvg refits it too.

### 2. Namespaces (`LeanSvg/Xml.lean`)

As roxmltree + usvg `parse_tag_name`/`parse_svg_attribute`:

* `xmlns` / `xmlns:p` declarations are scoped per element (flat binding
  array plus a per-element mark restored on close); `xml` is predefined.
  At most `maxNsBindings` = 64 bindings in scope, else the parse fails.
* Unknown prefix (element or attribute) and `xmlns:p=""` are parse errors,
  as in roxmltree.
* An element whose namespace is neither none nor SVG is dropped with its
  whole subtree (text/CDATA included) from the event stream, so every
  consumer (`defsScan`, `Use.expand`, filters, patterns, CSS, text) sees the
  same filtered tree. A non-SVG root element is an error (usvg `NoRootNode`).
* Attribute names are canonicalised: SVG-namespace prefix stripped;
  XLink-namespace attributes become `xlink:<local>` and XML-namespace ones
  `xml:<local>` whatever the prefix; attributes in any other namespace and
  the `xmlns*` declarations themselves are dropped.
* End tags now match on the raw qualified name (roxmltree does too).
* The parser stays a single bounded `for` loop; lookups are bounded by
  `maxNsBindings`.

## Skipped

* Shapes usvg keeps but we drop before `doc.nodes` (e.g. `visibility="hidden"`
  or no fill and no stroke) do not contribute to the refit box; usvg counts
  them. No corpus file hits this.
* Text bbox is the union of our glyph outlines, not usvg's text layout box.
* Content percentages in the `width="N"`-only case still resolve against the
  100×100 viewport (usvg uses `(N, 100)`); unchanged from before.

## Report

Target files, 200 px (`--dir structure/svg`), within-8:

| file | before | after |
|---|---|---|
| `structure/svg/no-size.svg` | 0.674 | 1.000 |
| `structure/svg/xmlns-validation.svg` | 0.360 | 1.000 |
| `structure/svg/mixed-namespaces.svg` | 0.965 | 1.000 (same root cause) |

Whole resvg suite, direct route:

| pass | before | after |
|---|---|---|
| 100 px (`--fast`) | 1521 / 1679 | 1524 / 1679 |
| 200 px | 1542 / 1679 | 1545 / 1679 |

Zero pass→fail and zero within-8 drops at either width.

* `lake build`: no errors, no warnings. `check-theorems.sh`: `theorems ok`.
* `run_tests.py`: 48/52 (was 46/50; new `86_xmlns`, `86_root_refit` pass;
  no score drops; the same 4 fail as before).
* `run_adversarial.py`: 125/125 clean. New cases: `ns_nested_60` (renders),
  `ns_nested_overflow` (rejected), `ns_rebind_30`, `ns_foreign_deep` (60-deep
  non-SVG subtree dropped), `ns_unknown_prefix` (rejected), `ns_lookup_flood`
  (63 bindings × 3·10^5 prefixed attributes, ~2.4 s), `refit_huge`
  (refit canvas rejected by `maxDim`).
* `run_tiles.py`: 52/52 byte-identical.

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
