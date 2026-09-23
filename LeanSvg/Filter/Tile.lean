import LeanSvg.Canvas

/-!
# `feTile` (T70): resvg `filter/mod.rs::apply_tile`

resvg crops the referenced input to its own recorded sub-region (`Image`'s
`region` field — the *declared* sub-region of whichever primitive produced
it, not necessarily where its pixels visually ended up: `feOffset` carries
its input's `region` forward unchanged, per `FilterApply.run`'s `isOffset`
handling) and repeats that crop across the whole filter region with a
`tiny_skia::Pattern` in `Repeat` spread mode and `Bicubic` filtering.

Every coordinate a filter primitive sees here is a whole device pixel
(`devRect` floors/ceils in `FilterApply.run`), so the pattern's sample points
always land exactly on the tile's own pixel centres.  Checked against
`resvg` 0.48.1 on `feTile/simple-case` (a period with sharp internal
transparent/opaque structure) and `feTile/complex-transform` (the tile under
a skew+rotate): both come back with only `{0, 255}` alpha, i.e. razor-sharp
edges and no resampling blur, so the exact-alignment case of `Bicubic`
reduces to plain nearest/periodic indexing here — no interpolation to model.

This file only needs `Canvas` (not `FilterApply.Img`, which imports it) so
that `FilterApply.runPrim` can call it without a cyclic import; it wraps the
`Canvas` this returns into an `Img` itself. -/

namespace LeanSvg
namespace FilterApply

/-- `apply_tile`.  `(tx, ty, tw, th)` is the input's own region, already
translated into region-local pixel coordinates; it need not lie fully inside
the canvas (`feTile/complex-transform`, whose title's own "(UB)" flags a
`feFlood` sub-region that pokes outside the filter region under a skew — an
independent per-rect `to_int_rect` rounding, not a real geometric overflow,
since one is a subset of the other before rounding): resvg's own crop
(`Pixmap::clone_rect`) *intersects* with the canvas rather than requiring
containment, so the repeated tile is only ever the visible part, anchored at
the declared (unclamped) `tx, ty`.  Only a wholly-outside sub-region (empty
intersection, e.g. `feTile/empty-region`) clears this primitive's own
result — exact whenever `feTile` is the filter's last primitive, true of
every corpus file, since resvg's `Err` there clears the *whole* filter to
transparent. -/
def runTileCanvas (rw rh : Nat) (tx ty tw th : Int) (src : Canvas) : Canvas :=
  if tw ≤ 0 || th ≤ 0 then Canvas.new rw rh none
  else
    let ix0 := max tx 0
    let iy0 := max ty 0
    let ix1 := min (tx + tw) (rw : Int)
    let iy1 := min (ty + th) (rh : Int)
    if ix1 ≤ ix0 || iy1 ≤ iy0 then Canvas.new rw rh none
    else Id.run do
      let itw := ix1 - ix0
      let ith := iy1 - iy0
      let ix0n := ix0.toNat
      let iy0n := iy0.toNat
      let mut px : Array Nat := Array.replicate (rw * rh) 0
      for y in [0:rh] do
        let sy := iy0n + (Int.emod ((y : Int) - ty) ith).toNat
        let srow := sy * rw
        let drow := y * rw
        for x in [0:rw] do
          let sx := ix0n + (Int.emod ((x : Int) - tx) itw).toNat
          px := px.setIfInBounds (drow + x) (src.px.getD (srow + sx) 0)
      return ⟨rw, rh, px⟩

end FilterApply
end LeanSvg
