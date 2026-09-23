/-!
# Decoded raster images (interface)

The shared type between the embedded-image decoders (`PngDecode`,
`JpegDecode`) and the `<image>` renderer (`Image`). Only bytes already inside
the SVG reach a decoder: `href="data:..."`. There is no path from here to a
file or a URL.

Contract every decoder must meet (T61–T63), each proved in `proofs/`:
* total: a plain function `ByteArray → Option Decoded`, no `partial`;
* `none` on anything malformed, truncated, unsupported or over budget;
* `some d → d.px.size = d.w * d.h * 4 ∧ 0 < d.w ∧ 0 < d.h ∧ d.w * d.h ≤ maxPixels`,
  checked before any allocation proportional to the image.
-/

namespace LeanSvg.ImageData

/-- RGBA8, straight (non-premultiplied) alpha, row-major, `px.size = w*h*4`. -/
structure Decoded where
  w : Nat
  h : Nat
  px : ByteArray

/-- Largest decoded image, in pixels (same as the canvas cap). -/
def maxPixels : Nat := 16777216

end LeanSvg.ImageData
