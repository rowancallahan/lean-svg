/-
# The `ImageData` size contract for `GifDecode.decode` (T78)

Same shape as `proofs/PngDecode.lean`: `decode` ends by checking the
contract on what `decodeRaw` produced and returns `none` otherwise, so this
is that check read back as a theorem. It says nothing about the pixels
being right (there is no `tests/check_gif_decode.py` here — see the task's
`## Report`), only that a `some` is always safe to index as `w * h` RGBA8
pixels within `ImageData.maxPixels`.

Check with `lake env lean proofs/GifDecode.lean`.
-/
import LeanSvg.GifDecode

namespace LeanSvg.GifDecode

theorem decode_size {b : ByteArray} {d : ImageData.Decoded} (h : decode b = some d) :
    d.px.size = d.w * d.h * 4 ∧ 0 < d.w ∧ 0 < d.h ∧ d.w * d.h ≤ ImageData.maxPixels := by
  unfold decode at h
  split at h
  · cases h
  · split at h
    · cases h
      assumption
    · cases h

end LeanSvg.GifDecode
