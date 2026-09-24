import LeanSvg.Fixed
import LeanSvg.FontSet
import LeanSvg.FamilyMatch

/-!
# Synthetic bold and oblique (T116)

Chromium (Blink's `FontPlatformData`) synthesises a style the matched face
lacks: bold when the requested weight is ≥ 600 and the face's is < 600
(`SkFont::setEmbolden`), oblique when italic/oblique is requested and the face
is upright (`SkFont::setSkewX(-1/4)`).  Measured in this container's
Chromium: the skew is exactly `x' = x - y/4` about the glyph origin (`y` down),
and fake bold outsets the outline symmetrically, by Skia's
`kStdFakeBoldInterp`: a stroke `size/24` wide at ≤ 9 px, `size/32` at ≥ 36 px,
linear in between (the size in device pixels); advances do not change.

Only the real-world fonts (`FamilyMatch`, `FontSet` indices from
`FamilyMatch.first`) synthesise: usvg never does, and the resvg suite's fonts
come before them.
-/

namespace LeanSvg
namespace Synth

/-- A T106 embedded font: the only ones that synthesise. -/
def realWorld (k : Nat) : Bool := !FamilyMatch.suite k && k < FontSet.count

/-- Font `k` drawn for `weight` gets a fake-bold outline. -/
def bold (k weight : Nat) : Bool :=
  realWorld k && 600 ≤ weight && (FontSet.styles.getD k (400, false, 5)).1 < 600

/-- Font `k` drawn for italic/oblique text gets a -1/4 skew. -/
def oblique (k : Nat) (italic : Bool) : Bool :=
  realWorld k && italic && !(FontSet.styles.getD k (400, false, 5)).2.1

/-- The 16.16 linear part `[la lc; lb ld]` followed by the skew: `L · [1 -1/4; 0 1]`. -/
def skew (la lb lc ld : Int) : Int × Int × Int × Int :=
  (la, lb, lc - Int.ediv la 4, ld - Int.ediv lb 4)

/-- Skia's fake-bold stroke width for a `size` (user units, `Fx`) drawn at
`scale` (16.16 user → device): `size · r`, `r` from 1/24 at a device size of
9 px down to 1/32 at 36 px. -/
def boldWidth (size : Fx) (scale : Nat) : Fx :=
  let dev : Int := Int.ediv (size * scale) 65536
  let s := max 2304 (min 9216 dev)
  Int.ediv (size * (27648 - (s - 2304))) 663552

example : boldWidth (Fx.ofNat 48) 65536 = Fx.ofNat 48 / 32 := by decide
example : boldWidth (Fx.ofNat 6) 65536 = Fx.ofNat 6 / 24 := by decide

end Synth
end LeanSvg
