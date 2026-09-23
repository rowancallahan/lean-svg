# D-structure — near-miss diagnosis

Diagnosis only; no `LeanSvg/*.lean` files touched. All four files render at
`--width 200` against `resvg -w 200`; scores below match the task's stated
baseline. `docs/near-miss/D-structure.png` is resvg | ours | diff, one row
per file in the order below, ×4 gain on the diff panel (`tests/run_tests.py`
conventions).

No other agent's branch currently touches any of these four files (checked
`tasks/*.md` and the sibling `claude/beautiful-brown-nd2o1h` branch, which is
the D-*/T-* task-authoring branch, not a fixer). Two of the four causes are
independently corroborated by prior, unrelated diagnoses already in the repo
(`tasks/T83-misc-b.md`, `tasks/T49-masks.md`, `tasks/T44-integer-composite.md`)
— cited below rather than re-derived from scratch, alongside the fresh
evidence gathered for this task.

## `masking/mask/with-opacity-1.svg` (0.952)

**Cause.** Not a masking bug. `rect2` is `fill="green" mask="url(#mask1)"
opacity="0.5"` — a *group* opacity on the masked element, composited by
`Canvas.compositeLayer`/`blendOverScaled`/`storeQ`
(`LeanSvg/Canvas.lean:155`, `:173`). At `opacity = 0.5` exactly, `storeQ`'s
round-half-to-even hits a real tie in a handful of premultiplied-channel
values and rounds the other way from resvg's actual (non-idealised) `f32`
pipeline, a **premultiplied difference of exactly 1**. Verified directly:

```
max premultiplied RGBA diff over the whole 200×200 render: 1.08 (of 255)
pixels with premultiplied diff > 1.5: 0
pixels with straight-alpha diff > tol(8): 1920
```

`lg1`'s mask (`white,opacity 0` → `black,opacity 1`) makes `rect1`'s luminance
`255·t·(1−t)`, a parabola in the gradient direction that is small (peaking at
32/255 at the very centre) over the whole 160×160 masked region — so the
masked layer's resulting alpha is low (≈3–32) almost everywhere. Converting
that low-alpha premultiplied canvas to the straight-alpha PNG divides by
alpha, and at alpha 13 one premultiplied level is `255/13 ≈ 20` straight
levels — turning an invisible ±1 premultiplied rounding difference into a
visible, over-tolerance one on ~1 900 pixels (13.5% of the masked region;
every offending pixel's straight-alpha value is exactly 1 unit off before
amplification).

This is the exact mechanism `tasks/T49-masks.md` (`## Report`, "Still failing
in `masking/mask`") already named for this same file — "not mask errors:
every differing pixel is alpha ±1 at alpha ≈ 6–30, amplified by
un-premultiplying" — and traced to `tasks/T44-integer-composite.md`'s own
accepted residual: `storeQ` computes the *exact-rational* answer for
`round_to_nearest_even(source-over at group opacity)`, which is only an
approximation of resvg/tiny-skia's literal chained-`f32`-multiply rounding;
T44 measured it at "off by at most 1 on 0–0.4%" of a typical layer's pixels
and kept it (a real, `07_opacity`-class artifact, not new). This file is
close to a worst case for it: a mask that keeps almost the entire region at
very low alpha, where every stray ±1 gets maximally amplified.

**Code location.** `LeanSvg/Canvas.lean:155` (`storeQ`), `:173`
(`blendOverScaled`), reached from `LeanSvg/Render.lean:810`
(`compositeLayer ... parent.opacity parent.opacityQ parent.blend`) —
`opacityQ` at `LeanSvg/Render.lean:456` quantises `0.5` onto `opGrid`, which
is exactly the tie case `storeQ` cannot land bit-for-bit without resvg's own
literal `f32` op sequence.

**Proposed fix.** None known that fixes this without cost: reproducing
resvg/tiny-skia's *literal* multi-step `f32` arithmetic (rather than the
exact-rational shortcut) for the general layer composite would need the same
kind of per-step `F32` emulation `LeanSvg/Mask.lean`'s `lumaF32`
(`:140`–`:150`) already does for mask luminance, but for the hot per-pixel
`compositeLayer` path used by every opacity/blend layer in the renderer —
a much larger surface to get bit-exact and a real perf cost if applied
unconditionally. A scoped version — only the low-resulting-alpha pixels
(where amplification matters) fall back to literal `f32` steps, everything
else keeps `storeQ`'s fast path — is the pragmatic version, but still needs
resvg/tiny-skia's real op order confirmed from source and re-verified against
T44's full byte-identity sweep (`painting/mix-blend-mode/opacity-on-group.svg`
and friends) to avoid regressing what T44 already fixed.

**Size.** Medium/large, and low value: this is a documented, ~4-year-old-in-
project-time accepted residual (T44 → T49), not a fresh regression, and the
fix is a hot-path rewrite for a handful of over-amplified pixels on files
whose masks happen to sit almost entirely at very low alpha.
`masking/mask/with-opacity-3.svg` (0.888, not in this task's list) fails for
the identical reason — same group, same fix, if ever done.

## `structure/svg/mixed-namespaces.svg` (0.965)

**Cause.** XML namespace resolution is entirely absent from the renderer.
`text2`'s child `<a id="a2" xmlns="http://example.org/notsvg" ...>Invalid</a>`
redefines the *default* namespace to a non-SVG URI, which per XML namespace
rules takes `<a2>` itself out of the SVG namespace — a conforming renderer
drops it and its "Invalid" text entirely, which is what `resvg` does (solid
green "Valid", confirmed by the reference render: no red anywhere).
`text1`'s sibling `<a id="a1">` only binds unrelated prefixes
(`xmlns:toto`/`xmlns:dahut`), so its default namespace is still SVG, and
"Valid" (green) renders normally in both.

Our renderer tracks no namespace concept anywhere in the XML/SVG pipeline, so
it treats both `<a>` elements as plain pass-through containers regardless of
`xmlns`, rendering "Valid" and "Invalid" on top of each other at the same
`x="100" y="100"` (visible in the composite: `ours` shows the two strings
overlaid; the diff panel isolates "Invalid" in red, i.e. exactly the one
string that a namespace-aware renderer would have dropped).

This is the *same root cause*, independently diagnosed, as
`structure/svg/xmlns-validation.svg` in `tasks/T83-misc-b.md`'s `## Report`
— which explicitly names `mixed-namespaces.svg` as sharing it ("not in this
task's list but shares the identical root cause and fix") — and reaches the
same conclusion here.

**Code location.** `LeanSvg/Xml.lean:45` (`Xml.localName` strips every
prefix at tokenise time, unconditionally, for element names); no namespace
resolver anywhere in `LeanSvg/Svg.lean`'s `interpret` walk (attributes keep
their raw, possibly-prefixed name; nothing resolves `xmlns`/`xmlns:*`
bindings against any element or attribute).

**Proposed fix** (per T83, unchanged here): (1) `Xml.lean` — stop discarding
the prefix at parse time, so `Event.open_`/`.close` carry enough to resolve
namespaces later; (2) `Svg.lean` — track a default-namespace/prefix map per
element through `interpret`'s walk (inherited, reset by any `xmlns*`
attribute on that element, not unlike `xml:space`), resolve every element's
and every namespaced attribute's (`xlink:href` etc.) effective namespace
against it, and drop anything outside SVG (or XLink, for attributes); (3)
every other pass sharing the same flat event stream and dispatching on bare
local name needs the identical gating to stay consistent (`defsScan`,
`Use.expand`, `Filter.scan`, `Pat.Defs.build`, `textPathTables`, CSS
element-chain matching) — an `id`/`href` inside a namespace-shadowed subtree
must not be referenceable, exactly as it must not be paintable.

**Size.** Large: a cross-cutting parser-representation change plus a new
resolution pass threaded through every dispatch site that currently assumes
bare local names, for one file in the whole corpus whose default namespace is
shadowed this way (T83's own count). Out of proportion for this file alone;
T83 already reached and documented the identical conclusion.

## `structure/systemLanguage/on-tspan.svg` (0.952)

**Cause.** `tspan2`'s `systemLanguage="ru-RU"` conditional attribute is never
checked. `passesConditions` (`LeanSvg/Svg.lean:2272`) implements exactly this
— `systemLanguage`/`requiredFeatures`/`requiredExtensions` — matching usvg's
`is_condition_passed` (`crates/usvg/src/parser/switch.rs:61`), and is already
called for `<switch>` children, the root `<svg>`, and most non-text elements
(`LeanSvg/Svg.lean:3073`, `:3596`, `:3700`, `:3718`, `:3736`, `:3783`,
`:3845`, `:3907`, `:4049`). But the text-span walk that builds `tspan`/`a`/
`textPath` visibility (`LeanSvg/Svg.lean:2911`–`:2947`) computes

```
let rend := (rendStack.back?.getD true) && !isDisplayNone attrs
```

— `display:none` only, `passesConditions` not consulted at all — so
`tspan2` renders unconditionally.

Confirmed against usvg source: `is_visible_element`
(`crates/usvg/src/parser/converter.rs:356`) is
`display != "none" && has_valid_transform && is_condition_passed(...)`, and
`collect_text_chunks_impl` (`crates/usvg/src/parser/text.rs:221`) calls it on
every span's parent — `if !parent.is_visible_element(...) { chars_count +=
...; continue }` — i.e. `systemLanguage` hides a span's *glyphs* exactly like
`display:none` while its characters keep their slots in the position list
(the same behaviour our own doc comment at `Svg.lean:2925` already describes
for `display:none`, just missing the other half of usvg's check). Both
`tspan1` (no condition) and `tspan2` (`systemLanguage="ru-RU"`, assumed
system language `en-US`) share `x="32"`, so with `tspan2` wrongly kept
visible it paints over `tspan1` in document order — green "Text" replaced by
red "Text", exactly the observed diff.

**Code location.** `LeanSvg/Svg.lean:2931`.

**Proposed fix.** One-line: `let rend := (rendStack.back?.getD true) &&
!isDisplayNone attrs && passesConditions attrs`. `passesConditions` is
already defined, already used for every other conditional-processing site,
and takes exactly `attrs : Array Xml.Attr`, already in scope at this call
site — no new plumbing.

**Size.** Tiny (1 line).

## `structure/transform-origin/on-text-path.svg` (0.962)

**Cause.** The path `pathForText1` (`transform="rotate(90)"
transform-origin="center"`) is used two ways: rendered directly as a visible
`<path stroke="gray">`, and referenced by `<textPath xlink:href=
"#pathForText1">` for laying text along it. Only the first goes through the
general per-element transform pipeline
(`LeanSvg/Svg.lean:3398`–`:3401`, composed in `applyProp`'s `"transform"`
case at `:2034`–`:2045` as `translate(originDx,originDy) · transform ·
translate(-originDx,-originDy)`), which correctly resolves `transform-origin:
center` against the viewBox (200×200 here) to `(100, 100)` — confirmed
against `usvg -w`'s own resolved tree, which emits `matrix(0 1 -1 0 200 0)`
for this same path, exactly `translate(100,100)·rotate(90)·translate(-100,
-100)`, folded by usvg's shared `resolve_transform`
(`crates/usvg/src/parser/converter.rs:1100`, called for the `textPath`'s
linked shape too, at `crates/usvg/src/parser/text.rs:369`
`linked_node.resolve_transform(AId::Transform, state)`).

The *second* use — `textPathTables` (`LeanSvg/Svg.lean:2698`), which builds
the arc-length table `Text.Ev.openPath` walks to lay glyphs along the path —
parses only the raw `transform` attribute and ignores `transform-origin`
completely:

```
let m := match attr attrs "transform" with
  | some t => parseTransform t
  | none => Mat.identity
```

(`LeanSvg/Svg.lean:2717`–`:2719`). For this file that is `rotate(90)` about
`(0, 0)` — the SVG user-space origin, not the viewBox centre — instead of
`matrix(0 1 -1 0 200 0)`. Applying each to the path's own point range
(`x ∈ [23, 160], y ∈ [47, 100]`, from usvg's flattened output): the correct
matrix maps it to `x ∈ [100, 153], y ∈ [23, 160]` (matches the gray arc pixels
actually visible in both renders, `x ∈ [100,153], y ∈ [28,160]`, confirmed by
sampling `docs/near-miss/../../render` output); the wrong one used for text
layout maps it to `x ∈ [-100, -47]` — entirely off the 0–200 canvas. Every
glyph positioned along that off-canvas table is invisible, which is exactly
what `ours` shows: the arc (correctly transformed, drawn through the general
pipeline) is there, the text along it (mislaid through `textPathTables`) is
not.

**Code location.** `LeanSvg/Svg.lean:2717`–`:2719` (`textPathTables`).

**Proposed fix.** Parse `transform-origin` on the same referenced element and
compose it the same way `applyProp`'s `"transform"` case does
(`Svg.lean:2041`–`:2045`): `parseTransformOrigin` needs a `(refW, refH)` pair
to resolve percentages/`center` against — the root viewBox/size, exactly
`base.pctRefW`/`base.pctRefH` at `:3399` — which `textPathTables` does not
currently have (it only sees `events`, no root/pctRef). The gradient/pattern
pre-passes already solve this (`scan.pctRef`, `Svg.lean:3340`,
`:3348`); `textPathTables` needs the same value threaded in, then:

```
let (odx, ody) := match attr attrs "transform-origin" with
  | some v => parseTransformOrigin v pctRefW pctRefH
  | none => (0, 0)
let base := parseTransform t   -- or Mat.identity
let m := if odx == 0 && ody == 0 then base
         else ((Mat.translate odx ody).mul base).mul (Mat.translate (-odx) (-ody))
```

**Size.** Small/medium: one pre-pass function gains a `(pctRefW, pctRefH)`
parameter (threaded from its one call site, alongside the existing
`scan.pctRef`), plus the ~5-line origin composition above, reusing
`parseTransformOrigin` and `Mat` as-is. No new module, no change to the
general pipeline.

## Grouped by cause (largest first)

| files | cause | code location | size |
|---|---|---|---|
| `masking/mask/with-opacity-1.svg`, (`with-opacity-3.svg`, not assigned but same cause) | `storeQ`'s exact-rational round-to-nearest-even ties at `opacity = 0.5` differ from resvg's literal `f32` rounding by 1 premultiplied level; amplified up to ~20× by un-premultiplying at this file's very-low mask alpha | `LeanSvg/Canvas.lean:155,173`, `LeanSvg/Render.lean:456,810` | Medium/large, low value (known residual, T44→T49) |
| `structure/systemLanguage/on-tspan.svg` | `passesConditions` (systemLanguage/requiredFeatures/requiredExtensions) not checked for `tspan`/`a`/`textPath` visibility, only `display:none` is | `LeanSvg/Svg.lean:2931` | Tiny (1 line) |
| `structure/transform-origin/on-text-path.svg` | `textPathTables` ignores `transform-origin` on the referenced shape, using only raw `transform`; text laid out on a wrongly-rotated (off-canvas) path while the shape's own visible rendering is correct | `LeanSvg/Svg.lean:2717`–`2719` | Small/medium |
| `structure/svg/mixed-namespaces.svg` | No XML namespace tracking anywhere; an element whose default `xmlns` is shadowed to a non-SVG URI should be dropped but is not | `LeanSvg/Xml.lean:45`, `LeanSvg/Svg.lean` (`interpret`, no resolver) | Large (same as `T83`'s `xmlns-validation.svg`) |

Cheapest fix first if picking one up next: `systemLanguage` on `tspan`
(1 line, `Svg.lean:2931`), then the `textPath`/`transform-origin` gap
(`Svg.lean:2717`). The namespace and opacity-amplification causes are both
already-documented, cross-cutting/low-value items (T83, T44/T49) rather than
fresh, cheap wins.
