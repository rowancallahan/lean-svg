# Where lean-svg is, and what is left

Written 2026-09-21, after roughly three days of work. This is a status and
options document, not a plan. Nothing here is scheduled.

## 1. Features: where we are

The resvg test suite is 1679 files. We pass **868, or 51.7%**, up from 24.3%
at the start of this stretch. "Pass" means at least 99% of pixels within 8
levels of resvg's output at matched width.

Suite composition, by directory:

| area | files |
|---|---|
| filters | 397 |
| text | 356 |
| painting | 304 |
| structure | 247 |
| paint-servers | 149 |
| shapes | 133 |
| masking | 93 |

Landed this stretch: arcs, cubic subdivision, quadratics, dashes, colours and
defaults, `switch`, the `<style>` element and CSS cascade, transform-origin,
an embedded font parser, basic text, gradients, group layers, blend modes,
clipPath, paint-order, hsl.

## 2. Features: what is left

811 failing files. The large clusters:

| cluster | files | notes |
|---|---|---|
| filters | ~250 | a whole image-processing subsystem |
| markers | 60 | structural, similar to work already done |
| text baselines | 48 | fiddly metrics work |
| use / symbol | 44 | structural |
| images | 43 | needs PNG and JPEG decoders |
| masks | 37 | medium |
| textPath | 34 | medium, needs path arc-length |
| nested svg | 33 | structural |
| patterns | 27 | structural |

The remaining ~235 are a long tail.

### Time estimates

These are *working days at the current pace*, meaning days of orchestrating
with heavy subagent parallelism, not calendar days. The pace so far was
+27 points in about three days, but the work that remains is harder per file
than the work that was taken first — the cheap wins went first, as they should
have.

| target | what it adds | days | cumulative |
|---|---|---|---|
| ~62% | markers, use/symbol, nested svg, patterns | 2–3 | 2–3 |
| ~69% | masks, textPath, text baselines | 2–3 | 5–6 |
| ~72% | images (PNG + JPEG decoders) | 2–4 | 8–10 |
| ~87% | filters | 5–10 | 13–20 |

**"Close enough" is about 72%**, reached in roughly 8–10 more days. That is
everything except filters and the long tail.

Filters roughly double the total. They are Gaussian blur, colour matrix,
composite, merge, offset, flood, tile, morphology, displacement, lighting and
turbulence — and all of it in fixed point with no floats. Lighting and
turbulence are genuinely unpleasant under that constraint. They are also the
feature least likely to matter for the kind of SVG anyone would hand a
safety-critical renderer.

### The strategic point

Features and proofs pull against each other. Every feature added is more
surface area that a locality proof has to cover, and more code in the trusted
region. The README says safety is the only claim this project makes and
fidelity is empirical. If that is the real point of the project, there is a
good argument for freezing features somewhere around 70% and spending the
time on section 3 instead. Getting to 87% buys filters, which nobody will
care about, at the cost of making every theorem harder to state.

## 3. Proofs: what could be added

Six theorems hold today, all depending on `propext` alone. See `SPEC.md`
sections 1 and 4 for what is and is not established.

Two new candidates, both of which came from Rowan, are assessed below.

### 3a. The PNG round-trip theorem

**Statement.** Decoding the bytes we write returns exactly the pixels we were
asked to encode.

```
theorem png_roundtrip (px : ByteArray) (w h : Nat) :
  Png.decode (Png.encode px w h) = some (px, w, h)
```

**Difficulty: moderate. Estimate one week. Do it now, not later.**

This is far easier than it looks, because of a choice already made in
`LeanSvg/Png.lean:5`: every row uses filter type 0 (None), and the zlib stream
is made of **stored, uncompressed DEFLATE blocks**. That means:

- Unfiltering is the identity. Nothing to prove.
- There is no Huffman coding and no LZ77 matching. A stored block is a
  3-byte header, a length, its complement, and the raw bytes.

So the work is: write a total reference decoder for this restricted subset
(perhaps 150 lines), and prove the round trip by induction over the block
list. The chunk framing, CRC-32 and Adler-32 parts are true by construction
once stated.

**The timing matters.** Rowan has said LeanZip will eventually replace this.
The moment real compression lands, proving the stream decodes requires
reasoning about Huffman tables and back-references, which is a different and
much larger job. The cheap window for this theorem is open only while the
deflate is stored blocks.

**What it would not prove.** That our decoder matches the PNG specification.
That is not provable, only reviewable — but a 150-line total decoder is very
reviewable, and it can be cross-checked against PNGs produced by other tools.

### 3b. The locality theorem

**Statement, informally.** Take two documents that are identical except that
one has an extra drawing command. If that command covers 10% of the canvas,
then at most 10% of the pixels can differ between the two outputs.

**This splits into a cheap half and an expensive half, and the cheap half is
most of the value.**

#### The cheap half: no operation writes outside its rectangle

```
theorem fillMask_local (cv : Canvas) (m : Raster.Mask) (c : Rgba) (a i : Nat) :
  ¬ inRect m cv.w i → (fillMask cv m c a).px.getD i 0 = cv.px.getD i 0
```

The code is already shaped for this. `Canvas.fillMask`
(`LeanSvg/Canvas.lean:225`) is a double `for` over `[0:m.h] × [0:m.w]`, the
mask carries its own rectangle as `m.x0, m.y0, m.w, m.h`, and every write goes
through `setIfInBounds` at a computed index. There is nothing to restructure.

The real cost is that Lean 4 has no good automation for reasoning about `for`
loops. You rewrite each loop as explicit recursion with an accumulator, or
induct through `forIn`. Neither is hard, but the first one eats days while you
learn the idiom.

Three loops need it: `Canvas.fillMask`, `Shader.fillMaskShader`
(`LeanSvg/Shader.lean:1029`), and `Canvas.compositeNormal`
(`LeanSvg/Canvas.lean:729`) with its `compositeBlend` sibling. The argument is
identical in all of them.

**Estimate: 3–5 days for the first, then half a day each. Call it a week.**

The percentage corollary is then immediate — it is just counting the
rectangle, `m.w * m.h` pixels out of `cv.w * cv.h`.

Composition is also easy and Rowan's instinct that this is "a compositor
proof" is right. SVG uses the painter's model, so rendering a command list is
a fold, and `render (cmds ++ [c]) = drawOne (render cmds) c` holds by
definition. The two-document statement therefore reduces exactly to the
single-operation lemma above.

**Scope limits worth stating honestly.** The theorem needs the appended
command to be a plain shape draw. It does not hold as stated if the new
element sits inside a filter or mask, changes text layout, or is a definition
referenced elsewhere in the document. Those are fine exclusions, but they
should be in the statement rather than discovered later.

#### The expensive half: the rectangle matches the shape's true extent

The cheap half proves nothing about *which* rectangle a shape gets. To connect
"covers 10% of the canvas" back to the SVG geometry, you need the scan
converter to produce no coverage outside the shape's control-point box, which
needs the Bézier convex-hull property carried through flattening, subdivision
and fixed-point rounding — including slack for the rounding, since a rounded
point can land just outside the true hull.

That is the whole geometry pipeline. **Weeks, not days.**

#### Recommendation

Do the cheap half alone. It catches the bug class that actually matters: a
compositor scribbling outside its region, an off-by-one at a band seam, a bad
index. It is worth a week. The expensive half is a research project and the
marginal safety it buys is small.

There is a practical bonus. The cheap half is exactly the invariant that
`tasks/T45-someday-hoist-band-culling.md` could silently violate, since the
one thing T45 can get wrong is a rectangle bound at a band seam. Proving this
first would de-risk that change.

### 3c. Already written down but not started

`tasks/T43-ci-proofs.md` — run the theorem checks in CI so an axiom cannot
creep in unnoticed. Small, and arguably should come before either of the
above, since it protects what already exists.

## 4. Suggested order, if picking this up again

1. T43, CI proofs. Small, protects the six theorems that already hold.
2. The PNG round-trip theorem. One week, and the cheap window closes when
   LeanZip lands.
3. The locality theorem, cheap half. One week.
4. Then decide whether features or the expensive half of locality is worth
   more.
