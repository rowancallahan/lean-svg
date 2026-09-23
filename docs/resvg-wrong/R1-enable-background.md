# R1 — `enable-background` / `BackgroundImage` / `BackgroundAlpha`

20 files under `filters/enable-background/`, all scored "pass 1.000000" against
resvg at 200px, all marked wrong (2) for chrome/firefox/safari in
`results.csv`. One root cause covers all 20; see "Shared finding" before the
per-file notes.

`filters/enable-background/with-mask.svg` exists in the corpus but is not in
this task's file list — out of scope here.

## Shared finding

`enable-background` (values `new`, `accumulate`, `inherit`, and the
`new <x> <y> <w> <h>` region form) and the `BackgroundImage`/`BackgroundAlpha`
filter inputs are an SVG 1.1 Filter Effects feature: an element with
`enable-background="new"` starts a fresh accumulation buffer; every sibling
painted after it, up to the next `new` boundary, is composited into that
buffer; a descendant filter can then read the buffer so far via
`in="BackgroundImage"`/`"BackgroundAlpha"`.

**No renderer we can check implements it.** `results.csv` marks chrome,
firefox and safari wrong (2) on every one of these 20 files — none of the
three ever shipped support. resvg used to attempt it and removed it outright:

> `CHANGELOG.md`, `[0.32.0] - 2023-04-23`, under Removed:
> "`enable-background` support. This feature was never supported by browsers
> and was deprecated in SVG 2. To my knowledge, only Batik has a good support
> of it. Also, it's a performance nightmare, which caused multiple issues in
> resvg already."
>
> Same entry, under Changed: "`BackgroundImage` and `BackgroundAlpha` filter
> inputs will produce the same output as `SourceGraphic` and `SourceAlpha`
> respectively."

The "multiple issues" is not hand-waving: linebender/resvg#257, "Endless loop
during enable-background processing" (closed the same day as the 0.32.0
removal) — a real-world SVG made resvg's background-accumulation code hang
for over two days without terminating, while rsvg finished in 13 minutes and
Inkscape in 10. Removing the feature closed the issue.

resvg 0.48.1's actual source confirms the CHANGELOG, with one correction — in
current code **both** `BackgroundImage` and `BackgroundAlpha` map to
`SourceGraphic` (not `SourceAlpha` for the latter, despite what the changelog
entry says):

```rust
// crates/usvg/src/parser/filter.rs:485-491
"BackgroundImage" | "BackgroundAlpha" | "FillPaint" | "StrokePaint" => {
    log::warn!("{} filter input isn't supported and not planed.", s);
    Input::SourceGraphic
}
```

`enable-background` itself is worse than unimplemented — it's dead on
arrival. `AId::EnableBackground` is a recognized attribute name and has a
`FromValue` impl (`svgtypes::EnableBackground::from_str`, `svgtree/mod.rs:956`),
so a value like `new 30 80 30 30` parses without error, but nothing in
`crates/usvg` or `crates/resvg` ever calls `node.attribute::<EnableBackground>(...)`
again — the parsed value is discarded. So in resvg 0.48.1 the attribute's
value, or even its presence, changes nothing: `new`, `accumulate`, `inherit`,
a region list, or a syntactically invalid region list are all equivalent to
the attribute not being there at all. Confirmed by rendering: resvg produces
pixel-identical output (max channel diff 1, one pixel — frame-stroke AA
noise) across `new`, `new-with-region`, and all three
`new-with-invalid-region-*` files once the shape/filter structure is the
same.

`LeanSvg/Filter.lean:547-549` (`resolveInput`) makes the same substitution
resvg's parser does — `SourceGraphic`, `BackgroundImage`, `BackgroundAlpha`,
`FillPaint`, `StrokePaint` all resolve to `.source` (`SourceGraphic`) — and
`enable-background` isn't parsed or consulted anywhere in the codebase. That
is why we score 1.000000 against resvg on all 20 files: we independently made
the identical "not supported, alias to SourceGraphic" call resvg made, and
none of the `enable-background` attribute variants matter to either renderer.

The suite's own reference PNGs are the only one of the four renders in
`R1-enable-background.png` that show real background accumulation (a second,
offset copy of the earlier sibling's shape). They most likely come from Batik
or a hand-authored reference — consistent with the CHANGELOG's "only Batik has
good support of it." Chromium, resvg and ours agree with each other and
disagree with the suite PNG on every file.

**Classification, all 20 files: (c), deliberately not supported.** Two
independent reasons converge: (1) resvg 0.48.1, our reference implementation
per `SPEC.md`, does not implement it and explicitly will not
("not planed"); (2) implementing real accumulation requires re-rendering an
unbounded number of earlier-painted sibling subtrees into an offscreen buffer
on demand, sized by however far back the nearest `new` boundary is — exactly
the kind of unbounded, data-dependent work `DESIGN.md`'s "bounded resources"
guarantee and resvg's own postmortem (#257, a two-day hang) warn against.
Confidence: high, for all 20.

## Per-file notes

Renders in `R1-enable-background.png`, one row per file. All 20 share the
same filter (`feOffset in="BackgroundImage" dx="100"`, `filterUnits="userSpaceOnUse"
x="0" y="0" width="200" height="200"`) and the same result: resvg/Chromium/ours
paint the filtered element's own `SourceGraphic` shifted by 100 (or nothing,
if the filtered element is an empty `<g>` with no content of its own), while
the suite PNG additionally shows an offset copy of the earlier sibling that a
real accumulation buffer would have captured.

- **accumulate-with-new.svg** — "`accumulate` with `new`": `g1[new] > g2[accumulate] > (rect1, g3[filter])`.
  Tests that `accumulate` nested inside a `new` ancestor keeps accumulating.
  Moot: neither `new` nor `accumulate` do anything in resvg or ours.
- **accumulate.svg** — "`accumulate`", desc "Has no effect without `new`.": `g1[accumulate] > (rect1, g2[filter])`,
  no `new` ancestor at all. Suite PNG still shows the offset background copy
  here (2×), which is odd if `accumulate` genuinely requires a `new` ancestor per
  the SVG1.1 text — possibly the suite's own reference is being generous, or
  our reading of the spec's "has no effect without new" is off. Doesn't change
  the classification since no renderer we can check implements either value.
- **filter-on-shape.svg** — "Filter on shape": filter is on `rect2` (red, same geometry as `rect1` green) rather
  than an empty `<g>`. Isolates that `SourceGraphic` substitution uses the
  filtered element's own paint (red), not an empty image.
- **inherit.svg** — "`inherit`": `g1[new] > (rect1 blue, g2[inherit] > (rect2 green, g3[filter]))`. Tests that
  `inherit` passes the ancestor's accumulation state through.
- **new-with-invalid-region-1.svg** — "`new` with invalid region (1)": `enable-background="new 10 10"` (2 numbers,
  the form needs 4). Malformed region list.
- **new-with-invalid-region-2.svg** — "`new` with invalid region (2)": `"new 10 10 20 30 40"` (5 numbers).
- **new-with-invalid-region-3.svg** — "`new` with invalid region (3)": `"new 10 10 20 -30"` (negative height).
- **new-with-region.svg** — "`new` with region": `"new 30 80 30 30"`, a syntactically valid restricted
  accumulation rectangle. All four region-list files (invalid-1/2/3 and this
  one) render identically to plain `new` in resvg and in ours, confirming the
  attribute value is discarded unread.
- **new.svg** — "`new`": the baseline case, `g1[new] > (rect1, g2[filter])`.
- **shapes-after-filter.svg** — "Shapes after filter", desc "`rect2` should not be included into
  `BackgroundImage`.": `g1[new] > (rect1, g3[filter], rect2)`. Tests that only
  siblings painted *before* the filtered element accumulate, not ones after.
- **stop-on-the-first-new-1.svg** — "Stop on the first `new` (1)": `rect1[blue]` sits *outside* `g1[new]`, which
  contains `rect2[green]` and the filtered `g2`. Tests that a `new` boundary
  blocks accumulation from reaching outside itself.
- **stop-on-the-first-new-2.svg** — "Stop on the first `new` (2)": `rect1[blue]` outside; `g1[new] > (rect2[orange],
  g2[new] > (rect3[green], g3[filter]))`. Tests that the *nearest* `new`
  ancestor is the one whose buffer is read — accumulation should not walk past
  it to the outer `new`.
- **with-clip-path.svg** — "With clip-path": `filter` and `clip-path` on the same `<g>`. Tests
  ordering/interaction between clipping and background capture.
- **with-filter-on-the-same-element.svg** — "With `filter` on the same element": `enable-background="new"` and
  `filter` on the *same* `g1`, which contains `rect1`. Self-reference edge
  case: a live accumulation region can't include its own not-yet-composited
  content. Suite PNG is blank here — consistent with "nothing to
  read yet" — while resvg/Chromium/ours show `rect1` itself shifted by 100
  (their `SourceGraphic` substitution reads `g1`'s own content, which the
  spec's self-reference rule would exclude). This is the one file where our
  reasoning about *why* the suite PNG looks the way it does is least certain;
  doesn't change class (c).
- **with-filter.svg** — "With filter": `g1[new] > (rect1, g2[filter2=blur] > (rect2, g3[filter1=BackgroundImage
  offset]))`. Background-reading filter nested inside a differently-filtered
  ancestor group.
- **with-opacity-1.svg** — "With opacity (1)": `opacity="0.5"` on `g1`, the element that also carries
  `enable-background="new"`.
- **with-opacity-2.svg** — "With opacity (2)": `opacity="0.5"` on the filtered element itself (`g3`).
- **with-opacity-3.svg** — "With opacity (3)": `opacity="0.5"` on an intermediate `g2` that wraps
  `rect2` and the filtered `g3`.
- **with-opacity-4.svg** — "With opacity (4)": two nested `opacity="0.5"` groups between `new` and the
  filtered element.
- **with-transform.svg** — "With transform": `g1[transform] > (rect1[blue], g2[new] > (rect2[green],
  g3[filter]))`. Tests whether background capture is defined in the
  transformed user space or an outer one.

## Summary table

| file | class | correct reference | one-line cause |
|---|---|---|---|
| accumulate-with-new.svg | c | suite PNG only (no live renderer) | `enable-background`/`BackgroundImage` unsupported by resvg (removed 0.32.0) and by every browser |
| accumulate.svg | c | suite PNG only | same |
| filter-on-shape.svg | c | suite PNG only | same |
| inherit.svg | c | suite PNG only | same |
| new-with-invalid-region-1.svg | c | suite PNG only | same; region value discarded unread regardless |
| new-with-invalid-region-2.svg | c | suite PNG only | same |
| new-with-invalid-region-3.svg | c | suite PNG only | same |
| new-with-region.svg | c | suite PNG only | same |
| new.svg | c | suite PNG only | same |
| shapes-after-filter.svg | c | suite PNG only | same |
| stop-on-the-first-new-1.svg | c | suite PNG only | same |
| stop-on-the-first-new-2.svg | c | suite PNG only | same |
| with-clip-path.svg | c | suite PNG only | same |
| with-filter-on-the-same-element.svg | c | suite PNG only (low confidence in exact suite rationale) | same |
| with-filter.svg | c | suite PNG only | same |
| with-opacity-1.svg | c | suite PNG only | same |
| with-opacity-2.svg | c | suite PNG only | same |
| with-opacity-3.svg | c | suite PNG only | same |
| with-opacity-4.svg | c | suite PNG only | same |
| with-transform.svg | c | suite PNG only | same |

All 20 are "pass" against resvg today (score 1.000000) and would stay so — no
code change is proposed for this task. Nothing to add to the pass→fail list
for the corpus gate.

## Questions for Rowan

1. Confirm: since resvg 0.48.1 treats `enable-background` as fully inert and
   `BackgroundImage`/`BackgroundAlpha` as aliases for `SourceGraphic`, should
   `LeanSvg/Filter.lean` stay exactly as-is (matching resvg's substitution),
   or would you rather these inputs resolve to fully transparent black
   instead of `SourceGraphic`? Both keep every corpus file's score unchanged
   (none of the 20 exercise a case where the two choices differ, since a
   filter's first/only primitive reading `BackgroundImage` is always the
   element's own filter subregion), but the two choices diverge on a
   hypothetical file with unfiltered content painted right after the
   `enable-background="new"` boundary and before the filtered element, inside
   the *same* filter's subregion at a point `SourceGraphic` would also cover
   — resvg's current substitution is not exactly "transparent," it's "alias
   to whatever this element would have painted anyway." Low-stakes; no corpus
   file distinguishes the two.
2. Is there any interest in a from-scratch, bounded implementation of real
   background accumulation (e.g. capped to N immediately-preceding sibling
   subtrees, or capped by total painted area) purely to pass the suite PNG on
   these 20 files, given it would then disagree with resvg (dropping us from
   1.000000 to failing) and disagree with every browser? My read is no — the
   task brief's `results.csv` framing ("if we pass, we're copying resvg's
   mistake") reads as "match reality (resvg/browsers), not the SVG 1.1 text,"
   but confirming before anyone spends real time on it.
