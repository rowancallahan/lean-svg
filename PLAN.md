# lean-svg — work plan

Goal: a micro-SVG → PNG rasterizer in Lean 4 whose *only* claim is safety.
Bytes in, bytes out. It reads exactly one file, then either fails with a message
(writing nothing) or writes exactly one PNG of bounded size. No floats, no
`partial`, no `unsafe`, no FFI, no dependencies. Rendering fidelity is checked
empirically against resvg; it is not a theorem.

Model for the project: [kim-em/lean-zip](https://github.com/kim-em/lean-zip)
(verified DEFLATE in Lean). This is the same idea for a rasterizer.

Legend: **[done]**, **[Opus]** = straightforward coding, spec below is complete,
**[design]** = needs conceptual work first (do not delegate blind).

---

## M0 — Scaffold, proofs, first renderer  [done]

- Lake project, no dependencies (`lakefile.toml`, `lean-toolchain` = v4.34.0).
- `LeanSvg/Effect.lean`: free monad `Prog` over two ops; theorems
  `runFS_frame`, `runFS_input_only`, `renderProgram_spec`,
  `renderProgram_error_no_write`, `renderProgram_ok_output`,
  `renderProgram_ok_frame`. Axioms used: `propext` only.
- Pure pipeline: `Xml.parse` → `Svg.interpret` → `Render.canvasSetup` →
  `flatten`/`strokePoly` → `Raster.rasterize` → `Canvas.fillMask` → `Png.encode`.
- First corpus: `tests/svg/01..11`. All ≥ 99% pixels within tolerance 32 of
  resvg; triangle is 99.00% *exact*, 100% within 8.
- Adversarial corpus `tests/adversarial/`: billion laughs and XXE rejected at
  the DOCTYPE, external refs ignored, huge dims rejected, all < 20 ms, no
  output file on error.

## M1 — Test harness  [Opus, in progress]

`tests/run_tests.py` (resvg oracle, Hamming-style metrics, composites, HTML
report), `tests/run_adversarial.py` (generated hostile inputs, checks exit
code ∈ {0,1}, no stray files, no timeouts), `Makefile`.

Metric definition (fixed): per pixel `d = max channel |ours − ref|`.
`exact = P(d = 0)`, `within = P(d ≤ 8)`. Pass = `within ≥ 0.99`. Report exact
too. Anti-aliasing seams differ by a few levels along every edge, so `exact`
alone would fail on thin strokes even when the render is right.

## M2 — Browser playground  [Opus, in progress]

`playground/server.py` + `playground/index.html`: type or draw an SVG, see
browser / resvg / lean-svg / diff, with the metrics. `.claude/launch.json`
entry `playground`.

## M3 — Output-shape theorem  [design → then Opus for the proof grind]

User's requirement: "either errors or writes to another file *at the size
expected*". Statement to prove:

```lean
theorem render_ok_shape (opts inp png) (h : render opts inp = .ok png) :
    ∃ w h, 0 < w ∧ 0 < h ∧ w ≤ maxDim ∧ h ≤ maxDim ∧ w * h ≤ maxPixels ∧
      png.size = Png.sizeFor w h ∧ png.extract 16 24 = Png.be32 w ++ Png.be32 h
```

Approach (decided):
1. Add `Png.sizeFor w h := 8 + 25 + (12 + 2 + 5·nblocks + raw + 4) + 12` with
   `raw = h·(4w+1)`, `nblocks = max 1 ⌈raw/65535⌉`.
2. Prove `ByteArray.size_append`, `size_push`, `size_extract` style lemmas as
   needed (core has most; check `ByteArray.size_append`).
3. Prove `Canvas.toRgbaBytes_size : (cv.toRgbaBytes).size = 4 · cv.px.size`
   and `Canvas.fillMask` preserves `px.size` (it only uses `setIfInBounds`).
4. Prove `zlibStored_size` by rewriting the `for` loop as `Nat.fold` or a
   recursive helper (easier to reason about than `forIn` over `Std.Range`).
   Recommendation: restructure `Png.zlibStored` and `Png.encode` as explicit
   recursion over `Nat` with `termination_by`, keep behaviour identical, then
   prove by induction.
5. `render` is a `do` block in `Except`; unfold and case on each bind.

## M3b — Stronger effect theorems  [design → Opus for the proofs; future]

Requested 2026-09-20, not started. Statements to add to `Effect.lean`.
**Priority set 2026-09-21: no-clobber (1) is the next one to do**, because it
subsumes the distinct-paths requirement below.

0. **Input and output paths must differ.** Today nothing stops
   `lean-svg in.svg in.svg`: the program reads the file and then overwrites
   it. `runFS_frame` is still true, because the output path is the one path
   allowed to change, so the theorem is honest but protects less than
   "only touches the two paths given" suggests. Two ways to fix it, and
   no-clobber is the better one:
   - cheap: reject `inp = out` in `Main.lean` before running the program,
     and state it as a theorem about the argument parser rather than the
     effect layer;
   - better: **no-clobber** (1) makes it impossible to overwrite *any*
     existing file, which covers this case and every other one. Do that
     instead, and keep the cheap check only if it gives a clearer error.


1. **No-clobber.** The program only writes the output path if that path did
   not exist when the program started. Model: `FS := String → Option ByteArray`
   (`none` = absent); add `Op.outputExists : Op` with `Res = Bool`; the
   renderer program becomes: read input; if output exists, fail; else render
   and write. Theorems: `runFS_frame` as today; new
   `renderProgram_no_clobber : fs out = some b → (run …).2 = fs`; and the
   existing input-only theorem generalises to "depends only on `fs inp` and
   on whether `fs out` is present". The trusted `execIO` gains one
   `System.FilePath.pathExists` call, still on the two given paths only.
2. **Output size bound (reach; strengthens M3).** `render opts inp = .ok png →
   png.size ≤ Png.maxSize` where `Png.maxSize = sizeFor maxDim maxDim` is the
   uncompressed size of the largest permitted canvas: no blown-up files by
   construction. M3's exact `sizeFor w h` implies it.
3. **Bounded work (reach).** Two options, cheapest first: (a) a step budget
   threaded through `render` as fuel (pure, provable: "returns within N
   steps or fails"); (b) a wall-clock cap in the trusted shell (default one
   hour, resettable to unlimited by flag), not provable but simple. Totality
   already guarantees termination; this bounds *how long*.
4. **Max input size.** `render` rejects `inp.size > maxInput` (say 64 MiB)
   before parsing; theorem `render_rejects_large : inp.size > maxInput →
   render opts inp = .error _`. Trivial once the check exists.

## M4 — Fidelity features  [Opus]

Some features share scene/definition infrastructure (see the scoped plan below).
Keep the invariants: no `partial`, every loop bounded
by input size or a constant, every parsed number clamped, indices via
`getD`/`setIfInBounds`.

- **Implemented (T24a):** 148 CSS named colours and `color`/`currentColor`.
- **Implemented (T23), fidelity refinements remain:** `stroke-dasharray` /
  `stroke-dashoffset`: split each flattened polyline into
  dashes before `strokePoly`. Bound the dash count: if pattern sum ≤ 0 or the
  number of dashes on a subpath would exceed 100 000, draw solid.
- Percent lengths for `width`/`height` on root (relative to viewBox).
- `display`/`visibility` on the root `<svg>`.
- Nested `<svg>` as a group with its own viewport (currently skipped).
- **Implemented (T16):** elliptical arc `A`/`a` conversion to cubics using
  fixed-point centre parameterisation and square roots, without `atan2`.
  Remaining curve/stroke fidelity work is separate from adding arc support.
- `<use href="#id">` **deferred from the next scoped release**: requires a definitions table and a cycle
  guard. Bound expansion by a fuel of 64 nested uses and 100 000 total
  instantiated elements; otherwise error. Never follow anything but `#local`.
- Group opacity done correctly (offscreen layer for `<g opacity>`); today it
  is multiplied into children, wrong where children overlap. Layer = a second
  `Canvas`, then `over` with alpha. Bound: layers count as pixels against
  `maxPixels`.
- Linear/radial gradients (`url(#id)` fill): a paint that is evaluated per
  pixel from the mask. Fixed-point gradient parameter; `spreadMethod` pad only
  first. Do after a restricted local definitions table; implementing `<use>`
  is not a prerequisite.

## Scoped feature plan — suggestions from review, 2026-09-20

Requested scope: useful text, group layers, gradients, clipping, masks, and
nested SVG, with bounded nesting and conservative reference handling. This
section updates the ordering/scope of older M4 and M11 notes; it records
suggestions only, not implemented behaviour. Arcs, named colours, and dashes
are already on main. No renderer changes were made during this review.

### What matters most

Text is probably the largest usability gap for labelled diagrams and charts.
It is not a prerequisite for gradients, layers, clipping, or masks. Basic
embedded-font Latin text is a tractable milestone; "most fonts" and correct
international shaping are a much larger project and are not promised here.

The main shared graphics change is replacing the flat `Doc.shapes` model with
a bounded representation that retains group boundaries. An explicit sequence
of begin-group/end-group/draw commands can preserve the iterative design;
an unrestricted recursive scene tree is not required. Group opacity must be
applied after children are composited, rather than multiplied into each child.
The same boundaries support clips, mask application, and nested viewports.

### References: restrict capability rather than enabling general resolution

- Keep external URLs, filesystem paths, external fonts/images, and general
  resource loading unsupported. Defer `<use>`/`symbol` expansion.
- Suggest allowing only same-document `url(#id)` lookups for gradients,
  clip paths, and masks. Ordinary SVG uses these references to attach the
  effects; rejecting all references would prevent ordinary use of these
  features. A local lookup adds no file/network operation and can retain the
  existing effect interface.
- Build a bounded, typed definitions table from the input bytes. Initially
  reject duplicate IDs, missing/wrong-type targets, and reference chains
  within definitions. No gradient `href` inheritance, recursive masks, or
  reusable-element expansion in the first version. Restrict mask/clip content
  to explicitly supported valid child types and paints; do not silently claim
  full SVG semantics for this subset. In particular the local corpus tests
  that a direct `g` child of `clipPath` is ignored; applying a clip to a group
  is a different, supported-use case to implement.
- `<use>` is not intrinsically an external read, but its expansion/cycle
  handling is extra work that can reasonably wait.

### Resource limits: depth ten plus total budgets

Suggested first policy: maximum XML element depth **10**, counting the root
as depth 1; reject deeper inputs with a clear error. Current code still allows
64. Check existing examples/exported SVGs before finalising the lower cap.
Render-group depth must also remain bounded; ordinary groups need no offscreen
surface unless their compositing semantics require one.

A depth limit alone does not bound practical runtime: a depth-two document
can contain many full-canvas shapes, and a branching definition can expand
repeatedly. Pair the depth limit with:

- A maximum input byte size and total parsed elements/path commands/glyphs.
- A shared work budget for drawing and definition evaluation, including
  repeated uses of the same mask/clip. Calibrate concrete values on the
  existing stress tests; do not infer a time guarantee from depth alone.
- A cap on aggregate live canvas/mask/layer storage, including parallel bands.
  Allocate temporary surfaces to clipped bounds where possible and release
  them when the group ends. Ten full-size layers are not automatically cheap.
- Shared total component/point/work budgets for composite glyphs, in addition
  to T25's existing per-node component and recursion-depth limits.

On an exceeded budget, return an error before writing output. Structural
termination and these engineering limits do not themselves complete M3/M3b's
formal output-size/work-bound proofs.

### Delivery units and rough effort

Estimates below are judgement from the inspected code, not measured schedules
or guarantees. Units are focused engineering days for someone comfortable
with Lean and this codebase, including local feature tests. They assume reuse
of the existing rasterizer and completion of the in-progress T25 parser.
The final row covers cross-feature integration beyond each feature's tests.

| Unit | First supported scope | Estimated days |
|---|---|---|
| Native text | Finish/validate T25; preserve XML text; embedded regular/bold/italic; basic Latin `text`/`tspan`, positions, anchors, spacing, kerning and baseline handling; outline rendering | 7–12 |
| Shared graphics foundation | Preserve group boundaries, bounded local definitions, depth/work/storage limits | 4–7 |
| Layers | Isolated group opacity with source-over compositing; defer blend modes | 2–4 |
| Gradients | Linear and radial, stops, units and transforms; pad spread first; no chained inheritance | 3–5 |
| Clipping | Local clip paths applied to shapes/groups, valid clip children, transforms, units, fill rules and bounded clip intersections | 2–4 |
| Masks | Bounded offscreen mask rendering, region/units, alpha and luminance application over the supported content subset | 3–5 |
| Nested SVG | Local viewport/viewBox mapping, preserveAspectRatio and overflow clipping, within the depth cap | 2–3 |
| Integration and validation | Text/effect combinations, tile and parallel equivalence tests, adversarial budgets, corpus refresh and regressions | 4–7 |
| **Total remaining scoped feature work** | **Eight delivery units** | **27–47** |

Budget roughly **6–10 working weeks of one engineer's focused effort**, with
additional uncertainty for fixed-point radial gradients, text semantics, and
the shared scene change. This is an effort estimate, not an agent runtime
estimate; staffing does not divide it linearly because the work shares core
modules. It is not an estimate to finish every milestone in PLAN.md.

**Agent-assisted planning update:** Rowan reports the existing implementation
was built in about ten hours using agents and proposes two more days for this
feature set. That observed delivery rate is more relevant to this workflow
than the human-engineering estimate above. A two-day sprint is a plausible
target for a first integrated implementation of the scoped features, not a
validated completion forecast. Basic text is likely the largest individual
feature; shared scene/compositing work and masks may rival it. Layers and
linear gradients are comparatively straightforward; clipping and nested
viewports are moderate; radial-gradient cases and masks need more care.
Use the acceptance checks below as the finish line, and allow unresolved
integration/fidelity/resource-limit failures to carry beyond the sprint.
Broad font compatibility and the excluded milestones are not part of that
two-day target.

Suggested order: a minimal end-to-end text slice; shared graphics foundation;
layers and clipping; gradients and nested SVG; masks; combined validation.
Text can reuse the existing shape renderer before the scene change, provided
its output can be emitted inside the later group representation.

Exclude from this estimate: general `<use>` expansion, complex-script shaping,
CFF/variable/colour fonts, system-font discovery, filters, images, advanced CSS,
blend modes, text-on-path/vertical text, the stronger formal proofs, verified
compression, and Aeneas. These remain separate roadmap items.

### Acceptance evidence

- Refresh the whole external corpus on the final combined commit, with fixed
  sizes and an explicitly controlled font set. Keep direct/usvg results separate.
- Check text on tightly cropped/content-focused images as well as the existing
  whole-image metric: blank backgrounds can let missing text pass that metric.
- Add overlap examples for group opacity, clips/masks around transformed text,
  and nested viewports; compare against resvg only within the declared subset.
- Check depth 10 acceptance / depth 11 rejection, very wide shallow documents,
  repeated definitions, and aggregate temporary-storage exhaustion. Confirm
  error paths write nothing and tile/parallel renders still agree.
- Existing full-corpus percentages are historical baselines; the recorded
  86.5% simple-icons result is a 400-file usvg sample, not a full-corpus score.

## Feature selection and corpus audit — 2026-09-20

This is a practical menu for a static SVG-to-PNG renderer, not an exhaustive
SVG/CSS specification or a claim that every renderer supports every row.
Choose Yes or No in each row (or respond with the IDs). Choices are deliberately
blank; the recommendation column is advisory. "Later" means omit from the
first scoped release, not an implemented or accepted decision.

Coverage was checked against the **local files**, not inferred from pass rates:
1,679 SVGs under `tests/corpora/resvg-test-suite/tests`. Directory names below
are relative to that directory; counts describe examples present, not exhaustive
coverage, independent cases, or tests that currently pass. Shared directories
appear in multiple rows and must not be summed. No renders were run for this
audit. The simple-icons and feather sets supplement shape/stroke diversity,
but do not replace feature-specific tests.

### Geometry, styles, structure, and painting

| ID | Include? | Feature | Suggestion | Local corpus evidence |
|---|---|---|---|---|
| C01 | [ ] Yes / [ ] No | Basic shapes, rounded rectangles | Yes; largely implemented | `shapes/rect` 38, circle 6, ellipse 12, line 10, polygon 5, polyline 5 |
| C02 | [ ] Yes / [ ] No | Paths, cubic/quadratic curves, elliptical arcs | Yes; implemented, refine fidelity | `shapes/path` 57, including `A.svg`, `M-A.svg`, `M-Q-T.svg` |
| C03 | [ ] Yes / [ ] No | Solid colors, alpha, currentColor, RGB/HSL notation | Yes; HSL separate from existing named colors | `painting/fill` 60, `painting/color` 4; explicit HSL/HSLA fixtures |
| C04 | [ ] Yes / [ ] No | Nonzero/even-odd fills | Yes; implemented | `painting/fill-rule` 2 plus path/polygon examples |
| C05 | [ ] Yes / [ ] No | Stroke widths, caps, joins, miter limits | Yes; implemented, refine curves | `painting/stroke` 20, width 5, linecap 9, linejoin 5, miterlimit 5 |
| C06 | [ ] Yes / [ ] No | Dashes and dash offsets | Yes; implemented, refine units/fidelity | `painting/stroke-dasharray` 17, dashoffset 6 |
| C07 | [ ] Yes / [ ] No | Non-scaling strokes (`vector-effect`) | Optional | No matching `vector-effect`/`non-scaling-stroke` content found |
| C08 | [ ] Yes / [ ] No | Author-specified `pathLength` scaling | Later | No `pathLength` content found |
| C09 | [ ] Yes / [ ] No | Transforms and transform origins | Yes | `structure/transform` 19, transform-origin 23 |
| C10 | [ ] Yes / [ ] No | Size/units, viewBox, preserveAspectRatio | Yes | `structure/svg` 42; explicit percent, size, alignment, meet/slice fixtures; text also has unit tests |
| C11 | [ ] Yes / [ ] No | Groups, inheritance, display/visibility | Yes | `structure/g` 2, `painting/display` 9, visibility 7, inheritance cases across directories |
| C12 | [ ] Yes / [ ] No | Group/element opacity applied after compositing | Yes | `painting/opacity` 9, including group-opacity and mixed-group-opacity |
| C13 | [ ] Yes / [ ] No | Fill/stroke opacity | Yes; implemented | `painting/fill-opacity` 8, stroke-opacity 8 |
| C14 | [ ] Yes / [ ] No | Nested SVG viewports and overflow | Yes, depth-limited | `structure/svg` 42 includes many `nested-svg*` fixtures; `painting/overflow` 5 |
| C15 | [ ] Yes / [ ] No | Inline style and simple stylesheet selectors/cascade | Yes | `structure/style-attribute` 4, style 16; type/class/id/attribute/universal selectors, specificity, important |
| C16 | [ ] Yes / [ ] No | Advanced CSS/browser layout behavior | Later; define a subset explicitly | Simple-selector evidence does not establish broad CSS coverage |
| C17 | [ ] Yes / [ ] No | Shape-rendering hints, crisp edges | Optional | `painting/shape-rendering` 8 |
| C18 | [ ] Yes / [ ] No | Paint order (fill/stroke/markers) | Optional | `painting/paint-order` 14 |
| C19 | [ ] Yes / [ ] No | Conditional switch and language selection | Optional | `structure/switch` 13, systemLanguage 10 |

### Paint servers, effects, and resources

| ID | Include? | Feature | Suggestion | Local corpus evidence |
|---|---|---|---|---|
| C20 | [ ] Yes / [ ] No | Local definitions and restricted `url(#id)` resolution | Yes, needed for effects below | `structure/defs` 7; local effect references throughout the suite |
| C21 | [ ] Yes / [ ] No | Linear gradients, stops, units, transforms | Yes | `paint-servers/linearGradient` 38; stop 32, stop-color 1, stop-opacity 2 |
| C22 | [ ] Yes / [ ] No | Radial gradients and focal-point/radius handling | Yes | `paint-servers/radialGradient` 45; explicit focal correction, fx/fy/fr and degenerate-radius fixtures |
| C23 | [ ] Yes / [ ] No | Repeat/reflect gradient spread | Optional after pad | Both gradient directories have `spreadMethod=pad/reflect/repeat.svg` |
| C24 | [ ] Yes / [ ] No | Gradient inheritance through local href chains | Later | Both gradient directories include inherited stops/attributes and recursive references |
| C25 | [ ] Yes / [ ] No | Repeating patterns | Later | `paint-servers/pattern` 31 |
| C26 | [ ] Yes / [ ] No | Clip paths, units, transforms, fill rules | Yes | `masking/clipPath` 52, clip-rule 1; includes text clips and invalid child types |
| C27 | [ ] Yes / [ ] No | CSS basic-shape clips / legacy clip rectangle | Optional, separate from clipPath elements | clipPath contains circle-shorthand fixtures; `masking/clip` 1 |
| C28 | [ ] Yes / [ ] No | Alpha/luminance masks, regions and units | Yes, restricted contents | `masking/mask` 39; alpha/luminance, transforms, units, opacity and clip interactions |
| C29 | [ ] Yes / [ ] No | Blend modes and isolation | Later | `painting/mix-blend-mode` 20, isolation 2 |
| C30 | [ ] Yes / [ ] No | Markers / arrowheads / context paint | Optional; useful for diagrams | `painting/marker` 63, context 15 |
| C31 | [ ] Yes / [ ] No | Local use/symbol reuse and expansion | Later | `structure/use` 41, symbol 16 |
| C32 | [ ] Yes / [ ] No | Embedded raster images (PNG/JPEG/GIF) | Later; needs decoders | `structure/image` 49 shared cases; explicit embedded PNG/JPEG/GIF fixtures |
| C33 | [ ] Yes / [ ] No | Embedded SVG/SVGZ images | Later | Same image directory includes nested SVG, compressed SVG, recursion and sizing cases |
| C34 | [ ] Yes / [ ] No | External images, CSS, fonts, URL/file loading | No for current confinement goal | External image/CSS fixtures exist; no explicit webfont-loading cases found; do not count deliberate rejection as a fidelity defect |
| C35 | [ ] Yes / [ ] No | Basic filters: blur, drop shadow, offset, flood, merge | Later; choose individually if desired | `filters/feGaussianBlur` 13, feDropShadow 8, feOffset 9, feFlood 8, feMerge 3 |
| C36 | [ ] Yes / [ ] No | Other filters: color matrix, transfer, blend/composite, morphology, convolution, displacement, turbulence, lighting, tile/image | Later; separate implementations | Dedicated directories for these operators; **397 filter examples total**, including the basic-filter rows |

### Text and font compatibility

| ID | Include? | Feature | Suggestion | Local corpus evidence |
|---|---|---|---|---|
| C37 | [ ] Yes / [ ] No | Basic text/tspan, whitespace/entities, coordinates and rotation | Yes | `text/text` 46, tspan 31; explicit whitespace/entities, position lists, rotation |
| C38 | [ ] Yes / [ ] No | Family selection, fallback, size, weight, style, stretch | Yes for defined embedded faces; stretch optional | font-family 12, font-size 20, font-weight 12, font-style 3, font-stretch 3, font shorthand 2 |
| C39 | [ ] Yes / [ ] No | Kerning, letter/word spacing, anchors | Yes | font-kerning 3, kerning 2, letter-spacing 12, word-spacing 7, text-anchor 13 |
| C40 | [ ] Yes / [ ] No | Baselines and baseline shifts | Yes, scoped basics | alignment-baseline 19, dominant-baseline 21, baseline-shift 22 |
| C41 | [ ] Yes / [ ] No | textLength / lengthAdjust | Optional | textLength 12, lengthAdjust 4 |
| C42 | [ ] Yes / [ ] No | Underline/overline/strike-through | Optional | text-decoration 21 |
| C43 | [ ] Yes / [ ] No | Text along paths | Later | textPath 44 |
| C44 | [ ] Yes / [ ] No | Vertical writing / glyph orientation | Later | writing-mode 23, glyph-orientation-vertical 1, horizontal 1 |
| C45 | [ ] Yes / [ ] No | RTL, Arabic/Indic shaping, ligatures, combining marks | Later; much broader than basic text | direction 2, unicode-bidi 1, complex-grapheme/ligature/bidi/Arabic cases in text/text; fonts include Amiri and Noto Sans Devanagari; not exhaustive script coverage |
| C46 | [ ] Yes / [ ] No | Emoji sequences and color glyphs | Later | emojis and compound-emojis fixtures; Noto Emoji/Noto Color Emoji font assets present; per-format coverage unverified |
| C47 | [ ] Yes / [ ] No | Small caps, font-size-adjust, text-rendering hints | Optional | font-variant 2, font-size-adjust 1, text-rendering 5 |
| C48 | [ ] Yes / [ ] No | Broad font-file support: CFF, collections, variable fonts, webfonts | Later; choose formats individually | Text tests do not validate parsers across formats; no font-variation-settings, font-optical-sizing, @font-face or WOFF references found |
| C49 | [ ] Yes / [ ] No | System-font discovery or user font loading | Later; changes resource policy | Font-family fixtures exercise selection, not your filesystem confinement or discovery implementation |

### Browser features and output behavior

| ID | Include? | Feature | Suggestion | Local corpus evidence |
|---|---|---|---|---|
| C50 | [ ] Yes / [ ] No | HTML in foreignObject | No for this release | No foreignObject element found |
| C51 | [ ] Yes / [ ] No | Animation sampled at a selected time | No for this release | No animate/set elements found |
| C52 | [ ] Yes / [ ] No | Scripts/events/interactivity | No; outside static renderer scope | No script elements found; `structure/a` 5 concerns rendering linked content, not interaction |
| C53 | [ ] Yes / [ ] No | Explicit color-interpolation behavior / advanced color management | Optional; separate simple sRGB support from ICC/wide-gamut | color-interpolation mentioned in 60 files and ICC-named paint fixtures exist; this does not establish a color-management conformance suite |
| C54 | [ ] Yes / [ ] No | PNG dimensions, transparency, background, tiles and parallel consistency | Yes; much implemented | Project-owned run_tests/run_tiles and task reports; not established by feature-directory counts |
| C55 | [ ] Yes / [ ] No | Depth/work/storage limits and safe rejection | Yes | Project adversarial harness exists; exact new limit boundaries and shared-budget tests still need adding |

### Five human-review policies, not fifty-five subjective implementations

Most features have concrete oracle output. Human judgment is mainly needed to
choose acceptable approximation/fallback rules, then to label ambiguous cases.
The five practical review buckets are:

1. **Small text:** how much edge difference remains readable and acceptable.
   Compare a shared tight region around the intended text at native size and
   enlarged display size; use fixed fonts. Re-rendering at a higher resolution
   is a separate check and must not hide defects at the intended small size.
2. **Geometry edges:** tolerance for subpixel curve/stroke/cap differences.
   Use edge-distance and coverage error as well as within-8; never independently
   align/crop outputs in a way that conceals a position or size error.
3. **Font substitution:** decide whether a different face is ever acceptable.
   Keep those explicitly approved fallbacks separate from exact-font fidelity.
   Once the font set and fallback policy are fixed, most checks are objective.
4. **Subtle tone/soft effects:** acceptable gradient banding, mask fringes,
   alpha rounding, and eventually blur/shadow differences. Compare alpha and
   composites on both light and dark backgrounds; ignore meaningless RGB
   differences where both pixels are fully transparent.
5. **Ambiguous/unsupported inputs:** decide reject, skip, or an explicit fallback
   where the chosen subset differs from the oracle. Known scope exclusions
   should not enter the ordinary visual-pass queue.

These are five policy families, not a prediction of five reviews or a claim
that every bucket requires manual review forever. Rowan can review roughly
1,000 pictures/day if needed; queue novel/near-threshold failures, cluster
duplicates, and retain approved examples as regression fixtures. Build a
small human-labelled calibration set before choosing numeric thresholds.

### What the current harness does and does not establish

- **Confirmed present for the proposed sprint:** group opacity, linear/radial
  gradients, clipping, alpha/luminance masks, nested SVG, and basic text all
  have dedicated or explicitly named fixtures. Existing interactions include
  clips on transformed text, masks with clips/opacity, and nested viewports.
- **Not exhaustive:** directory presence is evidence of examples, not proof
  of coverage of every attribute, combination, degenerate input, or resource
  limit. Content searches finding no match are recorded as gaps, not a formal
  proof that no equivalent behavior is exercised indirectly.
- **Font setup is not pinned:** run_corpora.py invokes resvg/usvg without
  explicit font arguments. The suite supplies fonts, but the harness does not
  explicitly load that directory or disable machine-dependent selection.
  Configure an identical controlled font set before judging native text;
  confirm which fonts the oracle actually used. File-format/parser fuzz tests
  remain necessary independently of SVG text tests.
- **Whole-image metric can miss missing content:** current scoring uses max
  RGBA channel delta over the entire canvas. Many fixtures include a frame
  and guides; cropping to all non-background pixels can still leave most of
  the canvas. Use a targeted feature region or an isolated text fixture, then
  a common crop covering reference and actual extents. Check missing/extra ink
  and displacement as well as per-pixel tolerance. A missing entire glyph
  must not pass because the background or frame dominates the denominator.
- **Direct and usvg routes answer different questions:** native feature
  support must pass the direct route. A usvg pass can mean the preprocessor
  performed the text/CSS/reuse work. Keep renderer/oracle versions, sizes,
  fonts, and backgrounds fixed for comparable results.
- **Intentional rejection needs its own result class:** recursive references,
  external resources, and depth above ten may be valid oracle inputs but out
  of scope here. Report supported-feature fidelity, expected rejections, and
  the unfiltered full-corpus score separately; do not inflate the latter.
- **Gaps to fill after choices:** add tests for each selected row without
  direct coverage, depth 10/11, shallow-wide documents, repeated mask work,
  total live layer storage, and tile/parallel effects across band boundaries.
  resvg alone is not an oracle for this renderer's resource limits.

## M5 — Full-SVG route via usvg + resvg test suite  [Opus]

- `tests/run_suite.py`: for a checkout of `linebender/resvg-test-suite`
  (`tests/*.svg`, MIT), run `usvg in.svg micro.svg` (usvg ships with resvg;
  install `cargo install usvg` or `brew` if a formula exists), then render
  `micro.svg` with lean-svg and with resvg, compare with the M1 metric. Report
  pass rate per test-suite directory (structure, painting, shapes, ...).
  Text becomes paths through usvg, so `text/` tests become testable.
- Feed failures back as items in M4.

## M6 — Performance  [Opus]

- Benchmark script: render each corpus file 20× with `--width 2000`, report
  median ms for lean-svg vs resvg. Also a 5 000-shape generated file.
- Likely wins, in order: (1) skip rows of the mask that are all zero before
  blending; (2) in `accumPiece`, use `USize` indexing with proofs or keep
  `setIfInBounds` but hoist `base + c`; (3) avoid re-allocating the mask per
  shape by reusing a scratch `Array Int` (thread it through `drawShape`);
  (4) `Canvas.px` as `Array UInt32`? No: `UInt32` boxes in arrays; keep `Nat`.
- Target: within 5× of resvg on the corpus at 2000 px. Report, don't guess.

## M6b — Parallel rendering with `Task`, same theorems  [design done → Opus]

Requested 2026-09-20. Lean's `Task.spawn : (Unit → α) → Task α` and
`Task.get : Task α → α` are *pure*: `Task` is a structure holding its result
and `Task.get (Task.spawn f) = f ()` is definitional. So parallelism lives
inside `render` with no change to its type and no change to `Effect.lean`;
every effect theorem carries over untouched, and totality is unaffected
(each task body is one of our existing total functions).

Design (decided):
1. **Horizontal bands.** Split the canvas into `k` bands of rows
   (`k = min(cores, H / 64)`, never more than 64). For each band, cull shapes
   against the band (T10's test with the band rectangle), render the band as
   its own `Canvas` with the band's translate composed into the root matrix
   (exactly the viewport mechanism of T4, so band borders are byte-identical
   by the same argument), then concatenate the bands' RGBA rows. Blending
   order per pixel is unchanged, so the output is **byte-identical** to the
   serial render; `tests/run_tiles.py`'s stitching check is the test.
2. Wrap each band in `Task.spawn` (priority default), collect with
   `Task.get` in order. Provide `Options.threads : Nat` (0 = serial) so the
   serial path remains available and is the reference.
3. Theorem: `renderPar opts inp = render opts inp` — by unfolding the band
   composition and the `Task.get`/`Task.spawn` identity; if the band
   composition is stated as "concatenate rows of independent band renders",
   the proof reduces to the tile-identity argument (M4-level effort; at
   minimum state it and prove the `Task` layer, leaving band-identity as a
   tested claim).
4. PNG output stays serial (Adler-32 is sequential); T8 made it cheap.
   Later: per-band Adler combination is possible (Adler-32 is combinable)
   if it shows up.
5. Runtime: Lean executables run tasks on a thread pool sized to the
   machine; check `LEAN_NUM_THREADS` behaviour and report scaling on
   `16_stress_2000` at 1600 px for 1, 2, 4, 8 threads. Memory: each band
   canvas is `4·W·rows`, total unchanged.

**Done (T14, 2026-09-20):** `--threads N`, byte-identical, 2.5–3× on 4
threads. Finding for M6: four *processes* scale better (3.4×/4.4×) than
four in-process tasks (2.6×/2.5×), most likely because `Task.spawn` marks
the shared `Doc` multi-threaded and the hot culling/flatten loops then pay
atomic reference counting. Candidate fixes: give each band its own copy of
the shape list (cheap relative to rasterizing), or spawn coarser tasks.
Also: equal-row bands load-imbalance on files like 12_badge; a work queue
of smaller bands would help there. Theorem `renderPar = render` not written;
tested by 1 920 identical renders and `run_tiles.py`.

## M7 — Verified DEFLATE via lean-zip  [Opus after checking the API]

**Promoted to a requirement 2026-09-21, with measured evidence.** The PNG
encoder emits *stored* (uncompressed) deflate blocks, so our output is several
times larger than resvg's for the same pixels. Measured at `--width 800` by
`docs/readme/render.py`:

| image | lean-svg PNG | resvg PNG | ratio |
|---|---|---|---|
| icons (mostly flat colour) | 1626 KB | 30 KB | 55× |
| confetti | 1626 KB | 48 KB | 34× |
| stress (1500 shapes) | 2501 KB | 687 KB | 3.6× |

Flat images are the worst case, because that is exactly what DEFLATE is good
at. The README's committed PNGs are losslessly recompressed for this reason,
which is a workaround, not a fix. This is the largest remaining gap between
"correct" and "usable", and it is the one place a verified dependency exists
and would settle it.

Note for whoever does it: this is also the first dependency the project would
take, so it widens the trusted computing base from "Lean core only". That is
a real trade and should be stated in `SPEC.md` when it lands. A verified
compressor is still far better than an unverified one, and better than
shipping 55× files.

- Add `kim-em/lean-zip` as a Lake dependency; replace `Png.zlibStored` with
  its compressor (zlib framing may or may not be provided; Adler-32 is).
  Keep the stored-block encoder as the default until the size theorem in M3
  is redone for the compressed case (compressed size is not a closed form, so
  M3 becomes an upper bound: `png.size ≤ sizeFor w h`).
- Separately (user): open a PR to lean-zip. Candidate contributions: a zlib
  wrapper if missing, or a fuzz harness like `tests/run_adversarial.py`.

## M8b — CI that enforces the proof boundary  [Sonnet; requested 2026-09-21]

There is no CI yet. The guarantees that matter most are currently kept by
review, which is the weakest link in a repository several agents edit at once.
Turn each into a check that fails the build. See `tasks/T43-ci-proofs.md`.

1. **The theorems still hold, with no holes.** `#print axioms` on all six
   effect theorems must report exactly `[propext]`. `sorryAx` anywhere is a
   failure, which also catches a `sorry` slipped in to make something compile.
2. **The effect type still has exactly two constructors.** `Op` gaining a
   third is the single change that would most weaken the project's claims, and
   nothing would currently catch it.
3. **No IO outside the effect layer.** `IO.` must not appear in any
   `LeanSvg/*.lean` except `Effect.lean`.
4. **The invariants in `tasks/README.md`** that are mechanically checkable:
   no `partial`, `unsafe`, `@[extern]`, `panic!`, `!`-indexing or `Float` in
   `LeanSvg/`.
5. **`lake build` clean**, plus `run_tests.py`, `run_tiles.py`,
   `run_adversarial.py` and `tests/CssTests.lean`.

Items 1 to 4 need no oracle and should run on every push. Item 5 needs resvg
and the test corpora, so it may need a separate job or a cached install.

## M8 — Fuzzing  [Opus]

- `tests/fuzz.py`: mutation fuzzer over the corpus (byte flips, splices,
  number replacement with extreme values, tag duplication). N iterations,
  seeded. Same checks as the adversarial harness. Run for 10 minutes in CI.

## M10 — Rust cores via Aeneas, fixed harness  [deferred, ideation only]

Idea (2026-09-19): one never-changing `main.rs` (read one path, call a pure
core, write one path) plus cores written in safe `no_std` Rust, translated to
Lean by Aeneas and proven against a pre-specified contract (pure, total,
panic-free, output bound). `Effect.lean`'s theorems apply to any core
unchanged. Design in `harness/README.md`, vertical-slice spike spec in
`tasks/T9-aeneas-spike.md`. Not started; revisit once the Lean renderer's
speed work (T6–T8) has reported.

## M11 — Text and fonts, self-contained  [parser in progress; basic text suggested next]

Requested 2026-09-20 as a future requirement ("a functional SVG renderer").
The scoped plan above suggests an initial text slice before the remaining
graphics waves; broad font compatibility remains a later extension.

Design (decided):
- **Fonts are constants.** Embed a fixed set of open-licence fonts (a Latin
  subset of Noto Sans regular/bold/italic, plus the fonts the resvg test
  suite ships in `fonts/` for oracle parity) as byte constants in the
  binary (generate a Lean module from the `.ttf` bytes; ~100 KB each). No
  new effect: the theorems in `Effect.lean` are unchanged. System fonts are
  never read. Optional later: `@font-face` with `data:` URIs from the SVG
  itself, which keeps "one file in" (no resvg oracle for that).
- **Parser (total, bounded):** `head` (unitsPerEm, indexToLocFormat),
  `maxp`, `cmap` (formats 4 and 12), `loca`, `glyf` (quadratic outlines →
  cubics via exact degree elevation; composite glyphs with fuel ≤ 8 and a
  component cap), `hhea`/`hmtx`, `kern` format 0 and GPOS pair adjustment
  (single lookup type, format 1/2). Every table read is bounds-checked;
  every loop bounded by table length. Reject fonts over a size cap.
- **Layout:** `text`/`tspan` with `x y dx dy`, `font-size` (px, em,
  percentages of parent), `font-family` fallback list, `font-weight`
  (400/700) and `font-style` selecting among embedded faces, `text-anchor`,
  `letter-spacing`, `word-spacing`, `baseline-shift`/`dominant-baseline`
  basics, `xml:space`. Shaping is character → glyph plus pair kerning only
  (no ligatures, no complex scripts; report those as out of scope).
- **Rendering:** glyph outlines are `PathCmd`s fed to the existing fill and
  stroke pipeline (text `fill`/`stroke` apply), with the text transform.
- **Later:** `textPath` (glyph placement along a flattened path),
  `text-decoration`, vertical `writing-mode`, CFF (`CFF ` table, Type 2
  charstrings with fuel), `textLength`/`lengthAdjust`.

Tasks: **T25** [Sonnet, started 2026-09-20] font parsing + embedding +
`fontdump`, verified glyph-by-glyph against fontTools and mutation-fuzzed
for totality; T-B [Opus] layout and rendering of `text`/`tspan`; T-C
`textPath`, decorations, vertical; T-D CFF. Measure on
`resvg-test-suite/tests/text/` (356 files) on the direct route; target
60–80% with the suite's fonts.

**TODO (future, requested 2026-09-20): reading system fonts.** Would add a
third operation to the effect monad, `Op.readFont (name : String) : Op
(Option ByteArray)`, interpreted as a read under one fixed font directory
only; theorems generalise to "reads only the input path and files under
the font directory, writes only the output path". Keep behind a flag; the
default stays embedded-fonts-only so the headline claim is unchanged.

## GitHub release — licensing, provenance, and ecosystem credits

Requested 2026-09-20: explicitly thank and cite the projects this renderer
builds on, use compatible licensing, and be a constructive member of their
ecosystems. This is a release checklist and preliminary inventory, not a
completed provenance audit or a declaration that the repository is already
licensed. Only this roadmap was edited. At review time no project LICENSE,
NOTICE, or COPYING file was tracked on main.

### Explain the actual relationship to resvg/usvg

Public scope description: **lean-svg reads a static SVG document and renders
it to PNG in Lean.** It performs the parsing, geometry, rasterization,
compositing, and encoding needed for that conversion. It is not an SVG editor,
diagram authoring system, web browser, or script/animation engine. Temporary
group/layer state is only rendering machinery; an editing model is not a goal.

- The ordinary `lean-svg` executable renders the supplied SVG directly through
  its own Lean XML/SVG/geometry/raster/PNG pipeline. `Main.lean` does not invoke
  usvg. `lake-manifest.json` currently lists no external Lake packages.
- `tests/run_corpora.py` has **direct** and **usvg** routes. The latter invokes
  the external usvg CLI to simplify the document before passing it to lean-svg.
  Both routes compare against the external resvg CLI rendering the original.
  The playground compares browser/resvg/lean-svg directly; it does not invoke
  usvg. These testing tools are not dependencies linked into the Lean renderer.
- Credit resvg as the reference renderer, usvg as the optional preprocessing
  route, and the resvg test suite as a separate source of fixtures. Distinguish
  native support from support supplied by preprocessing in every published
  result. Effect-confinement claims apply to the Lean renderer, not to an
  arbitrary external preprocessing command.
- Runtime dependency independence does not erase source provenance:
  Raster.lean and Canvas.lean explicitly describe ports from tiny-skia/Skia,
  and Geom.lean documents adapted subdivision, stroke, and dash behavior.
  Audit those adaptations even though there is no Rust linking or FFI.

### Preliminary license and credit inventory

Exact local license files were read for the corpora/fonts. Upstream license
pages were checked for other projects on 2026-09-20; verify the actual version
and per-file notices used before release. Repository-wide license labels do
not override separately licensed assets or source files.

| Project/material | Role and license evidence | Release action |
|---|---|---|
| [resvg / usvg](https://github.com/linebender/resvg) | Oracle / optional external preprocessor; upstream workspace specifies `Apache-2.0 OR MIT` in [Cargo.toml](https://github.com/linebender/resvg/blob/main/Cargo.toml) | Thank the original authors and current Linebender maintainers; record tool versions. If bundling binaries or incorporating code, retain the applicable license and all relevant dependency notices. Merely running a separately installed test tool is different from redistribution. |
| [resvg test suite](https://github.com/linebender/resvg-test-suite) | Local `tests/corpora/resvg-test-suite/LICENSE`: MIT, copyright 2018 Reizner Evgeniy | Preserve its full copyright/license with redistributed fixtures or substantial adapted portions; give an explicit README credit. Fonts/resources need their own checks rather than assuming the suite's MIT license covers everything. |
| [tiny-skia / Skia-derived code](https://github.com/linebender/tiny-skia) | [tiny-skia LICENSE](https://github.com/linebender/tiny-skia/blob/main/LICENSE): BSD-3-Clause terms, Google and Yevhenii Reizner notices; code is described locally as ported/adapted | Preserve applicable upstream copyright, conditions and disclaimer for source and binary releases. Map local functions to original files/revisions, including inherited Skia notices. Cite both tiny-skia and Skia; acknowledgement must not imply endorsement. |
| [font-rs](https://github.com/raphlinus/font-rs) | Earlier rasterizer inspiration recorded in DESIGN/PLAN; upstream identifies Apache-2.0, main author Raph Levien | Credit historical inspiration. Inspect history to determine whether any adapted code remains or is distributed in earlier commits/tags; retain applicable Apache license/notices and modification information where required. Do not claim it is a current linked dependency. |
| [Feather](https://github.com/feathericons/feather) | Local LICENSE: MIT, copyright 2013–2023 Cole Bemis; stroke-icon test corpus | Credit creators; preserve copyright/license if redistributing icon fixtures or substantial copies. |
| [Simple Icons](https://github.com/simple-icons/simple-icons) | Local LICENSE.md: CC0-1.0; logo/icon test corpus | Credit the project voluntarily and retain provenance. CC0 does not waive trademark rights; check per-icon metadata/guidelines before using brand images in public galleries or promotion. |
| Embedded Noto Sans subsets | T25 regular/bold/italic byte modules plus LICENSE-OFL.txt; SIL OFL-1.1 | Font data remains OFL, including generated Lean byte constants. Record original font source/version/hash, copyright notices, subset command and modifications. Check exact fonts for Reserved Font Names before naming redistributed subsets. |
| Other suite fonts | Local OFL files for Amiri, MPLUS1p, Sedgwick Ave Display and Source Sans Pro; Yellowtail has an Apache-2.0 license file | Inventory each font actually shipped/embedded. Source Sans Pro's local notice reserves the name `Source`; do not assume all subset names are unrestricted. Preserve each font's own notices; do not silently relicense fonts under the code license. |
| [Lean 4](https://github.com/leanprover/lean4) | Compiler/core/runtime; [Apache-2.0](https://github.com/leanprover/lean4/blob/master/LICENSE) | Credit Lean and record toolchain version. Audit notices for the runtime and other components incorporated into distributed binaries, not just the empty Lake dependency list. |
| Python test/font-generation tools | NumPy, Pillow and fontTools are used by the harness/generator rather than the Lean executable | Record actual package versions and licenses. Include notices for any redistributed packages/code; separately installed development tools should be identified accurately. This review did not audit their installed transitive dependencies. |
| Future dependencies | lean-zip, Aeneas and other roadmap ideas are not established current dependencies | Add license/provenance entries only when actually used. Audit any imported code, fonts, images, docs or fixtures before publishing them. |
| Planned CSS work | `tasks/T29-style-element-css.md` points to [simplecss](https://github.com/linebender/simplecss) | If that work adapts implementation rather than only consulting semantics, record the exact source/revision and verify its license and notices before landing/releasing it. Its license was not verified in this review. |

License details to consult: [resvg MIT text](https://github.com/linebender/resvg/blob/main/LICENSE-MIT),
[OFL official terms](https://openfontlicense.org/open-font-license-official-text/),
and [OFL FAQ](https://openfontlicense.org/ofl-faq/).

### Compatible project license suggestion

Recommend **Apache-2.0 for original lean-svg code**, subject to completing the
source provenance review. It provides a permissive contribution path alongside
the identified MIT/BSD material and Apache-licensed tooling/inspiration. Keep
the upstream MIT/BSD/Apache obligations and asset licenses explicitly attached
to their material; a project-level license does not replace them. Using the
MIT test suite does not by itself require choosing MIT for all renderer code.
This is a recommendation, not a license selection made on Rowan's behalf.

**Porting tiny-skia is permitted:** its BSD-3-Clause terms allow redistribution
and modification, including an adapted implementation in another language.
Retain the applicable copyright notices, license conditions and disclaimer in
source distributions and with binary distributions; do not imply upstream
endorsement. Original additions may use the chosen project license, but a
translation to Lean does not remove the BSD obligations for adapted material.
Credit this as a port/adaptation, not a wholly original rendering algorithm.

Font software remains under its original font license. Bundling OFL font data
does not require placing the renderer's original code or ordinary rendered
images under OFL. Subsetting is modification: check copyright and naming terms
for the exact font files. The copied T25 OFL text lacks a font-specific copyright
heading, so recover/verify the original notices (including font metadata) and
ship them in an accessible form rather than assuming generic license text is
the complete attribution package.

### Check for other Lean SVG code and accidental uncredited reuse

Preliminary review on 2026-09-20 examined local imports/package metadata,
source comments/task reports and git history, plus public searches for Lean
SVG/rasterizer projects. The initial implementation is commit `f94e1a2`;
later commits explicitly identify tiny-skia work, including `7890a46` (scan
conversion), `58b1290` (blending), `0f8c186` (hairlines), and `86140cd`
(cubic subdivision). No external Lean packages are declared in the inspected
main build, and no recorded use of the following projects was found:

- [ProofWidgets](https://github.com/leanprover-community/ProofWidgets4): the
  inspected [Svg.lean](https://github.com/leanprover-community/ProofWidgets4/blob/main/ProofWidgets/Data/Svg.lean)
  constructs SVG/HTML elements for display, using a different API and Float
  coordinates. It is not an SVG-input-to-PNG rasterizer like this project.
- [Illuminate](https://github.com/leanprover/illuminate): a Lean diagramming
  library with SVG output; its documented visual tests render via Inkscape.
  Its stated role differs from this project's input parser/rasterizer.

This check found no evidence of reuse from those projects. It did not perform
an exhaustive clone-detection audit, inspect every historical source available
to earlier agents, or prove originality of agent-generated code. Public search
is incomplete; do not advertise "the first Lean SVG library" or "no code was
copied" on that basis. Another library's existence does not imply copying;
shared SVG terminology, standard formulas, and common algorithms are not by
themselves evidence of copied implementation. Related work can be cited as
related work without falsely listing it as a dependency or source.

For future agent work, record sources when consulted or adapted: repository,
file, revision, license, and local affected functions. Preserve source notices
when adapting code, Lean or otherwise. If a suspiciously distinctive block
matches another project, compare the actual implementations/history and resolve
provenance before publishing it; do not merely rename variables or remove the
attribution. Explicitly identify inspiration, adapted code, tools, and test
assets as different kinds of contribution. The task is accurate provenance,
not avoiding legitimate reuse of permissively licensed work.

### Before publishing source or release binaries

- [ ] Choose the original-code license and add its full text at repository root.
- [ ] Create a third-party notice/provenance document and retain full applicable
  license texts, copyright notices, and relevant upstream NOTICE contents.
  A friendly README thank-you is additional to required license notices.
- [ ] Audit adapted Raster/Canvas/Geom code and other copied material against
  exact upstream files. T17 records tiny-skia revision `5d47547`; resolve the
  full revision and check that version's headers/license. That exact revision
  was not fetched successfully during this review; current upstream license
  verification is not a substitute. Check modifications and older distributed
  history as well as the final tree.
- [ ] Record font provenance, subset hashes/commands, original notices, and
  any required name changes. Check generated byte modules and release binaries.
- [ ] Keep external corpora fetched separately by default, as the current
  `.gitignore` does; document pinned revisions and reproducible acquisition.
  If fixtures, resources, comparison images or datasets are copied into the
  public repo/release/site, retain applicable attribution and review the asset
  rights. Generated PNGs are not automatically free of source artwork rights.
- [ ] Include notices in release archives/installers, not only on GitHub.
  Inventory what each artifact actually bundles, including runtime libraries,
  fonts and any external CLI tools. Do not present this preliminary table as
  a complete software bill of materials.
- [ ] Add README acknowledgements linking resvg/usvg, the test suite,
  tiny-skia/Skia, font-rs where relevant, Lean, font authors and icon projects.
  State what each contributed and avoid suggesting sponsorship or endorsement.
- [ ] Publish comparisons with versions/commits, font configuration, image
  sizes, tolerance, exclusions, and direct/usvg routes clearly distinguished.
  Describe visual agreement as empirical evidence, not proof of SVG correctness
  or proof that this project is more secure than upstream.
- [ ] When useful bugs or missing cases are found, prepare minimal reproducible
  examples and offer them upstream under the target project's contribution
  rules. Discuss uncertain oracle behavior respectfully; first rule out local
  bugs and environment/font differences. No outreach is authorized by this
  checklist alone.

Suggested README acknowledgement wording (adapt to what actually ships):

> lean-svg is a static SVG renderer written in Lean. We thank the resvg and
> usvg authors and Linebender maintainers for the reference renderer, optional
> preprocessing tools, and publicly available resvg test suite. Rendering
> algorithms include adaptations of tiny-skia/Skia, with earlier inspiration
> from font-rs. We also thank the Lean community, the authors of our bundled
> fonts, and the Feather and Simple Icons contributors. Upstream projects and
> assets retain their respective licenses; see the third-party notices.

## M9 — Write-up  [user]

Design and results, in the user's own words. `DESIGN.md` has the material.

---

## Decisions that are settled (do not relitigate in delegated work)

1. **Fixed point, no floats.** `Fx = Int`, 8 fractional bits; matrices 16.16.
   Lean's `Float` is opaque and admits NaN/Inf; integers are provable and
   deterministic.
2. **Hot loops in `Nat`.** Lean's unboxed `Int` is 31-bit on 64-bit hosts,
   `Nat` is 63-bit. The rasterizer clips to the canvas so all coordinates are
   non-negative before the per-row loop.
3. **Event-based XML, no tree, no DTD.** Rejecting `[` in DOCTYPE is the
   whole XXE/billion-laughs defence. Current depth cap 64, element cap
   1 000 000; the scoped plan proposes depth 10 plus total work/storage caps.
4. **Accumulation rasterizer** (font-rs scheme) with exact per-column area.
   Even-odd via triangle fold of the accumulated winding.
5. **Strokes are unions of consistently oriented polygons** filled nonzero.
6. **Trusted computing base:** Lean compiler + runtime, the C compiler,
   `Prog.execIO` (6 lines), `Main.lean` (arg parsing), the OS.
7. **Every loop is a `for` over a finite range**, so termination is
   structural. Never introduce `partial`.
8. **Resource caps:** output ≤ 16384 px per edge and ≤ 16 Mpx; numbers clamp
   to ±2^22 px; 18 significant digits; exponents saturate.
