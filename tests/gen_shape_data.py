#!/usr/bin/env python3
"""Generate LeanSvg/ShapeData.lean: the Unicode and shaper tables T93's shaper
(LeanSvg/Shape.lean) reads, taken verbatim from harfrust 0.12.0 -- the shaper
resvg 0.48.1 links -- so that our shaping decisions match its own.

harfrust keeps these tables as packed Rust arrays behind crate-private
accessors, so this script copies the table files out of the cargo registry
(`~/.cargo/registry/src/*/harfrust-0.12.0`, installed by
scripts/cloud-setup.sh's `cargo install resvg`) into a throwaway crate under
/tmp/tabex, runs every accessor over U+0000..U+10FFFF, and packs the runs:

    general category, modified combining class, script, Arabic joining
    type, Indic (category, position), canonical decompositions (with a flag
    for "compose(a, b) gives this back").

    python3 tests/gen_shape_data.py            # writes LeanSvg/ShapeData.lean

Every table is a base64 string of fixed-width big-endian records; the Lean
side decodes each once at module initialisation and binary-searches it.
"""

import base64
import glob
import os
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORK = Path("/tmp/tabex")

MAIN_RS = r'''
mod hb;
use hb::ucd_table::ucd::*;
use std::io::Write;
fn runs(name: &str, f: &dyn Fn(u32) -> i64, out: &mut impl Write) {
    let mut start = 0u32; let mut cur = f(0);
    for u in 1..=0x10FFFFu32 {
        let v = f(u);
        if v != cur { writeln!(out, "{} {} {} {}", name, start, u - 1, cur).unwrap(); start = u; cur = v; }
    }
    writeln!(out, "{} {} {} {}", name, start, 0x10FFFF, cur).unwrap();
}
fn main() {
    let stdout = std::io::stdout(); let mut out = std::io::BufWriter::new(stdout.lock());
    runs("gc", &|u| _hb_ucd_gc(u as usize) as i64, &mut out);
    runs("ccc", &|u| {
        if u == 0x1A60 || u == 0x0FC6 { 254 } else if u == 0x0F39 { 127 }
        else { hb::mcc::MODIFIED_COMBINING_CLASS[_hb_ucd_ccc(u as usize) as usize] as i64 }
    }, &mut out);
    runs("sc", &|u| _hb_ucd_sc(u as usize) as i64, &mut out);
    for (i, s) in _hb_ucd_sc_map.iter().enumerate() { writeln!(out, "scname {} {}", i, s.0).unwrap(); }
    runs("jt", &|u| hb::ot_shaper_arabic_table::joining_type(u) as i64, &mut out);
    runs("indic", &|u| { let (c, p) = hb::ot_shaper_indic_table::get_categories(u); (c as i64) * 256 + p as i64 }, &mut out);
    for u in 0..=0x10FFFFu32 {
        if (0xAC00..0xD7A4).contains(&u) { continue; }
        if let Some((a, b)) = hb::norm::decompose(u) {
            let comp = if b != 0 { hb::norm::compose(a, b) == Some(u) } else { false };
            writeln!(out, "dm {} {} {} {}", u, a, b, comp as u8).unwrap();
        }
    }
}
'''


def section(text: str, start_pat: str) -> str:
    """The block starting at the first line matching `start_pat` through the
    next line that is exactly `}` or `];`."""
    lines = text.splitlines()
    for i, l in enumerate(lines):
        if re.match(start_pat, l):
            for j in range(i, len(lines)):
                if lines[j] in ("}", "];"):
                    return "\n".join(lines[i : j + 1]) + "\n"
    raise SystemExit(f"pattern {start_pat!r} not found")


def build_extractor() -> Path:
    hb = Path(glob.glob(os.path.expanduser("~/.cargo/registry/src/*/harfrust-0.12.0/src/hb"))[0])
    src = WORK / "src" / "hb"
    src.mkdir(parents=True, exist_ok=True)
    (WORK / "Cargo.toml").write_text('[package]\nname = "tabex"\nversion = "0.1.0"\nedition = "2021"\n')
    for f in ["algs.rs", "ucd_table.rs", "ot_shaper_arabic_table.rs", "ot_shaper_indic_table.rs"]:
        (src / f).write_text((hb / f).read_text())
    ucd = (hb / "ucd_table.rs").read_text()
    names = sorted(set(re.findall(r"script::([A-Z_0-9]+)", ucd)))
    (src / "common.rs").write_text(
        "#![allow(dead_code, non_upper_case_globals)]\n"
        "#[derive(Clone,Copy,Debug)] pub struct Script(pub &'static str);\n"
        "pub mod script { use super::Script;\n"
        + "".join(f'pub const {n}: Script = Script("{n}");\n' for n in names)
        + "}\n"
    )
    (src / "unicode.rs").write_text("pub type Codepoint = u32;\n")
    (src / "ot_shaper_arabic.rs").write_text(
        "#[allow(dead_code)]\n#[derive(Clone, Copy, PartialEq, PartialOrd, Debug)]\n"
        "pub enum hb_arabic_joining_type_t { U = 0, L = 1, R = 2, D = 3, GroupAlaph = 4, "
        "GroupDalathRish = 5, T = 6, X = 7 }\n"
    )
    indic = (hb / "ot_shaper_indic.rs").read_text()
    (src / "ot_shaper_indic.rs").write_text(
        "#![allow(dead_code, non_upper_case_globals, non_snake_case)]\n"
        + section(indic, r"pub mod ot_category_t")
        + section(indic, r"pub mod ot_position_t")
    )
    uni = (hb / "unicode.rs").read_text()
    (src / "mcc.rs").write_text(
        "#![allow(dead_code, non_upper_case_globals)]\n"
        + section(uni, r"pub mod combining_class")
        + section(uni, r"pub mod modified_combining_class")
        + section(uni, r"static MODIFIED_COMBINING_CLASS").replace("static", "pub static", 1)
    )
    consts = "\n".join(l for l in uni.splitlines() if re.match(r"const [SLVTN]_", l))
    (src / "norm.rs").write_text(
        "use crate::hb::ucd_table::ucd::*; use crate::hb::algs::*; pub type Codepoint = u32;\n"
        + section(uni, r"pub fn compose\(a: Codepoint")
        + section(uni, r"fn compose_hangul")
        + section(uni, r"pub fn decompose\(ab: Codepoint\)")
        + section(uni, r"pub fn decompose_hangul")
        + consts
        + "\n"
    )
    (src / "mod.rs").write_text(
        "#![allow(dead_code, non_upper_case_globals, non_snake_case, non_camel_case_types, "
        "unused_imports, clippy::all)]\n"
        "pub mod algs; pub mod common; pub mod ucd_table; pub mod unicode; pub mod ot_shaper_arabic; "
        "pub mod ot_shaper_arabic_table; pub mod ot_shaper_indic; pub mod ot_shaper_indic_table; "
        "pub mod mcc; pub mod norm;\n"
    )
    (WORK / "src" / "main.rs").write_text(MAIN_RS)
    subprocess.run(["cargo", "build", "--release", "-q"], cwd=WORK, check=True)
    common = (hb / "common.rs").read_text()
    iso = dict(re.findall(r'pub const ([A-Z_0-9]+): Script = Script::from_bytes\(b"(....)"\)', common))
    return iso


def b64(bs: bytes) -> str:
    return base64.b64encode(bs).decode()


def u24(v: int) -> bytes:
    return v.to_bytes(3, "big")


def main() -> None:
    iso = build_extractor()
    out = subprocess.run([str(WORK / "target/release/tabex")], check=True, capture_output=True, text=True).stdout
    rows = [l.split() for l in out.splitlines()]

    def runs(name: str, width: int) -> str:
        bs = b""
        for r in rows:
            if r[0] == name:
                v = int(r[3])
                bs += u24(int(r[1])) + v.to_bytes(width, "big")
        return b64(bs)

    scnames = {int(r[1]): r[2] for r in rows if r[0] == "scname"}
    tags = "".join(iso[scnames[i]] for i in range(len(scnames)))
    dm = b"".join(
        u24(int(r[1])) + u24(int(r[2])) + u24(int(r[3])) + bytes([int(r[4])]) for r in rows if r[0] == "dm"
    )
    cm = sorted((int(r[2]), int(r[3]), int(r[1])) for r in rows if r[0] == "dm" and r[4] == "1")
    cmb = b"".join(u24(a) + u24(b) + u24(c) for a, b, c in cm)
    lean = f'''-- Generated by tests/gen_shape_data.py from harfrust 0.12.0's tables. Do not edit by hand.
import LeanSvg.Font

/-!
# Unicode and shaper tables for `LeanSvg/Shape.lean` (T93)

harfrust 0.12.0's own data (the shaper resvg 0.48.1 uses), dumped by
`tests/gen_shape_data.py` and packed as base64 runs: each table is a sorted
list of `(first codepoint, value)` records, the value holding until the next
record starts.  Lookups binary-search it (21 halvings cover the codepoint
range).  Decoding happens once, at module initialisation.
-/

namespace LeanSvg.ShapeData

open LeanSvg.Font (u8 u16)

/-- `(start, value)` runs from `width`-byte values after a 24-bit start. -/
def decodeRuns (s : String) (width : Nat) : Array (Nat × Nat) := Id.run do
  let bs := Font.base64Decode s
  let rec_ := 3 + width
  let mut out : Array (Nat × Nat) := Array.emptyWithCapacity (bs.size / rec_)
  for k in [0:bs.size / rec_] do
    let i := rec_ * k
    let mut v := 0
    for j in [0:width] do v := v * 256 + u8 bs (i + 3 + j)
    out := out.push (u16 bs i * 256 + u8 bs (i + 2), v)
  return out

/-- The value of the run containing `cp` (`0` before the first run). -/
def lookupRuns (rs : Array (Nat × Nat)) (cp : Nat) : Nat := Id.run do
  -- invariant: rs[lo].1 ≤ cp < rs[hi].1 (with hi = size meaning +∞)
  let mut lo := 0
  let mut hi := rs.size
  if rs.size == 0 || (rs.getD 0 (0, 0)).1 > cp then return 0
  for _ in [0:32] do
    if hi - lo ≤ 1 then break
    let mid := (lo + hi) / 2
    if (rs.getD mid (0, 0)).1 ≤ cp then lo := mid else hi := mid
  return (rs.getD lo (0, 0)).2

def gcRuns : Array (Nat × Nat) := decodeRuns "{runs('gc', 1)}" 1

def cccRuns : Array (Nat × Nat) := decodeRuns "{runs('ccc', 1)}" 1

def scRuns : Array (Nat × Nat) := decodeRuns "{runs('sc', 1)}" 1

def jtRuns : Array (Nat × Nat) := decodeRuns "{runs('jt', 1)}" 1

def indicRuns : Array (Nat × Nat) := decodeRuns "{runs('indic', 2)}" 2

/-- ISO 15924 tags of harfrust's script indices, four characters each. -/
def scriptTags : String := "{tags}"

/-- Canonical decompositions: `(cp, a, b, recomposes)`, sorted by `cp`;
`b = 0` for a singleton; `recomposes` when harfrust's `compose a b` gives `cp`
back (not a composition exclusion). -/
def dmTable : Array (Nat × Nat × Nat × Bool) := Id.run do
  let bs := Font.base64Decode "{b64(dm)}"
  let mut out : Array (Nat × Nat × Nat × Bool) := Array.emptyWithCapacity (bs.size / 10)
  for k in [0:bs.size / 10] do
    let i := 10 * k
    let r := fun (o : Nat) => u16 bs (i + o) * 256 + u8 bs (i + o + 2)
    out := out.push (r 0, r 3, r 6, u8 bs (i + 9) != 0)
  return out

/-- Canonical compositions `(a, b, ab)`, sorted by `(a, b)`: the `dmTable`
rows that recompose. -/
def cmTable : Array (Nat × Nat × Nat) := Id.run do
  let bs := Font.base64Decode "{b64(cmb)}"
  let mut out : Array (Nat × Nat × Nat) := Array.emptyWithCapacity (bs.size / 9)
  for k in [0:bs.size / 9] do
    let i := 9 * k
    let r := fun (o : Nat) => u16 bs (i + o) * 256 + u8 bs (i + o + 2)
    out := out.push (r 0, r 3, r 6)
  return out

/-! ## Accessors -/

/-- harfrust's general category number (`hb_gc`: 0 Cc, 1 Cf, 2 Cn, 3 Co,
4 Cs, 5 Ll, 6 Lm, 7 Lo, 8 Lt, 9 Lu, 10 Mc, 11 Me, 12 Mn, 13 Nd, 14 Nl, 15 No,
16 Pc, 17 Pd, 18 Pe, 19 Pf, 20 Pi, 21 Po, 22 Ps, 23 Sc, 24 Sk, 25 Sm, 26 So,
27 Zl, 28 Zp, 29 Zs). -/
def genCat (cp : Nat) : Nat := lookupRuns gcRuns cp

/-- harfrust's *modified* combining class (`modified_combining_class`). -/
def modCcc (cp : Nat) : Nat := lookupRuns cccRuns cp

/-- The ISO 15924 tag of `cp`'s script, e.g. `"Arab"`, `"Zyyy"` (Common),
`"Zinh"` (Inherited). -/
def scriptOf (cp : Nat) : String :=
  let i := lookupRuns scRuns cp
  String.Pos.Raw.extract scriptTags ⟨4 * i⟩ ⟨4 * i + 4⟩

/-- Arabic joining type (`hb_arabic_joining_type_t`: 0 U, 1 L, 2 R, 3 D,
4 Alaph, 5 Dalath-Rish, 6 T, 7 X = decide by general category). -/
def joiningType (cp : Nat) : Nat := lookupRuns jtRuns cp

/-- Indic `(category, position)` (`ot_category_t`, `ot_position_t`). -/
def indicCatPos (cp : Nat) : Nat × Nat :=
  let v := lookupRuns indicRuns cp
  (v / 256, v % 256)

/-- One step of canonical decomposition, `(a, b)` with `b = 0` for a
singleton; Hangul syllables algorithmically (harfrust `decompose`). -/
def decompose (cp : Nat) : Option (Nat × Nat) := Id.run do
  if 0xAC00 ≤ cp && cp < 0xAC00 + 11172 then
    let si := cp - 0xAC00
    if si % 28 != 0 then return some (0xAC00 + si / 28 * 28, 0x11A7 + si % 28)
    return some (0x1100 + si / 588, 0x1161 + si % 588 / 28)
  let mut lo := 0
  let mut hi := dmTable.size
  for _ in [0:32] do
    if lo ≥ hi then break
    let mid := (lo + hi) / 2
    let (c, a, b, _) := dmTable.getD mid (0, 0, 0, false)
    if c == cp then return some (a, b)
    if c < cp then lo := mid + 1 else hi := mid
  return none

/-- Canonical composition of the pair, or `none` (harfrust `compose`,
Hangul algorithmically). -/
def compose (a b : Nat) : Option Nat := Id.run do
  if 0x1100 ≤ a && a < 0x1100 + 19 && 0x1161 ≤ b && b < 0x1161 + 21 then
    return some (0xAC00 + (a - 0x1100) * 588 + (b - 0x1161) * 28)
  if 0xAC00 ≤ a && a ≤ 0xAC00 + 11172 - 28 && 0x11A7 ≤ b && b < 0x11A7 + 28 &&
      (a - 0xAC00) % 28 == 0 then
    return some (a + (b - 0x11A7))
  let mut lo := 0
  let mut hi := cmTable.size
  for _ in [0:32] do
    if lo ≥ hi then break
    let mid := (lo + hi) / 2
    let (x, y, c) := cmTable.getD mid (0, 0, 0)
    if x == a && y == b then return some c
    if x < a || (x == a && y < b) then lo := mid + 1 else hi := mid
  return none

end LeanSvg.ShapeData
'''
    (REPO / "LeanSvg" / "ShapeData.lean").write_text(lean)
    print("wrote LeanSvg/ShapeData.lean", len(lean), "bytes")


if __name__ == "__main__":
    main()
