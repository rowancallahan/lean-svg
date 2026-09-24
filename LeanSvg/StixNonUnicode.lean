import LeanSvg.Bytes
import LeanSvg.StixNonUnicodeTable

/-!
# matplotlib's `STIXNonUnicode` letters

matplotlib's mathtext ("stix"/"stixsans" font sets) writes calligraphic,
italic/bold blackboard and sans-serif Greek letters as Private Use Area code
points in `font-family: STIXNonUnicode`, a STIX 1.x font that is installed
nowhere, so they would draw as `.notdef` boxes (Chromium draws nothing).
For text in that family, `remap` replaces each such code point with the
Unicode letter it stands for (`StixNonUnicodeTable`, generated from
matplotlib's own table): calligraphic → Mathematical Script, blackboard →
Double-Struck (Unicode has no italic or bold double-struck letters), sans
Greek → Greek.  `FamilyMatch` already sends `STIXNonUnicode` to STIX Two
Math, which has every target letter.  Anything else is copied unchanged.
-/

namespace LeanSvg.StixNonUnicode

/-- The Unicode letter for a matplotlib private-use code point, if any. -/
def lookup (cp : Nat) : Option Nat :=
  (table.find? (·.1 == cp)).map (·.2)

/-- UTF-8 bytes of `cp` (only called with a letter from `table`: BMP or
Supplementary Multilingual Plane). -/
def utf8 (cp : Nat) : Array UInt8 :=
  if cp < 0x10000 then
    #[(0xE0 + cp / 0x1000).toUInt8, (0x80 + cp / 0x40 % 0x40).toUInt8, (0x80 + cp % 0x40).toUInt8]
  else
    #[(0xF0 + cp / 0x40000).toUInt8, (0x80 + cp / 0x1000 % 0x40).toUInt8,
      (0x80 + cp / 0x40 % 0x40).toUInt8, (0x80 + cp % 0x40).toUInt8]

/-- `bs` with every mapped private-use code point (3-byte UTF-8,
`EE`/`EF xx xx`) replaced by its Unicode letter. -/
def remap (bs : ByteArray) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  let mut i := 0
  for _ in [0:bs.size] do
    if i ≥ bs.size then break
    let b0 := Bytes.at' bs i
    let b1 := Bytes.at' bs (i + 1)
    let b2 := Bytes.at' bs (i + 2)
    let cp := (b0.toNat % 0x10) * 0x1000 + (b1.toNat % 0x40) * 0x40 + b2.toNat % 0x40
    match (if (b0 == 0xEE || b0 == 0xEF) && i + 2 < bs.size
              && b1 / 0x40 == 2 && b2 / 0x40 == 2 then lookup cp else none) with
    | some u =>
      for b in utf8 u do out := out.push b
      i := i + 3
    | none =>
      out := out.push b0
      i := i + 1
  return out

/-- Is `family` (a raw `font-family` value) matplotlib's `STIXNonUnicode`?
Only its first name counts: matplotlib writes the family alone. -/
def isFamily (family : ByteArray) : Bool :=
  match (Bytes.splitTrim family 44)[0]? with
  | some n =>
    let q := Bytes.at' n 0
    let n := if n.size ≥ 2 && (q == 34 || q == 39) && Bytes.at' n (n.size - 1) == q
      then n.extract 1 (n.size - 1) else n
    Bytes.eqAsciiCI n "stixnonunicode"
  | none => false

set_option maxRecDepth 8000 in
example : lookup 0xE23A = some 0x1D4A9 := by rfl  -- calligraphic N → 𝒩
set_option maxRecDepth 8000 in
example : lookup 0xE156 = some 0x1D53C := by rfl  -- blackboard E → 𝔼
example : utf8 0x1D4A9 = #[0xF0, 0x9D, 0x92, 0xA9] := by rfl

end LeanSvg.StixNonUnicode
