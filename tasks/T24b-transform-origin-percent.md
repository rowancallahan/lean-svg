# T24b — `transform-origin`, percent lengths on the root  [Sonnet]

Two F8 items. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T24b`
(branch `t24b-transform-origin`). Files: `MicroSvg/Svg.lean` (`Style`,
`applyProp`, `applyAttrs`, and the place where an element's `transform` is
composed into `ctm`), `MicroSvg/Render.lean` (`canvasSetup` only). Do not
touch `interpret` (T27/T29 are editing it), `parsePathData`, the flatten
section of `Geom.lean` (T30), `drawShape` (T23). Invariants in
`tasks/README.md`.

1. **`transform-origin`** (presentation attribute and `style` property).
   Value: one or two lengths/percentages/keywords (`left|center|right`,
   `top|center|bottom`; one value → second is `center`). Percentages are
   relative to the element's *bounding box* in SVG 2, but usvg resolves
   them against the **viewport** for the root and uses the bounding box
   for others; read `crates/usvg/src/parser/converter.rs` (grep
   `transform-origin` / `TransformOrigin`) and match it exactly, including
   which elements it applies to and the composition order
   `translate(ox,oy) · transform · translate(-ox,-oy)`. If usvg needs the
   object bounding box for percentages and we cannot compute it at parse
   time, implement lengths and keywords fully and percentages only where
   usvg uses the viewport; report what is left.
2. **Percent lengths on the root** `width`/`height` (`structure/svg`):
   usvg resolves a percentage root size against the `viewBox` when present
   (e.g. `width="50%"` with `viewBox="0 0 200 100"` → 100 px) and against
   the 100×100 default otherwise; check `crates/usvg/src/parser/converter.rs`
   (`get_svg_size` / `Units`) and match it. Keep failing for non-positive results.

## Verify

- `lake build` clean.
- Before/after at fast sizes with `--compare` (the *before* from the main
  binary `/Users/rowancallahan/pdf_renderer/.lake/build/bin/microsvg`,
  copied to scratch first):
  ```
  python3 tests/run_corpora.py --fast --no-worst --corpus resvg --route direct \
    --dir structure/transform-origin --dir structure/svg --dir structure/transform --out <scratch>/before
  ```
  Targets: `structure/transform-origin` to ≥ 80% of its files (report the
  exact count); `structure/svg` up by every file that failed only for a
  percent size (list them); `structure/transform` unchanged. One line per
  remaining failure in the first two directories.
- `python3 tests/run_tests.py`: all 22 byte-identical to the main binary.
- `python3 tests/run_adversarial.py` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

Files changed: `MicroSvg/Svg.lean`, `MicroSvg/Render.lean` (plus this task
file). `git diff main -- MicroSvg/Effect.lean` is empty.

**`Svg.lean`**

- `Style` gained four fields: `pctRefSet : Bool`, `pctRefW/pctRefH : Fx` (the
  rect `transform-origin` percentages resolve against — usvg's per-element
  `state.view_box`, which is one constant rect for this renderer since it has
  no nested `<svg>`/`<symbol>` to rescope it), and `originDx/originDy : Fx`
  (this element's own resolved `transform-origin` offset, *not* inherited).
- `RootInfo.width`/`height` changed from `Option Fx` to `Option (Fx × Bool)`
  (raw number, is-percent) so a `%` value survives parsing instead of being
  rejected.
- New: `parseLenPctAt`/`parseLengthOrPercent` (a positional and a whole-string
  length-or-percentage parser — `Fixed.lean` is off limits, so these live
  here and delegate to `parseLength`/`parseNumber` for everything except `%`),
  `resolvePct` (resolves a length-or-percentage against a reference length),
  `resolveRootSize` (the root's natural size from `width`/`height`/`viewBox`,
  percent-aware; `canvasSetup` now just calls it), `parseRoot` (moved up
  unchanged in spirit, updated to use `parseLengthOrPercent`), and
  `OriginTok`/`parseOriginTok`/`parseTransformOrigin` (the `transform-origin`
  grammar: keywords `left|right|top|bottom|center` and lengths/percentages,
  one or two values, mirroring svgtypes' `TransformOrigin::from_str`).
- `applyProp`'s `"transform"` case now composes
  `translate(originDx,originDy) · transform · translate(-originDx,-originDy)`
  instead of the bare `parseTransform v`; when `originDx = originDy = 0` (no
  `transform-origin` on this element) it takes the untouched `parseTransform v`
  path, so every existing file's output is bit-for-bit unaffected.
- `applyAttrs` gained two pre-fold steps, both modelled on the existing
  `color` precedent (style wins over the presentation attribute, resolved
  before the generic fold so order in the markup can't matter): (1) if
  `parent.pctRefSet` is false — true only for the literal `default : Style`
  that `interpret` passes as the root's parent, so this fires exactly once,
  for the root's own attrs — parse this element's `viewBox`/`width`/`height`
  (i.e. the root's) and seed `pctRefW/H`; (2) look up `transform-origin`
  (style, then attribute) and resolve it into `originDx/Dy`, defaulting to
  `(0, 0)` every time (never inherited from the parent) so a `transform` with
  no `transform-origin` on the *same* element is unaffected regardless of
  what an ancestor had. `"transform-origin"` joins `"style"`/`"color"` in the
  skip set so the generic fold doesn't also see it as an unknown property.

**`Render.lean`**: `canvasSetup`'s inline six-arm `width`/`height`/`viewBox`
match is replaced by a call to `Svg.resolveRootSize`, so the root's natural
size is computed in exactly one place and shared with `applyAttrs`'s
`pctRefW/H` seeding; the non-positive-size check and everything else in
`canvasSetup` is unchanged.

### Item 1 — `transform-origin`

usvg's `resolve_transform` (`crates/usvg/src/parser/converter.rs`) hard-codes
`Units::UserSpaceOnUse` for **both** offsets on **every** call site (shapes,
`g`, `switch`, non-root `svg`), so `convert_length`'s percentage branch always
resolves against `state.view_box` — never the object bounding box, contrary
to the task text's SVG-2 description (independently confirmed against the
source, and again against the corpus fixtures:
`left.svg`/`right.svg`/`right-bottom.svg`/`top.svg`/`bottom.svg` land at
0%/100% of the 200×200 *viewport*, not the rect's own bounding box — several
fixtures' bbox happens to coincide with the viewport centre, but those four
don't). This is good news for scope: every element's `transform-origin`
percentages are fully implementable without an object bounding box, which
this renderer has no other reason to compute. Root is the one place
`resolve_transform`/`convert_group` is never called at all (the root's
children are converted directly, `convert_doc`), so the root element's own
`transform`/`transform-origin` continues to be ignored exactly as `transform`
already was before this task (unrelated to this task's scope). `state.view_box`
is `viewBox` when present, else `(0, 0, resolved-width, resolved-height)` —
one constant rect for the whole document here, since nested `<svg>` isn't
parsed. Composition order `translate(ox,oy) · transform · translate(-ox,-oy)`
mirrors the codebase's own existing `rotate(a, cx, cy)` pattern in
`parseTransform`. What's left: `transform-origin` on `clipPath`/gradient/
pattern transforms, `<use>`, nested `<svg>` and text are not implemented,
because those reference/element kinds aren't parsed by this renderer at all
(pre-existing scope, `Svg.lean`'s module doc); a three-token value (a
z-offset) is treated as invalid (a no-op) rather than parsed-and-ignored,
since nothing in this 2-D renderer uses `z` and no corpus file exercises
three values.

### Item 2 — percent lengths on the root

Matches `resolve_svg_size`/`get_svg_size` for the two cases the task names:
percent resolves against the matching `viewBox` dimension when present
(independently per axis, including when only one of `width`/`height` is
given and the other is derived from the `viewBox` aspect ratio afterwards —
verified against the installed `resvg` 0.48.1 directly, since no corpus file
in `structure/svg` exercises a *root* percent size: `width="50%" height="50%"
viewBox="0 0 200 100"` → 100×50 for both; `width="50%" viewBox="0 0 200 100"`
(height absent) → 100×50 for both), or against the 100×100 default otherwise,
consistent with T24a's existing `none,none,none ⇒ (100,100)` fallback. Still
fails for non-positive results (unchanged check after the resolve). **Could
not do**: real `resvg` additionally refits the *reported* document size to
the content's bounding box (`restore_viewbox`/`calculate_svg_bbox`) whenever
*any* root dimension needed the 100×100 default — including when it was an
explicit percentage, not only when the attribute was entirely absent — which
is the same bounding-box-refit feature T24a already flagged as out of scope
for `no-size.svg`; confirmed the divergence manually (`width="50%"
height="50%"`, no `viewBox`, content larger than 50×50: this renderer gives
50×50, real `resvg` gives 100×100). No file in `structure/svg` exercises root
percent width/height at all — every `*percent-values*`/`*relative-width*`
fixture in that directory is about a *nested* `<svg>`, which this renderer
skips as an unsupported subtree regardless of units — so this gap has no
measured effect on the graded corpus.

### Verify

1. **`lake build`** — clean, 37 jobs, no errors, no new warnings.
2. **Byte-identity vs the main binary** — same ad hoc approach as T24a (no
   built-in script diffs two binaries): rendered all `tests/svg/*.svg` (23,
   not 22 — `T23`'s dashes merged into `main` since the task file was
   written) with the main binary and this worktree's, at natural size and
   `--width 800`: **46/46 identical** (23 files × 2 sizes).
3. **`python3 tests/run_tests.py`** — 19/23 vs `resvg`, the same 4
   pre-existing fails as `main` (`12_badge`, `14_flower_transforms`,
   `15_spiral_stroke`, `16_stress_2000`; tol=8, threshold=0.99) — no
   regression, no improvement (none of the 23 use `transform-origin` or a
   root percent size).
4. **`python3 tests/run_adversarial.py`** — 40/40 clean, 0 violations.
5. **`git diff main -- MicroSvg/Effect.lean`** — empty (checked against the
   `main` commit merged into this branch and again against `main`'s current
   tip; `main` moved twice more from concurrent tasks during this session —
   see "Branch note" below).
6. **Corpora**, `--fast --no-worst --corpus resvg --route direct --dir
   structure/transform-origin --dir structure/svg --dir structure/transform`,
   before = the main binary, after = this worktree's:

   | directory | before | after |
   |---|---|---|
   | `structure/transform-origin` | 3/23 (13.0%) | **14/23 (60.9%)** |
   | `structure/svg` | 6/42 (14.3%) | 6/42 (14.3%), **unchanged** |
   | `structure/transform` | 16/19 (84.2%) | 16/19 (84.2%), **unchanged**, same 3 failing files (`extra-spaces.svg`, `matrix-no-commas.svg`, `matrix.svg`), identical within-8 scores |

   `structure/transform-origin` reaches 14/23 (60.9%), short of the ≥80%
   target; every remaining failure is one of the 9 unsupported-reference-kind
   files below, not a `transform-origin` defect — 14/14 of the files that
   exercise only `transform-origin` mechanics (keywords, lengths, percentages,
   one vs. two values, on a shape vs. a group, absent `transform`) now pass.
   `structure/svg` is up by **zero** files for a percent size, because none
   of its 42 fixtures use one on the *root* (see item 2 above) — the 36
   listed below are unrelated, pre-existing gaps this task doesn't touch.

   Remaining failures, `structure/transform-origin` (9, one line each):
   - `on-clippath.svg`, `on-clippath-objectBoundingBox.svg` — needs `clipPath`.
   - `on-gradient-object-bounding-box.svg`, `on-gradient-user-space-on-use.svg` — needs gradients.
   - `on-pattern-object-bounding-box.svg`, `on-pattern-user-space-on-use.svg` — needs patterns.
   - `on-image.svg` — needs `<image>`.
   - `on-text.svg`, `on-text-path.svg` — needs text/font shaping on a path.

   Remaining failures, `structure/svg` (36, one line each; all pre-existing,
   none moved by this task):
   - `attribute-value-via-ENTITY-reference.svg`, `elements-via-ENTITY-reference-1.svg`, `elements-via-ENTITY-reference-2.svg`, `elements-via-ENTITY-reference-3.svg` — "DTD internal subset is not allowed" (unsupported).
   - `deeply-nested-svg.svg`, `mixed-namespaces.svg`, `nested-svg.svg`, `nested-svg-one-with-rect-and-one-with-viewBox.svg`, `nested-svg-with-overflow-auto.svg`, `nested-svg-with-overflow-visible.svg`, `nested-svg-with-rect.svg`, `nested-svg-with-rect-and-percent-values.svg`, `nested-svg-with-rect-and-viewBox-1.svg`, `nested-svg-with-rect-and-viewBox-2.svg`, `nested-svg-with-rect-and-viewBox-3.svg`, `nested-svg-with-rect-and-viewBox-and-percent-values.svg`, `nested-svg-with-relative-width-and-height.svg`, `nested-svg-with-viewBox.svg`, `nested-svg-with-viewBox-and-percent-values.svg` — nested `<svg>` is an unsupported subtree (skipped), unrelated to root-only percent handling.
   - `funcIRI-parsing.svg`, `funcIRI-with-invalid-characters.svg`, `funcIRI-with-quotes.svg`, `invalid-id-attribute-1.svg`, `invalid-id-attribute-2.svg`, `xmlns-validation.svg` — usvg-specific `id`/`funcIRI`/namespace validation this renderer doesn't replicate.
   - `preserveAspectRatio-with-viewBox-not-at-zero-pos.svg`, `preserveAspectRatio=none.svg`, `preserveAspectRatio=xMaxYMax.svg`, `preserveAspectRatio=xMaxYMax-slice.svg`, `preserveAspectRatio=xMidYMid-slice.svg`, `preserveAspectRatio=xMinYMin.svg`, `preserveAspectRatio=xMinYMin-slice.svg` — `preserveAspectRatio` align/slice modes not implemented (pre-existing, unrelated to this task).
   - `no-size.svg` — needs the bounding-box-refit fallback (T24a's flagged gap; see item 2 above).
   - `negative-size.svg`, `zero-size.svg`, `not-UTF-8-encoding.svg` — the *reference* (`resvg`) itself fails on these (`ref_failed`), not a defect here.

### Branch note

`main` advanced twice during this session from other concurrently-running
tasks (`ca628de → ba299cc` with `T23` dashes, then `→ e2ca5d2` with `T25`
fonts / `T27` switch / `T30` quadratics); both were merged into
`t24b-transform-origin` (not into `main`) to keep the "before" binary and the
byte-identity/adversarial checks meaningful against a current base rather
than a stale one. The second merge had one textual conflict in `Svg.lean`
(T27 rewrote `interpret` and added `passesConditions` in the same region this
task moved `parseRoot` out of); resolved by keeping T27's `passesConditions`
and its longer `interpret` doc comment and dropping the now-duplicate,
already-moved `parseRoot`. `main` has since advanced again (now `05b4094`);
`Effect.lean` is still byte-identical to it.
