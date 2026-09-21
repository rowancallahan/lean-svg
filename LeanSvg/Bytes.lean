/-!
# Byte-level helpers

All parsing in this project works directly on `ByteArray`.  Every scan is a
`for` loop over a finite range, so termination is structural and the compiler
never needs `partial`.  Out-of-range reads return `0`, which no grammar here
accepts, so a truncated input simply fails to parse instead of reading past
the end.
-/

namespace LeanSvg
namespace Bytes

/-- Byte at `i`, or `0` past the end.  Never panics. -/
@[inline] def at' (bs : ByteArray) (i : Nat) : UInt8 :=
  if h : i < bs.size then bs[i] else 0

@[inline] def isWs (c : UInt8) : Bool := c == 32 || c == 9 || c == 10 || c == 13
@[inline] def isDigit (c : UInt8) : Bool := 48 ≤ c && c ≤ 57
@[inline] def isAlpha (c : UInt8) : Bool := (65 ≤ c && c ≤ 90) || (97 ≤ c && c ≤ 122)
@[inline] def isNameChar (c : UInt8) : Bool :=
  isAlpha c || isDigit c || c == 45 || c == 95 || c == 46 || c == 58   -- - _ . :
@[inline] def toLower (c : UInt8) : UInt8 := if 65 ≤ c && c ≤ 90 then c + 32 else c

/-- Advance from `i` while `p` holds. -/
def skipWhile (bs : ByteArray) (i : Nat) (p : UInt8 → Bool) : Nat := Id.run do
  let mut j := i
  for _ in [i:bs.size] do
    if p (at' bs j) then j := j + 1 else break
  return j

def skipWs (bs : ByteArray) (i : Nat) : Nat := skipWhile bs i isWs

/-- Skip whitespace and commas (SVG list separators). -/
def skipWsComma (bs : ByteArray) (i : Nat) : Nat := skipWhile bs i (fun c => isWs c || c == 44)

/-- Index of the first `c` at or after `i`, or `bs.size`. -/
def findByte (bs : ByteArray) (i : Nat) (c : UInt8) : Nat := Id.run do
  let mut j := i
  for _ in [i:bs.size] do
    if at' bs j == c then return j
    j := j + 1
  return bs.size

/-- Does `bs` at `i` start with the ASCII string `s`? -/
def startsWith (bs : ByteArray) (i : Nat) (s : String) : Bool :=
  let sb := s.toUTF8
  if i + sb.size > bs.size then false
  else Id.run do
    for k in [0:sb.size] do
      if at' bs (i + k) != at' sb k then return false
    return true

/-- Index of the first occurrence of ASCII `s` at or after `i`, or `bs.size`. -/
def findSeq (bs : ByteArray) (i : Nat) (s : String) : Nat := Id.run do
  let mut j := i
  for _ in [i:bs.size] do
    if startsWith bs j s then return j
    j := j + 1
  return bs.size

/-- Byte-wise equality with an ASCII string. -/
def eqAscii (bs : ByteArray) (s : String) : Bool :=
  let sb := s.toUTF8
  if bs.size != sb.size then false
  else Id.run do
    for k in [0:sb.size] do
      if at' bs k != at' sb k then return false
    return true

/-- Case-insensitive byte-wise equality with a lowercase ASCII string. -/
def eqAsciiCI (bs : ByteArray) (s : String) : Bool :=
  let sb := s.toUTF8
  if bs.size != sb.size then false
  else Id.run do
    for k in [0:sb.size] do
      if toLower (at' bs k) != at' sb k then return false
    return true

/-- Strip leading and trailing whitespace. -/
def trim (bs : ByteArray) : ByteArray := Id.run do
  let b := skipWs bs 0
  let mut e := bs.size
  for _ in [0:bs.size] do
    if e > b && isWs (at' bs (e - 1)) then e := e - 1 else break
  return bs.extract b e

/-- Lowercase copy (ASCII only). -/
def lower (bs : ByteArray) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity bs.size
  for c in bs do
    out := out.push (toLower c)
  return out

/-- Split on a byte, trimming each piece and dropping empties. -/
def splitTrim (bs : ByteArray) (sep : UInt8) : Array ByteArray := Id.run do
  let mut out : Array ByteArray := #[]
  let mut i := 0
  for _ in [0:bs.size + 1] do
    if i > bs.size then break
    let j := findByte bs i sep
    let piece := trim (bs.extract i j)
    if piece.size > 0 then out := out.push piece
    i := j + 1
  return out

/-- Decode as UTF-8 for messages; invalid input becomes a placeholder. -/
def toStr (bs : ByteArray) : String := (String.fromUTF8? bs).getD "<invalid utf-8>"

end Bytes
end LeanSvg
