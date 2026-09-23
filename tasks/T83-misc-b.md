# T83 — root svg size and xmlns validation  (branch `claude/fix-misc-b`)

Both are about how the root `<svg>` is accepted and sized.

## How to work (research first)

1. **Diagnose first (keep it short).** Render each file below with
   `.lake/build/bin/lean-svg` and with `resvg -w 200`, look at both PNGs and a
   diff, find the root cause in our code, and find how resvg/usvg 0.48.1
   handles it in the Rust source.
2. **If the fix is small and safe**, implement it, verify it with the rules
   below, and push.
3. **If it is not**, do not force it: write the diagnosis (root cause, the
   relevant usvg/resvg code, the proposed fix and its risks, rough size) into
   your task file's `## Report`, and push only that.
Either way the report must name the root cause of every file below.

Files (within-8 at 200 px):

- `structure/svg/no-size.svg` (0.674)
- `structure/svg/xmlns-validation.svg` (0.360)

## Report

Diagnosed both; neither fix is small/safe, so nothing was changed in
`LeanSvg/*.lean`. Confirmed current scores unchanged at 200 px, `--corpus
resvg --route direct --dir structure/svg`:

| file | within-8 |
|---|---|
| `structure/svg/no-size.svg` | 0.674400 |
| `structure/svg/xmlns-validation.svg` | 0.359975 |

Both were already triaged and explicitly skipped for the same reason in
`tasks/T64-structure-tail-2.md` ("Skipped" section); this re-diagnoses each
from scratch against the actual usvg/resvg 0.48.1 source and pixel evidence,
and reaches the same conclusion.

### `structure/svg/no-size.svg` — root cause

The root `<svg>` has no `width`, `height` or `viewBox` at all. Rendered
natively (no `--width`) with plain `resvg`, the reference PNG is **199×199**,
not the 100×100 usvg's own stated default would suggest.

usvg's `resolve_svg_size` (`crates/usvg/src/parser/converter.rs:523`)
resolves the missing `width="100%"`/`height="100%"` against its
`Options::default_size` (100×100) when there is no `viewBox`, setting
`restore_viewbox = true` in that case (line 540). After the whole tree is
built, `convert` (line 497) then calls `calculate_svg_bbox` (line 600) *only*
when `restore_viewbox` was set:

```rust
fn calculate_svg_bbox(tree: &mut Tree) {
    let bbox = tree.root.abs_bounding_box();
    if let Some(size) = Size::from_wh(bbox.right(), bbox.bottom()) {
        tree.size = size;
    }
}
```

i.e. the document's *reported* size is replaced by `(bbox.right, bbox.bottom)`
of the whole tree's absolute (canvas-space, pre-zoom) bounding box —
`Group`/`Path`/`Image`/`Text::abs_bounding_box()` (`crates/usvg/src/tree/
mod.rs`), each precomputed recursively while the tree is built. For this file
the frame rect (`x=1 y=1 width=198 height=198`) puts `bbox.right() =
bbox.bottom() = 199`, matching the observed 199×199 native render exactly.

Our renderer (per `T24a`'s Report, which first hit this file) already
matches usvg's *pre*-refit fallback — `Svg.resolveRootSize`'s `none, none,
none => some (100, 100)` arm (`LeanSvg/Svg.lean:1372`), wired straight into
`Render.canvasSetup` (`LeanSvg/Render.lean:113`) — but never performs the
bbox-refit afterward, so our 100×100 canvas (then scaled to 200×200 for
`--width 200`) does not match resvg's 199×199-native canvas (also scaled to
200×200, but with different content placement relative to the frame), which
is the whole of the 0.674 gap: the green rect lands in the same place either
way, but the frame border and the margin around it do not.

Implementing the refit is a second, document-wide pass that has to run
*before* `canvasSetup` can even pick `(W, H)` — walk `Doc.nodes` and compute
a bounding box over every shape's own geometry (fill bbox, not stroke:
`Node::abs_bounding_box`, not `abs_stroke_bounding_box`), composed through
every ancestor's transform, matching each element kind's own bbox rule
(path/text/image/nested-group), *before* any zoom is known. That is a new
subsystem, not a local patch, and it also reaches into `proofs/
SizeBound.lean`: the size bound currently derives entirely from `root`'s
declared `width`/`height`/`viewBox`, decided before any content is walked;
making the canvas size a function of the fully-interpreted content would
need the proof re-derived, not just patched. Out of proportion for one file;
skipped, matching T64.

### `structure/svg/xmlns-validation.svg` — root cause

The file redefines the default XML namespace inside a group to a
non-SVG URI while binding a prefix to the real SVG namespace:

```xml
<s:g id="g1" xmlns="http://www.example.org/notsvg" xmlns:s="http://www.w3.org/2000/svg">
    <s:rect id="rect1" ... fill="green"/>
    <rect id="rect2" ... fill="red"/>
</s:g>
```

Per XML namespaces, `<s:rect>` resolves to the SVG namespace (via the `s:`
binding) and is a real SVG element; the unprefixed `<rect>` resolves to
`http://www.example.org/notsvg` (the `xmlns=""` on the same `<g>` shadows the
outer default) and is *not* an SVG element, so a conforming renderer must
drop it and everything under it. `resvg -w 200` on this file is solid green
(rect1 only) — confirmed by rendering and diffing both PNGs: our output's
centre pixel is `(255,0,0,255)` (red/rect2) against resvg's `(0,128,0,255)`
(green/rect1).

Our XML layer erases this information before `Svg.lean` ever sees it:
`Xml.localName` (`LeanSvg/Xml.lean:45`) strips everything up to and
including `:` unconditionally at tokenise time, for *element* names only
(`Xml.parse`, lines 182 and 196), and nothing downstream tracks `xmlns`/
`xmlns:*` bindings at all — attributes keep their raw (possibly prefixed)
name, but there is no namespace resolver anywhere in `Svg.lean`. So
`interpret` (`LeanSvg/Svg.lean:3306`) sees two indistinguishable local names
`rect`, paints both in document order, and the one drawn second (`rect2`,
red) wins — exactly the observed failure.

Fixing this for real means:

1. `Xml.lean`: stop discarding the prefix at parse time (keep the raw
   qualified name, or emit prefix and local name both) — a parser-level
   change to the `Event.open_`/`.close` shape every consumer pattern-matches
   on.
2. `Svg.lean`: track a default-namespace/prefix-map per element through
   `interpret`'s walk (inherited like `xml:space`, reset by any `xmlns*`
   attribute on that element), resolve every element's *and* every
   namespaced attribute's (`xlink:href` et al.) effective namespace against
   it, and drop anything that resolves outside the SVG (or, for attributes,
   XLink) namespace.
3. Every other pass that shares the same flat event stream and currently
   dispatches on bare local name would need the same gating to stay
   consistent with the main walk: `defsScan`, `Use.expand`, `Filter.scan`,
   `Pat.Defs.build`, `textPathTables`, and CSS element-chain matching — an
   `id`/`href` inside a namespace-shadowed subtree must not be
   referenceable, exactly as it must not be paintable.

That is a cross-cutting change to the parser and to every dispatch site
against a stream that today carries no namespace concept whatsoever, for one
file's worth of behaviour (this is the only file in the whole `resvg-test-
suite` corpus whose default namespace is shadowed like this). Out of
proportion for one file; skipped, matching T64's identical conclusion for
this same file (and `mixed-namespaces.svg`, which is not in this task's
list but shares the identical root cause and fix).

No `LeanSvg/*.lean` files changed. No corpus run needed beyond the two
`--dir structure/svg` runs above (100 px fast and 200 px full), which
reproduce the task's stated baseline exactly and confirm nothing regressed
because nothing was touched.

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
