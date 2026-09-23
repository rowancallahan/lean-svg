# D-filters-images — near-miss diagnosis

Both target files score 0.910 (within-8 at 200 px). Diagnosis only; no
renderer code changed. Composite (`resvg | ours | diff ×4`) for both files:
`docs/near-miss/D-filters-images.png`.

## Files

### `filters/feImage/with-subregion-1.svg` (0.910)
### `filters/feImage/with-subregion-2.svg` (0.910)

Same cause, same numbers (`within` = 0.90995 for both when recomputed
locally — the two files are the same test with `x`/`width` given as
fractions (`-1`) vs. percentages (`-2`) of the same `objectBoundingBox`
filter, and `primitiveUnits`/`filter` region resolve identically either way).

**Cause.** Both filters have one primitive, `<feImage>`, whose `href` is a
`data:image/png;base64,...` URI (a real, decodable 16×16 indexed PNG —
verified locally: IHDR gives `16×16`, bit depth 1, colour type 3/indexed,
which `PngDecode.lean`'s palette path already handles). `<feImage
href="data:...">` is the one call site `FeImage.dataCanvas` was left as a
stub for and never wired up:

```
LeanSvg/Filter/Image.lean:75
def dataCanvas (_uri : ByteArray) (_aspect : Viewport.AspectRatio) (_rw _rh : Nat)
    (_sx _sy _sw _sh : Int) : Option Canvas :=
  none
```

Its own doc comment (`Image.lean:68-73`) already names the fix: *"the one
`data:` call site (for the integrator, once T63's decoders land)"* — T63
(`LeanSvg/Image.lean`, the `<image>` element's PNG/JPEG decode + placement
pipeline) has since landed, but nothing hooked it up here.

The stub is called at the one `.data` match arm in the filter-primitive
render loop:

```
LeanSvg/Render.lean:725-729
| .data uri =>
  match FeImage.dataCanvas uri j.spec.aspect j.rw j.rh j.sx j.sy j.sw j.sh with
  | some cv => fs := FeImage.setPre fs fi j.prim cv
  | none => pure ()
```

`none` leaves the primitive's `pre` unset, so when the filter actually runs,
the `.image` primitive kind falls back to a fully transparent canvas — the
same "dummy primitive" usvg itself uses for an image it *can't* decode
(`create_dummy_primitive` in `usvg/src/parser/filter.rs`, `convert_image`) —
except here it's applied to an image we in fact can decode:

```
LeanSvg/FilterApply.lean:539
| .image s => Img.of (s.pre.getD (Canvas.new rw rh none)) false
```

Net effect: the filtered `rect1` (`fill="red" filter="url(#filter1)"`)
disappears entirely. The diff panel in the composite is a solid square the
size and position of resvg's rendered (scaled-up) 16×16 image — exactly the
content we're failing to draw — which is what the 0.910 score is: the two
renders agree everywhere except that one region.

**Code location.** `LeanSvg/Filter/Image.lean:75` (`dataCanvas`, the fix
goes here); call site `LeanSvg/Render.lean:727` (no change needed — it
already threads through everything a fix needs: `j.rw`/`j.rh` (region
pixmap size), `j.sx`/`j.sy`/`j.sw`/`j.sh` (subregion in the same pixel
convention `FeImage.Job` already uses), `j.spec.aspect` (parsed
`preserveAspectRatio`), `uri` (the raw `data:` bytes)).

**How resvg/usvg 0.48.1 does it** (checked against a clean
`v0.48.1` checkout): `usvg::parser::filter::convert_image_inner`
(`parser/filter.rs:821`) calls `image::get_href_data` + `image::convert_inner`
with the primitive's `filter_subregion.translate_to(0.0, 0.0)` as the target
rect, producing a `Group` with one placed `Image` node at local `(0,0)`
sized to the subregion. `resvg::filter::apply_image` (`filter/mod.rs:861`)
then renders that root into a fresh `region.width() × region.height()`
pixmap through `Transform::from_row(sx, 0, 0, sy, subregion.x, subregion.y)`
— scale from the filter's own device scale, translate by the subregion's
device-pixel origin. That's precisely the geometry `FeImage.Job` already
carries (`rw`/`rh` = region size, `sx`/`sy`/`sw`/`sh` = subregion) and that
the *link* (`href="#id"`) half of `feImage` already uses successfully via
`Job.mat` (`LeanSvg/Filter/ImageRender.lean:44-46`) — confirmed by testing:
every `data:`-less feImage file in the corpus's `filters/feImage/`
directory passes at 1.000, subregion cases included
(`with-x-y.svg`, `with-x-y-and-protruding-subregion-{1,2}.svg`), while every
`data:`-href file fails. Same primitive, same subregion plumbing, only the
"draw a decoded raster instead of a linked element" half was never written.

**Proposed fix.** Implement `dataCanvas` by composing existing pieces,
no new decoders and no changes outside `Filter/Image.lean`:
1. `Image.load uri` (`LeanSvg/Image.lean:263`) to decode + premultiply — the
   exact function `<image>` elements already use.
2. Placement: `Image.place`/`Image.viewBox` (`Image.lean:303-344`) already
   implement `preserveAspectRatio` meet/slice/align against a target rect;
   reuse them with the target rect `(0, 0, sw, sh)` (mirroring usvg's
   `filter_subregion.translate_to(0, 0)`) and `j.spec.aspect`.
3. Rasterize into a fresh `rw × rh` canvas at device offset `(sx, sy)`:
   either an identity `ctm0` through `Image.build`/`Canvas.fillMaskImage`
   with a full-rect mask (reusing the pixel sampler `Image.lean:426`
   already relies on for `<image>`), or a direct pixel copy loop — both are
   local, small additions.
4. `none` stays the answer for whatever `Image.load` already returns `none`
   for (undecodable format, GIF/WebP/SVG, bad `data:` URI) — same "degrade
   to dummy primitive" behaviour usvg has, so no new failure mode.

**Size.** Small: one function body in one file
(`LeanSvg/Filter/Image.lean`), reusing `Image.lean`'s decode/place/sample
pipeline end to end. Rough estimate 40–80 lines. No changes to
`Render.lean` or `FilterApply.lean` — both already carry the right plumbing
and only need `dataCanvas` to stop returning `none`.

**Concurrent work.** `tasks/T77-feimage-data.md` targets the identical root
cause (this exact `dataCanvas` stub) for a different file list:
`embedded-png.svg` (0.482), `preserveAspectRatio=none.svg` (0.741),
`with-subregion-3.svg` (0.750), `with-subregion-4.svg` (0.750),
`painting/image-rendering/on-feImage.svg` (0.482) — branch
`claude/fix-feimage-data`, which does not exist yet on `origin` as of this
diagnosis, so it does not look like anyone has picked it up. One more file,
`filters/feImage/with-subregion-5.svg` (0.840, confirmed locally via
`run_corpora.py --dir filters/feImage`), shares the same cause but isn't
listed in either task. A single `dataCanvas` fix should turn all of these —
this task's 2 files, T77's 5, and `with-subregion-5.svg` — from fail to
pass in one pass, since they differ only in subregion geometry and
`preserveAspectRatio`, not in whether the image decodes.

## Grouped by cause (largest first)

| Cause | Files (this task) | Fix location | Size | Notes |
|---|---|---|---|---|
| `FeImage.dataCanvas` (`LeanSvg/Filter/Image.lean:75`) is a stub that always returns `none` for `data:`-URI `feImage` sources, so the primitive renders as a transparent "dummy" instead of the decoded raster | `filters/feImage/with-subregion-1.svg`, `filters/feImage/with-subregion-2.svg` | `LeanSvg/Filter/Image.lean` (`dataCanvas`), reusing `LeanSvg/Image.lean`'s `load`/`place`/`build` (T63) and the subregion geometry `FeImage.Job` already computes and passes in | Small (~40–80 lines, one function) | Same cause as `tasks/T77-feimage-data.md`'s 5 files (branch not yet pushed) and the untracked `filters/feImage/with-subregion-5.svg` (0.840); one fix should clear all 8 |

Every file in this task's list falls into this single group.
