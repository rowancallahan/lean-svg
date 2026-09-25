/-
# The `ImageData` size contract for `PngDecode.decode` (T61)

`decode` ends by checking the contract on what `decodeRaw` produced and
returns `none` otherwise, so the theorem is that check read back. It says
nothing about the pixels being right (that is `tests/check_png_decode.py`),
only that a `some` is always safe to index as `w * h` RGBA8 pixels within
`ImageData.maxPixels`.

Check with `lake env lean spec/PngDecode.lean`.
-/
import LeanSvg.PngDecode

namespace LeanSvg.PngDecode

/-- A decoded PNG image has exactly `w * h * 4` bytes of RGBA, positive sides,
and at most `ImageData.maxPixels` pixels. -/
theorem decode_size {b : ByteArray} {d : ImageData.Decoded} (h : decode b = some d) :
    d.px.size = d.w * d.h * 4 ∧ 0 < d.w ∧ 0 < d.h ∧ d.w * d.h ≤ ImageData.maxPixels := by
  unfold decode at h
  split at h
  · cases h
  · split at h
    · cases h
      assumption
    · cases h

end LeanSvg.PngDecode
