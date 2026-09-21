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

**Difficulty: moderate. Estimate one week.**

> **Correction, 2026-09-21.** An earlier draft of this section said the cheap
> window for this theorem closes when LeanZip lands. That was wrong, and
> backwards. LeanZip *opens* the window — see "The compression layer is
> already done" below. What remains true is that the zero-dependency version
> of this theorem is only easy while the deflate is stored blocks.

#### The format decomposes into three independent layers

PNG is not a grammar in the formal-language sense, and that is good news. It
is a **length-prefixed binary container**: an 8-byte signature, then a
sequence of chunks, each being a 4-byte big-endian length `L`, a 4-byte type,
`L` bytes of data, and a 4-byte CRC-32 over type and data.

Length-prefixed beats a delimiter grammar for proof purposes. Parsing is
deterministic and total, with no ambiguity, no backtracking and no lookahead.
Structural recursion on the remaining byte count terminates trivially, since
every step consumes `12 + L` bytes, so **no fuel is needed** — which matters,
given invariant 3. The cost of that is that a length field controlling how
many later bytes belong to a chunk is not context-free, so it cannot be
written as a BNF grammar. Write a parser, not a grammar.

The genuinely grammar-like part of PNG is the chunk ordering, and it is short
enough to state as a predicate over the chunk list: IHDR first, IEND last,
exactly one of each, IDAT chunks consecutive, PLTE required for colour type 3
and forbidden for types 0 and 4 and placed before IDAT. IHDR itself is 13
fixed bytes: width, height, bit depth, colour type, compression method,
filter method, interlace method.

The three layers, each provable on its own:

1. **Container.** Signature, chunk list, CRC-32. Pure structural recursion.
2. **Compression.** All IDAT payloads concatenated form one zlib stream.
3. **Pixels.** The decompressed stream is `h` rows, each one filter-type byte
   followed by the row bytes. Filter type 0 is the identity; types 1–4 (Sub,
   Up, Average, Paeth) are simple byte arithmetic, each individually
   invertible in a few lines.

#### The compression layer is already done

[lean-zip](https://github.com/kim-em/lean-zip) is a verified DEFLATE
implementation in Lean 4: over 1,100 theorems, roughly 32,000 lines of proof,
no `sorry`, re-checked in CI. Relevant to us:

- It covers **zlib, RFC 1950**, not just raw DEFLATE, which is exactly the
  container PNG uses: `Zip.Native.ZlibEncode.compress` and
  `Zip.Native.ZlibDecode.decompress`.
- The round-trip theorem is `zlib_decompressSingle_compress`, stating
  `ZlibDecode.decompressSingle (ZlibEncode.compress data level) maxOutputSize
  = .ok data`, for every input and every compression level.
- It ships **verified CRC-32 and Adler-32** (`Zip.Native.Crc32`,
  `Zip.Native.Adler32`). PNG needs both: CRC-32 per chunk, Adler-32 for the
  zlib stream. Ours in `LeanSvg/Png.lean` are hand-rolled and unverified.

So layer 2 is inherited, and layers 1 and 3 are the easy ones.

#### The cost, which is a real trade

The README claims total functions, no floats, **no FFI, no dependencies**.
Adopting lean-zip breaks the last two. It is a dependency, and it carries
four small C primitives for word reads and copies, though its proofs use
pure-Lean reference implementations, so a pure path exists and should be
checked before committing to this.

Three options, in increasing order of both cost and strength:

| option | dependency | FFI | effort | strength |
|---|---|---|---|---|
| keep stored blocks, prove it ourselves | none | none | ~1 week | round trip, unverified checksums |
| vendor lean-zip's pure reference code | none | none | ~1–2 weeks | round trip, verified checksums |
| depend on lean-zip | yes | four C primitives | ~1 week | strongest, and real compression |

The middle row is probably the right answer, but it depends on whether
lean-zip's pure path is cleanly separable. Check that first.

**What none of them prove.** That our decoder, or lean-zip's inflate, matches
the published specification. That is not provable, only reviewable and
testable. lean-zip is well placed here — the existence of
[lean-zlib](https://github.com/kim-em/lean-zlib), thin FFI bindings to system
zlib, strongly suggests differential testing against the reference
implementation.

#### Specifications

- **[W3C PNG Third Edition](https://www.w3.org/TR/png-3/)** — current, a W3C
  Recommendation as of 2025, incorporating APNG and HDR. The canonical
  reference. A [Fourth Edition](https://w3c.github.io/png/) is in progress.
- **[RFC 2083](https://datatracker.ietf.org/doc/html/rfc2083)** — PNG 1.0,
  1997. Shorter and more readable, and complete for the subset we emit. This
  is the better one to write a decoder from.
- ISO/IEC 15948:2004 — the ISO version, essentially PNG 1.2.
- RFC 1950 (zlib) and RFC 1951 (DEFLATE) — covered by lean-zip.

#### Prior art

The technique is well trodden; the target is not. Verified binary-format
codecs go back a decade:

- **[EverParse](https://project-everest.github.io/everparse/)** (F*,
  Microsoft) generates verified parsers from format descriptions, proving
  memory safety, functional correctness and non-malleability. Applied to TLS,
  Bitcoin and PKCS #1.
- **[Narcissus](https://arxiv.org/pdf/1803.04870)** (Coq, MIT) derives
  correct-by-construction encoders *and* decoders from a single format
  description, and replaced the packet processors of a full Internet protocol
  stack in Mirage. Its format-combinator structure is the closest match to
  what this would need, and worth reading before starting.
- Comparable work exists for ASN.1/ACN codecs.

No verified image-format codec turned up, and nothing for PNG, and nothing in
Lean. So the novelty here is the target and the ecosystem, not the method.
Borrow the method.

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
2. The PNG round-trip theorem. About a week. Check first whether lean-zip's
   pure-Lean path is separable from its four C primitives, since that decides
   which of the three options in 3a is available.
3. The locality theorem, cheap half. One week.
4. Then decide whether features or the expensive half of locality is worth
   more.
