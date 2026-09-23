/-
# `JpegDecode.decode` meets the `ImageData` contract (T62)

`decode_size`: whatever the input bytes, a decoded image has exactly
`w * h * 4` bytes of RGBA, positive sides, and at most `maxPixels` pixels.

`decode` ends with that very check on the decoder's result (and returns
`none` if it fails), so the theorem holds by construction; the width/height
limits are also enforced at SOF, before any allocation, but that is not what
this proof relies on.

Check with `lake env lean proofs/JpegDecode.lean`.
-/
import LeanSvg.JpegDecode

namespace LeanSvg.JpegDecode

theorem decode_size (b : ByteArray) (d : ImageData.Decoded) (h : decode b = some d) :
    d.px.size = d.w * d.h * 4 ∧ 0 < d.w ∧ 0 < d.h ∧ d.w * d.h ≤ ImageData.maxPixels := by
  unfold decode at h
  split at h
  · split at h
    · cases h; assumption
    · cases h
  · cases h

end LeanSvg.JpegDecode
