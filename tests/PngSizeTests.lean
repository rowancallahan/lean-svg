import LeanSvg.Png

/-!
Regression oracle: the pre-T46 range-loop writer, kept here only for testing.
Compare the structurally recursive writer against it around stored-block
boundaries, including empty/short/oversized sources and nonempty prefixes.
Run with `lake env lean --run tests/PngSizeTests.lean`.
-/
namespace LeanSvg.Png.Tests
open LeanSvg.Png

def legacyZlibStoredRows (out : ByteArray) (rgba : ByteArray) (rowBytes h : Nat) : ByteArray := Id.run do
  let rawSize := h * (rowBytes + 1)
  let pieces := rowBytes / 65535 + 2
  let mut o := (out.push 0x78).push 0x01
  let mut pos := 0
  for y in [0:h] do
    if pos % 65535 == 0 then o := blockHeader o pos rawSize
    o := o.push 0
    pos := pos + 1
    let mut off := y * rowBytes
    let stop := off + rowBytes
    for _ in [0:pieces] do
      if off < stop then
        if pos % 65535 == 0 then o := blockHeader o pos rawSize
        let n := Nat.min (65535 - pos % 65535) (stop - off)
        let dst := o.size
        o := rgba.copySlice off o dst n false
        off := off + n
        pos := pos + n
  if rawSize == 0 then o := blockHeader o 0 0
  return o ++ be32 (adler32Rows rgba rowBytes h)

end LeanSvg.Png.Tests

open LeanSvg.Png LeanSvg.Png.Tests

def main : IO Unit := do
  let mut checks := 0
  for rowBytes in [0, 1, 4, 65534, 65535, 65536, 131070, 131071] do
    for h in [0, 1, 2, 3] do
      for size in [0, 7, rowBytes * h, rowBytes * h + 17] do
        let rgba : ByteArray := ⟨Array.ofFn (n := size) fun i => (i.val % 251).toUInt8⟩
        for initial in [ByteArray.empty, (⟨#[10, 20, 30]⟩ : ByteArray)] do
          let expected := legacyZlibStoredRows initial rgba rowBytes h
          let actual := zlibStoredRows initial rgba rowBytes h
          unless actual == expected do
            throw (IO.userError s!"writer mismatch: rowBytes={rowBytes}, h={h}, source={size}")
          checks := checks + 1
  IO.println s!"PNG writer byte identity: {checks}/{checks} cases passed"
