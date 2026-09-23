# T67 — feImage (same-document references)  (branch `claude/feat-feimage`)

The filter foundation (T51, read `tasks/T51-filters.md` and `DESIGN.md`
§3.11 first) has landed. Adding a primitive is: a `Kind` constructor, a clause
in `Filter.convertPrim`, a case in `FilterApply.runPrim`, and removing its name
from `Filter.isKnownUnsupported`. **Other agents are adding other primitives
concurrently**, so: put all of your primitive's code in a new file
`LeanSvg/Filter/<Name>.lean` (imported where needed), and keep your edits to
`Filter.lean`/`FilterApply.lean` to those few one-line-ish additions. Match
resvg 0.48.1's `crates/resvg/src/filter/*.rs` exactly where pixels depend on
it (its f32 maths must be reproduced in fixed point/integers to within the
8-level tolerance; exact is better — T51's report shows how it matched
colour-space LUTs and f32 sin/cos). Respect T51's work budgets: every
per-pixel loop is bounded by the layer area times a constant or a bounded
kernel size; cap kernel sizes/octaves/etc. as resvg does, and add an
adversarial case for the expensive parameter.

Target: `filters/feImage` (26 failing). Scope for now: `href` to an element
**in the same document** (usvg renders that element, with its own
transform, into the primitive subregion — see usvg `parser/filter.rs`
`convert_image` and resvg `filter/mod.rs` `apply_image`), and
`preserveAspectRatio`. `href` with a `data:` image: another agent (T63) is
building `<image>` and the decoders behind `LeanSvg/ImageData.lean`; call
`ImageData`-level decoding only through a function T63 will expose — for now
treat `data:` hrefs as usvg treats an image it cannot decode, and leave a
clearly marked single call site so the integrator can wire it up. Any other
href (file, URL): nothing is loaded, same as unsupported. Rendering the
referenced element needs the renderer's node walk: reuse
`Render.renderNodes` (it is re-entrant; masks use it the same way) with the
fuel it is given, and count it in the existing budgets.

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

Files: new `LeanSvg/Filter/Image.lean` (spec, `fix_recursive_fe_image`,
sub-documents), new `LeanSvg/Filter/ImageRender.lean` (jobs/geometry for
`Render`); one-liners in `Filter.lean` (`Kind.image`, `convertPrim`,
`isKnownUnsupported`/`isPrimitive`, `primRegion`'s `objectBoundingBox` case
now covers `feImage` like `feFlood`, as usvg's `resolve_primitive_region`
does) and `FilterApply.runPrim`; `Svg.Doc.events` + two lines in
`interpret`; the render hook in `Render.renderNodes`' `groupEnd`;
`DESIGN.md` §3.11.

* **`href="#id"` (usvg `convert_image_inner`, resvg `apply_image`).** The
  element is rendered with `[sx 0 0 sy subregion.x subregion.y]` (the filter
  transform's `get_scale`, the subregion's integer layer-pixel origin) onto a
  transparent canvas the size of the filter region (after `fit_to_rect`),
  anchored at the layer origin like every other result, sRGB.  Its own
  `transform`/`opacity`/`filter`/`clip-path`/`mask` apply; its ancestors'
  transforms do not, their inherited properties do.
* **How.** There is no node tree to convert one element from, so the element
  is cut out of the input as a sub-document: the root (keeping
  `width`/`height`/`viewBox` and inherited properties), all its children in one
  `<defs>` (so paint servers, filters, clips, masks, `use` targets and CSS are
  all still there), then one `<g>` per ancestor carrying only inheritable
  attributes (`style` filtered likewise), then the target subtree (ids on
  definition elements stripped, as `Use` does).  `Render` interprets it with
  `Svg.interpret` and paints it with `renderNodes` on `fuel - 1`, with a fresh
  clip cache (the sub-document's tables are its own).  The last element with
  the id wins (usvg's id map).  `Doc.events` holds the input events after the
  fix below and before `use` expansion (the sub-document is expanded by its own
  `interpret`).
* **`fix_recursive_fe_image`** on the events, before `use` expansion: a linked
  element whose `filter` (attribute or `style`) names the `feImage`'s parent
  gets `filter="none"`.  Longer cycles (A → B → A) are cut by the fuel.
* **Everything else** — no `href`, a missing id, the root, a non-graphic
  target that renders nothing, a file or URL — is usvg's dummy primitive
  (transparent black).  `data:` hrefs go through the single stub
  `FeImage.dataCanvas` (returns `none`, i.e. the dummy, as usvg does for an
  image it cannot decode); it receives the URI, the parsed
  `preserveAspectRatio`, the region size and the subregion, which is what
  usvg's `image::convert_inner(…, filter_subregion.translate_to(0, 0))` needs.
  **Integrator:** wire it to T63's decoder + image drawing.
* **Budgets.** Each link rendered costs `1 + events/4096` of
  `maxMaskRenders` (1024 per render: the re-interpretation is about the
  document's size), error `feImage budget`; the link's canvas is checked
  against `maxLayerPixels` (error `layer budget`); nested filters inside the
  link count in the same `maxFilterTotal`.  New adversarial cases:
  `feimage_cycle_fanout` (8 links per filter through an A → B → A cycle,
  `feImage budget` after 0.26 s) and `feimage_many_links` (16 links to a
  2000-shape group on a 1 Mpx region, renders in 2.1 s).

## Skipped, and why

* **Decoding `data:` images / `preserveAspectRatio` drawing**: T63's decoders
  and image renderer; left at the one marked call site.  The 8 image files of
  `filters/feImage` (plus `painting/image-rendering/on-feImage`) fail for
  that reason alone.
* **`max_bbox` inside a link**: resvg renders the link with
  `max_bbox = (0, 0, region)`; here a nested filter inside the link uses the
  usual `max_filter_bbox` rule sized by the region.  Differs only when a
  nested filter region reaches far past the feImage region.
* A CSS rule (not attribute/`style`) setting `filter` on a recursive link is
  not reset by the fix; ancestors that are nested `<svg>`s lose their
  percentage viewport in the sub-document.

## Report

Baseline commit `1ba4c27`. `run_corpora.py --fast --corpus resvg --route direct`
(width 100), before → after:

| dir | files | pass before | pass after | mean within-8 before | after |
|---|---|---|---|---|---|
| filters/feImage | 27 | 1 | 18 | 57.55% | 90.17% |
| filters/ (all) | 397 | 257 | 276 | | |

Also newly passing: `filters/filter/on-group-with-child-outside-of-canvas`,
`filters/filter/with-transform-outside-of-canvas` (both feImage-based).
Whole suite: **1224 → 1243 of 1679; newly passing 19, newly failing 0**; no
file's within-8 dropped (the image files moved up or stayed: a transparent
region vs. a red one against resvg's image).  At `--width 200` (natural size)
feImage is 18/27, the same files.

Other checks, all on the final tree:

* `lake build`: no errors, no warnings.
* `scripts/check-theorems.sh`: `theorems ok` (`SizeBound` unchanged).
* `tests/run_tests.py`: every file's score unchanged; new `35_feimage`
  (gradient, inherited fill/stroke through a `<g>` in `defs`, `use`,
  subregion `x`/`y`, a filtered link, a missing id, a rotated filtered
  element) 99.86% within 8, PASS; 32/36 pass (the same four fail as before).
* `tests/run_adversarial.py`: 85/85 clean.
* `tests/run_tiles.py`: 36/36 byte-identical; `35_feimage` at `--width 800`
  with `--threads 4` byte-identical to serial.
