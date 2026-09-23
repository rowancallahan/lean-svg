/-
# The output cap of `Gzip.gunzip` (T84)

`gunzip inp cap` inflates an `svgz` image under the SVG-image byte budget.
Whatever the stream says (a zip bomb included), a `some` holds at most `cap`
bytes: the block loop stops at `cap + 1` and the wrapper rejects anything
past `cap`.

Check with `lake env lean proofs/Gzip.lean`.
-/
import LeanSvg.Gzip

namespace LeanSvg.Gzip

theorem gunzip_size_le {inp out : ByteArray} {cap : Nat} (h : gunzip inp cap = some out) :
    out.size ≤ cap := by
  unfold gunzip at h
  split at h
  · cases h
  · split at h
    · split at h
      · cases h
        assumption
      · cases h
    · cases h

end LeanSvg.Gzip

-- Public theorem audit: only standard Lean axioms, never `sorryAx`.
#print axioms LeanSvg.Gzip.gunzip_size_le
