import LeanSvg.Canvas
import LeanSvg.Xml
import LeanSvg.Fixed
import LeanSvg.Geom
import LeanSvg.Filter.Morphology
import Std.Data.HashMap

/-!
# Filters (T51): the model, the `<filter>` pre-pass and usvg's resolution

This file turns `filter="…"` into a list of `Resolved` filters in the
element's own user space, exactly as usvg's `parser/filter.rs` does, and
`LeanSvg/FilterApply.lean` runs them on pixels as resvg's `filter/mod.rs` does.

Three stages, split by what each one needs:

1. `scan` — one bounded pass over the XML events, collecting every `<filter>`
   element with its primitive children (raw attributes, plus the two things
   that need the ancestor chain: the inherited `color-interpolation-filters`
   and the `color` a `currentColor` flood resolves to).
2. `resolve` — at the referencing element's *close*, when its object bounding
   box is known: parse the `filter` value list (`url(#id)` and the CSS filter
   functions), follow `href`, resolve `filterUnits`/`primitiveUnits`, the
   region and every primitive's subregion into user-space rectangles, and wire
   `in`/`in2`/`result` into indices.  The outcome is usvg's three-way one:
   filters to apply, no filter at all, or "the element is not rendered".
3. `FilterApply.run` — at render time, on the layer's pixels.

Adding a primitive is local: one `Kind` constructor, one clause in
`convertPrim` below, and one case in `FilterApply.runPrim`.  A primitive usvg
knows but this renderer does not implement yet (`isKnownUnsupported`) makes the
whole `filter` value degrade to "no filter", which is exactly what the renderer
did for every filter before this task, so nothing that rendered before renders
worse.
-/

namespace LeanSvg
namespace Filter

open Bytes

/-! ## Binary32 helpers

usvg keeps every filter number as an `f32` and resvg's per-pixel colour
arithmetic (`feColorMatrix`, `feComponentTransfer`, arithmetic `feComposite`)
is `f32` too, ending in a *truncating* `as u8`.  A truncation sits exactly on
the integers, which is where an exact rational computation and the float one
disagree by one, and in linearRGB one level near black is thirteen levels once
converted back to sRGB.  So those three primitives run on `F32`, the exact
binary32 emulation `Canvas.lean` already carries for the blend modes. -/

/-- The binary32 nearest `num / den` for operands of any size.  `F32.ofRat`
sizes its quotient with `F32.bitLen`, which only sees 64 bits; here the
operands are measured with `Nat.log2` instead, so a 50-digit π or a `2^120`
fixed-point value rounds correctly too. -/
def ofRatBig (num den : Nat) : F32 :=
  if num == 0 || den == 0 then 0
  else
    let bn := Nat.log2 num + 1
    let bd := Nat.log2 den + 1
    if 26 + bd ≥ bn then
      let k := 26 + bd - bn
      let nk := num * 2 ^ k
      let q := nk / den
      F32.norm false q (F32.pbias - k) (q * den != nk)
    else
      let k := bn - bd - 26
      let dk := den * 2 ^ k
      let q := num / dk
      F32.norm false q (F32.pbias + k) (q * dk != num)

/-- `⌊v⌋` of a binary32, `0` for a negative, saturating at `2^40`. -/
def f32Floor (v : F32) : Nat :=
  if v == 0 || F32.isNeg v then 0
  else
    let m := F32.mant v
    let eb := F32.expo v
    if eb ≥ F32.bias then m * F32.p2 (Nat.min 16 (eb - F32.bias))
    else
      let s := F32.bias - eb
      if s > 30 then 0 else m >>> s

/-- `(f32_bound(0, v, 1) * 255.0) as u8`: resvg's `from_normalized`. -/
def f32TruncU8 (v : F32) : Nat :=
  if v == 0 || F32.isNeg v then 0
  else if !(F32.lt v F32.one) then 255
  else Nat.min 255 (f32Floor (F32.mul v F32.c255))

/-- The binary32 nearest `±mant · 10^e`, exponent clamped to ±60 (the same
clamp `Fixed.scaleDecimal`'s callers rely on). -/
def f32OfDec (neg : Bool) (mant : Nat) (e : Int) : F32 :=
  let e := if e > 60 then 60 else if e < -60 then -60 else e
  let v := if e ≥ 0 then ofRatBig (mant * 10 ^ e.toNat) 1 else ofRatBig mant (10 ^ (-e).toNat)
  if neg then F32.neg v else v

/-- A signed binary32 from a 16.16 value (a fixed-point computation's result). -/
def f32Of16 (v : Int) : F32 :=
  if v < 0 then F32.neg (ofRatBig (-v).toNat 65536) else ofRatBig v.toNat 65536

/-- π to 50 digits, as `piNum / piDen`. -/
def piNum : Nat := 314159265358979323846264338327950288419716939937510
def piDen : Nat := 100000000000000000000000000000000000000000000000000

/-- A binary32 as an exact signed rational `(neg, num, den)`. -/
def f32Rat (v : F32) : Bool × Nat × Nat :=
  let m := F32.mant v
  let eb := F32.expo v
  if v == 0 then (false, 0, 1)
  else if eb ≥ F32.bias then (F32.isNeg v, m * 2 ^ (Nat.min 200 (eb - F32.bias)), 1)
  else (F32.isNeg v, m, 2 ^ (Nat.min 200 (F32.bias - eb)))

/-- `(sin x, cos x)` of a binary32 `x`, each rounded to the nearest binary32:
what `f32::sin_cos` returns (libm's are correctly rounded on these inputs).
Computed once per primitive, so the arithmetic is exact and unhurried: `x` is
reduced into `[-π, π]` on a `2^120` grid and summed to forty Taylor terms. -/
def sinCosF32 (x : F32) : F32 × F32 := Id.run do
  let S : Nat := 2 ^ 120
  let (neg, n, d) := f32Rat x
  let pi : Int := (piNum * S / piDen : Nat)
  let mut X : Int := (n * S / d : Nat)
  if neg then X := -X
  X := Int.emod (X + pi) (2 * pi) - pi
  let mut sn : Int := 0
  let mut cs : Int := 0
  let mut term : Int := S
  for k in [0:48] do
    match k % 4 with
    | 0 => cs := cs + term
    | 1 => sn := sn + term
    | 2 => cs := cs - term
    | _ => sn := sn - term
    term := Int.tdiv (term * X) ((S : Int) * (k + 1))
  let toF := fun (v : Int) =>
    if v < 0 then F32.neg (ofRatBig (-v).toNat S) else ofRatBig v.toNat S
  return (toF sn, toF cs)

/-- `c as f32 / 255.0`, tabulated: resvg's `to_normalized_components`. -/
def byteNorm : Array F32 := (Array.range 256).map fun c => F32.div (F32.ofNat c) F32.c255

/-! ## The model -/

/-- A primitive's input, resolved: usvg's `Input`, with a `Reference` already
turned into the index of the primitive whose result it names. -/
inductive Input where
  | source
  | alpha
  | ref (i : Nat)
deriving Inhabited, Repr, BEq

/-- `feColorMatrix`'s four kinds (usvg `ColorMatrixKind`), coefficients as
binary32. -/
inductive CMKind where
  | matrix (m : Array F32)
  | saturate (v : F32)
  | hueRotate (deg : F32)
  | lumToAlpha
deriving Inhabited, Repr

/-- One `feFuncX` (usvg `TransferFunction`), without `gamma`, which needs a
`powf` and is left to the wave-2 task (a `gamma` makes the filter unsupported). -/
inductive TF where
  | identity
  | table (vs : Array F32)
  | discrete (vs : Array F32)
  | linear (slope intercept : F32)
deriving Inhabited, Repr

inductive CompOp where
  | over | inn | out | atop | xor
  | arith (k1 k2 k3 k4 : F32)
deriving Inhabited, Repr

/-- A primitive's operation.  Lengths (`dx`, `stdDeviation`) are in the
element's user space, already scaled by `primitiveUnits`, as usvg stores them,
on the 16.16 grid: a bounding-box fraction like `0.01` times the box would
lose a fifth of a percent on `Fx`'s. -/
inductive Kind where
  | flood (r g b a : Nat)
  | offset (i : Input) (dx dy : Int)
  | blur (i : Input) (sx sy : Int)
  | dropShadow (i : Input) (dx dy sx sy : Int) (r g b a : Nat)
  | merge (ins : Array Input)
  | blend (i1 i2 : Input) (mode : BlendMode)
  | composite (i1 i2 : Input) (op : CompOp)
  | colorMatrix (i : Input) (k : CMKind)
  | transfer (i : Input) (fr fg fb fa : TF)
  | morphology (i : Input) (op : MorphOp) (rx ry : Int)
deriving Inhabited

/-- A rectangle in user space, `Fx`; `w` and `h` positive (`NonZeroRect`). -/
structure URect where
  x : Fx
  y : Fx
  w : Fx
  h : Fx
deriving Inhabited, Repr, BEq

structure Prim where
  /-- The primitive subregion, user space. -/
  sub : URect
  /-- `color-interpolation-filters: linearRGB`. -/
  linear : Bool
  kind : Kind
deriving Inhabited

/-- One filter of an element's `filter` list, in its user space. -/
structure Resolved where
  region : URect
  prims : Array Prim
deriving Inhabited

/-- At most this many primitives per filter are kept; a `<filter>` with more
is treated as unsupported (the element renders unfiltered).  Every primitive
keeps a region-sized result alive, so this bounds a filter's memory to
`maxPrims` layers (and `FilterApply` bounds the product with the area). -/
def maxPrims : Nat := 256
/-- At most this many `<filter>` elements are collected. -/
def maxFilters : Nat := 4096
/-- At most this many filters in one `filter` value list. -/
def maxListLen : Nat := 32

/-! ## The pre-pass -/

/-- One primitive element, raw: its tag, attributes, the resolved inherited
`color-interpolation-filters` and `color`, and its own element children
(`feMergeNode`, `feFuncX`) with theirs. -/
structure RawPrim where
  name : String
  attrs : Array Xml.Attr
  linear : Bool
  color : Rgba
  /-- `flood-color`/`flood-opacity` after `inherit` (which svgtree resolves
  against the parent, i.e. the `<filter>` element, for these non-inherited
  properties). -/
  floodColor : Option ByteArray := none
  floodOpacity : Option ByteArray := none
  children : Array (String × Array Xml.Attr) := #[]
deriving Inhabited

structure RawFilter where
  id : String
  attrs : Array Xml.Attr
  prims : Array RawPrim := #[]
  /-- usvg's `has_children`: any element child at all, primitive or not. -/
  hasChildren : Bool := false
deriving Inhabited

structure Table where
  filters : Array RawFilter := #[]
  ids : Std.HashMap String Nat := {}
deriving Inhabited

/-- What the pre-pass needs from `Svg.lean`, which imports this file and so
cannot be imported by it: colour and opacity parsing, and the opacity grid. -/
structure Parsers where
  color : ByteArray → Option Rgba
  opacity : ByteArray → Option Nat
  opOne : Nat

def attr (attrs : Array Xml.Attr) (name : String) : Option ByteArray :=
  (attrs.find? (fun a => a.name == name)).map (·.value)

/-- A presentation attribute: the `style=""` declaration if there is one,
else the attribute (usvg's svgtree gives the style the last word). -/
def prop (attrs : Array Xml.Attr) (name : String) : Option ByteArray := Id.run do
  let mut out := attr attrs name
  match attr attrs "style" with
  | none => pure ()
  | some v =>
    for decl in splitTrim v 59 do
      let k := findByte decl 0 58
      if k < decl.size && eqAscii (lower (trim (decl.extract 0 k))) name then
        out := some (trim (decl.extract (k + 1) decl.size))
  return out

def maxIdBytes : Nat := 256

/-- Collect every `<filter>` element with its direct element children, in one
pass.  `color-interpolation-filters` and `color` are inherited properties, so
one entry per open element tracks them; the XML depth cap bounds both stacks. -/
def scan (P : Parsers) (events : Array Xml.Event) : Table := Id.run do
  let mut filters : Array RawFilter := #[]
  let mut ids : Std.HashMap String Nat := {}
  -- per open element: (linearRGB?, color)
  let mut inh : Array (Bool × Rgba) := #[]
  let mut depth : Nat := 0
  -- the open `<filter>`: its index and depth; the open primitive's depth
  let mut cur : Option Nat := none
  let mut curDepth : Nat := 0
  for ev in events do
    match ev with
    | .text _ => pure ()
    | .close =>
      depth := depth - 1
      inh := inh.pop
      if cur.isSome && depth == curDepth then cur := none
    | .open_ name attrs =>
      let (pLin, pCol) := inh.back?.getD (true, ⟨0, 0, 0, 255⟩)
      let col := match prop attrs "color" with
        | some v => (P.color v).getD pCol
        | none => pCol
      let lin := match prop attrs "color-interpolation-filters" with
        | some v =>
          let t := trim v
          if eqAscii t "sRGB" then false
          else if eqAscii t "inherit" then pLin
          else true
        | none => pLin
      match cur with
      | some fi =>
        if depth == curDepth + 1 then
          filters := filters.modify fi fun f =>
            if f.prims.size < maxPrims + 1 then
              let inh := fun (n : String) => match prop attrs n with
                | some v => if eqAscii (trim v) "inherit" then prop f.attrs n else some v
                | none => none
              { f with prims := f.prims.push ⟨name, attrs, lin, col, inh "flood-color",
                                                inh "flood-opacity", #[]⟩,
                       hasChildren := true }
            else { f with hasChildren := true }
        else if depth == curDepth + 2 then
          filters := filters.modify fi fun f =>
            match f.prims.back? with
            | some p =>
              let ch := if p.children.size < maxPrims then p.children.push (name, attrs)
                        else p.children
              { f with prims := f.prims.pop.push { p with children := ch } }
            | none => f
      | none =>
        if name == "filter" && filters.size < maxFilters then
          match (attr attrs "id").filter (·.size ≤ maxIdBytes) with
          | some fid =>
            ids := ids.insert (toStr fid) filters.size
            filters := filters.push { id := toStr fid, attrs }
            cur := some (filters.size - 1)
            curDepth := depth
          | none => pure ()
      inh := inh.push (lin, col)
      depth := depth + 1
  return { filters, ids }

/-! ## Numbers and lengths -/

/-- A number at `i` as a binary32, and the index after it. -/
def f32At (bs : ByteArray) (i : Nat) : Option (F32 × Nat) :=
  match parseDecimal bs i with
  | some (neg, m, e, j) => some (f32OfDec neg m e, j)
  | none => none

/-- A whole attribute as one binary32. -/
def f32All (bs : ByteArray) : Option F32 :=
  let t := trim bs
  match f32At t 0 with
  | some (v, j) => if j == t.size then some v else none
  | none => none

/-- A number list, all-or-nothing (svgtypes' `Vec<f32>` attribute parse): one
unreadable item makes the whole attribute absent. -/
def f32List (bs : ByteArray) : Option (Array F32) := Id.run do
  let t := trim bs
  let mut out : Array F32 := #[]
  let mut i := 0
  for _ in [0:t.size + 1] do
    i := skipWsComma t i
    if i ≥ t.size then break
    match f32At t i with
    | some (v, j) =>
      if out.size < 4096 then out := out.push v
      i := j
    | none => return none
  return some out

/-- A 16.16 number at `i` and the index after it. -/
def n16At (bs : ByteArray) (i : Nat) : Option (Int × Nat) := parseNumber16 bs i

/-- A number or percentage, as a 16.16 value and a flag (a length whose unit
is resolved by the caller): svgtypes' `Length` for the unit-free cases. -/
inductive Len where
  | num (v : Int)
  | pct (v : Int)
deriving Inhabited

/-- A length at `i`: number with an optional unit, on the 16.16 grid.
Absolute units convert at 96 dpi; `em`/`ex` use `fontSize`. -/
def lenAt (bs : ByteArray) (i : Nat) (fontSize : Fx) : Option (Len × Nat) :=
  match n16At bs i with
  | none => none
  | some (v, j) =>
    let v := if v > Fx.maxVal * 256 then Fx.maxVal * 256
             else if v < -(Fx.maxVal * 256) then -(Fx.maxVal * 256) else v
    if at' bs j == 37 then some (.pct v, j + 1)
    else if startsWith bs j "px" then some (.num v, j + 2)
    else if startsWith bs j "pt" then some (.num (Int.ediv (v * 4) 3), j + 2)
    else if startsWith bs j "pc" then some (.num (v * 16), j + 2)
    else if startsWith bs j "mm" then some (.num (Int.ediv (v * 960) 254), j + 2)
    else if startsWith bs j "cm" then some (.num (Int.ediv (v * 9600) 254), j + 2)
    else if startsWith bs j "in" then some (.num (v * 96), j + 2)
    else if startsWith bs j "em" then some (.num (Int.ediv (v * fontSize) 256), j + 2)
    else if startsWith bs j "ex" then some (.num (Int.ediv (v * fontSize) 512), j + 2)
    else some (.num v, j)

def lenAll (bs : ByteArray) (fontSize : Fx) : Option Len :=
  let t := trim bs
  match lenAt t 0 fontSize with
  | some (l, j) => if j == t.size then some l else none
  | none => none

/-- `convert_length` for a filter coordinate: under `objectBoundingBox` a
number is a fraction and `50%` is `0.5`; under `userSpaceOnUse` a percentage
is of the viewport's `ref`.  16.16 in, 16.16 out. -/
def convLen (obb : Bool) (ref : Fx) : Len → Int
  | .num v => v
  | .pct v => if obb then Int.ediv v 100 else Int.ediv (v * ref) 25600

/-- `x * bbox.w + bbox.x` with `x` a 16.16 fraction and the box in `Fx`. -/
def fracX (f : Int) (o len : Fx) : Fx := Int.ediv (f * len) 65536 + o

/-- `NonZeroRect::from_xywh`. -/
def mkRect (x y w h : Fx) : Option URect := if w > 0 && h > 0 then some ⟨x, y, w, h⟩ else none

/-- `f · v` for a 16.16 fraction `f`, rounded to nearest: a fraction like
`-10%` is not exact on the grid, and flooring its product would put a region
edge that is exactly on a pixel boundary one `Fx` below it. -/
def mul16 (f v : Int) : Int := Int.ediv (f * v + 32768) 65536

/-- `rect.bbox_transform(b)` for a rectangle of 16.16 fractions `(x, y, w, h)`:
`x · b.w + b.x`, …; `none` unless `w` and `h` are positive. -/
def bboxT16 (x y w h : Int) (b : URect) : Option URect :=
  if w > 0 && h > 0 then
    some ⟨mul16 x b.w + b.x, mul16 y b.h + b.y, mul16 w b.w, mul16 h b.h⟩
  else none

/-! ## Resolution -/

/-- `href` chain of filter `fi`, the element itself first, following links to
other `filter` elements until one repeats or `fuel` runs out (usvg's
`href_iter`, which also stops on a cycle). `none` marks a link to something
that is not a `<filter>` (which usvg treats as an error). -/
def hrefChain (tab : Table) (fi : Nat) : Array (Option Nat) := Id.run do
  let mut out : Array (Option Nat) := #[some fi]
  let mut cur := fi
  for _ in [0:16] do
    let f := tab.filters.getD cur default
    let h := match attr f.attrs "xlink:href" with
      | some v => some v
      | none => attr f.attrs "href"
    match h with
    | none => break
    | some v =>
      let t := trim v
      if at' t 0 != 35 then break
      match tab.ids.get? (toStr (t.extract 1 t.size)) with
      | some n =>
        if out.contains (some n) then break
        out := out.push (some n)
        cur := n
      | none =>
        -- An element that is not a `<filter>` (or does not exist): usvg's
        -- link to a missing element is dropped from the tree, a link to a
        -- non-filter element ends `find_filter_with_primitives` with `None`.
        out := out.push none
        break
  return out

/-- `resolve_attr` for a `<filter>`: the first element of the `href` chain that
has the attribute. -/
def chainAttr (tab : Table) (chain : Array (Option Nat)) (name : String) : Option ByteArray :=
  chain.findSome? fun o => o.bind fun n => attr (tab.filters.getD n default).attrs name

def unitsOf (v : Option ByteArray) (dfltObb : Bool) : Bool :=
  match v with
  | some t =>
    let t := trim t
    if eqAscii t "userSpaceOnUse" then false
    else if eqAscii t "objectBoundingBox" then true else dfltObb
  | none => dfltObb

/-- The tags usvg converts but this renderer does not implement yet: a
`<filter>` containing one of them degrades to "no filter" as a whole. -/
def isKnownUnsupported (name : String) : Bool :=
  name == "feTile" || name == "feImage" || name == "feConvolveMatrix" ||
  name == "feDisplacementMap" || name == "feTurbulence" ||
  name == "feDiffuseLighting" || name == "feSpecularLighting"

def isPrimitive (name : String) : Bool :=
  isKnownUnsupported name || name == "feDropShadow" || name == "feGaussianBlur" ||
  name == "feOffset" || name == "feBlend" || name == "feFlood" || name == "feComposite" ||
  name == "feMerge" || name == "feComponentTransfer" || name == "feColorMatrix" ||
  name == "feMorphology"

/-- `parse_in`, then `resolve_input`'s fallback: an unknown reference becomes
the previous result, or `SourceGraphic` for the first primitive. -/
def resolveInput (names : Array String) (v : Option ByteArray) : Input :=
  let prev : Input := if names.isEmpty then .source else .ref (names.size - 1)
  match v with
  | none => prev
  | some raw =>
    let t := trim raw
    if eqAscii t "SourceGraphic" || eqAscii t "BackgroundImage" || eqAscii t "BackgroundAlpha"
        || eqAscii t "FillPaint" || eqAscii t "StrokePaint" then .source
    else if eqAscii t "SourceAlpha" then .alpha
    else
      let s := toStr t
      -- The *last* earlier primitive with that `result` (resvg looks results
      -- up newest first).
      match (List.range names.size).reverse.find? (fun k => names.getD k "" == s) with
      | some k => .ref k
      | none => prev

def blendModeOf (v : Option ByteArray) : BlendMode :=
  match v with
  | none => .normal
  | some raw =>
    let t := trim raw
    if eqAscii t "multiply" then .multiply
    else if eqAscii t "screen" then .screen
    else if eqAscii t "overlay" then .overlay
    else if eqAscii t "darken" then .darken
    else if eqAscii t "lighten" then .lighten
    else if eqAscii t "color-dodge" then .colorDodge
    else if eqAscii t "color-burn" then .colorBurn
    else if eqAscii t "hard-light" then .hardLight
    else if eqAscii t "soft-light" then .softLight
    else if eqAscii t "difference" then .difference
    else if eqAscii t "exclusion" then .exclusion
    else if eqAscii t "hue" then .hue
    else if eqAscii t "saturation" then .saturation
    else if eqAscii t "color" then .color
    else if eqAscii t "luminosity" then .luminosity
    else .normal

/-- `flood-color` × `flood-opacity` (usvg `convert_flood`): the colour's own
alpha times the opacity, then `Opacity::to_u8`. -/
def floodOf (P : Parsers) (p : RawPrim) : Nat × Nat × Nat × Nat :=
  let c : Rgba := match p.floodColor with
    | some v =>
      if eqAsciiCI (trim v) "currentColor" then p.color
      else (P.color v).getD ⟨0, 0, 0, 255⟩
    | none => ⟨0, 0, 0, 255⟩
  let op := (p.floodOpacity.bind P.opacity).getD P.opOne
  let op := Nat.min op P.opOne
  (c.r, c.g, c.b, (2 * c.a * op + P.opOne) / (2 * P.opOne))

/-- `round(±mant · 10^e · sc)` on the 16.16 grid, `sc` an `Fx` scale: a
decimal literal times a `primitiveUnits` scale, rounded once. -/
def decTimes (neg : Bool) (mant : Nat) (e : Int) (sc : Fx) : Int :=
  let e := if e > 60 then 60 else if e < -60 then -60 else e
  let num : Int := (mant : Int) * sc * 256
  let v : Int := if e ≥ 0 then num * (10 ^ e.toNat : Nat)
    else Int.ediv (2 * num + (10 ^ (-e).toNat : Nat)) (2 * (10 ^ (-e).toNat : Nat))
  let lim := Fx.maxVal * 256
  let v := if v > lim then lim else if v < -lim then -lim else v
  if neg then -v else v

/-- `convert_std_dev_attr`: one or two non-negative numbers (svgtypes'
`NumberListParser`, which stops at the first unreadable item), anything else
is `0 0`; scaled by the `primitiveUnits` box.  16.16 user units. -/
def stdDevOf (v : Option ByteArray) (dflt : Fx × Fx) (scx scy : Fx) : Int × Int := Id.run do
  match v with
  | none => return (Int.ediv (dflt.1 * scx) 256 * 256, Int.ediv (dflt.2 * scy) 256 * 256)
  | some raw =>
    let t := trim raw
    let mut ds : Array (Bool × Nat × Int) := #[]
    let mut i := 0
    for _ in [0:4] do
      i := skipWsComma t i
      if i ≥ t.size then break
      match parseDecimal t i with
      | some (neg, m, e, j) =>
        ds := ds.push (neg, m, e)
        i := j
      | none => break
    let pos := fun (d : Bool × Nat × Int) (sc : Fx) =>
      let v := decTimes d.1 d.2.1 d.2.2 sc
      if v < 0 then 0 else v
    match ds with
    | #[n] => return (pos n scx, pos n scy)
    | #[n, m] => return (pos n scx, pos m scy)
    | _ => return (0, 0)

/-- A plain-number attribute times a `primitiveUnits` scale (`Fx`), exactly
(`decTimes`); 16.16 user units. -/
def numAttrScaled (attrs : Array Xml.Attr) (name : String) (dflt : Fx) (sc : Fx) : Int :=
  let d : Int := Int.ediv (dflt * sc) 256 * 256
  match attr attrs name with
  | some raw =>
    let t := trim raw
    match parseDecimal t 0 with
    | some (neg, m, e, j) => if j == t.size then decTimes neg m e sc else d
    | none => d
  | none => d

def f32Attr (attrs : Array Xml.Attr) (name : String) (dflt : F32) : F32 :=
  ((attr attrs name).bind f32All).getD dflt

/-- `convert_color_matrix_kind`, `none` falling back to the identity matrix. -/
def colorMatrixOf (attrs : Array Xml.Attr) : CMKind :=
  let ident : CMKind := .matrix #[F32.one, 0, 0, 0, 0, 0, F32.one, 0, 0, 0,
                                  0, 0, F32.one, 0, 0, 0, 0, 0, F32.one, 0]
  let vals := (attr attrs "values").bind f32List
  let ty := (attr attrs "type").map trim
  let isTy := fun (s : String) => match ty with | some t => eqAscii t s | none => false
  if isTy "saturate" then
    match vals with
    | some l =>
      match l[0]? with
      | some v =>
        let v := if F32.isNeg v then 0 else if F32.lt F32.one v then F32.one else v
        .saturate v
      | none => .saturate F32.one
    | none => ident
  else if isTy "hueRotate" then
    match vals with
    | some l => .hueRotate (l.getD 0 0)
    | none => ident
  else if isTy "luminanceToAlpha" then .lumToAlpha
  else
    match vals with
    | some l => if l.size == 20 then .matrix l else ident
    | none => ident

/-- `convert_transfer_function`; `none` for an absent/unknown `type` (the
channel stays identity), `some none` for `gamma` (unsupported here). -/
def transferOf (attrs : Array Xml.Attr) : Option (Option TF) :=
  match (attr attrs "type").map trim with
  | none => none
  | some t =>
    if eqAscii t "identity" then some (some .identity)
    else if eqAscii t "table" then
      some (some (.table (((attr attrs "tableValues").bind f32List).getD #[])))
    else if eqAscii t "discrete" then
      some (some (.discrete (((attr attrs "tableValues").bind f32List).getD #[])))
    else if eqAscii t "linear" then
      some (some (.linear (f32Attr attrs "slope" F32.one) (f32Attr attrs "intercept" 0)))
    else if eqAscii t "gamma" then some none
    else none

/-- One primitive element to a `Kind`, given the names of the results before
it and the `primitiveUnits` scale.  `none` = unsupported. -/
def convertPrim (P : Parsers) (p : RawPrim) (names : Array String) (scx scy : Fx) :
    Option Kind :=
  let a := p.attrs
  let inp := resolveInput names (attr a "in")
  let inp2 := resolveInput names (attr a "in2")
  match p.name with
  | "feFlood" => let (r, g, b, al) := floodOf P p; some (.flood r g b al)
  | "feOffset" =>
    some (.offset inp (numAttrScaled a "dx" 0 scx) (numAttrScaled a "dy" 0 scy))
  | "feGaussianBlur" =>
    let (sx, sy) := stdDevOf (attr a "stdDeviation") (0, 0) scx scy
    some (.blur inp sx sy)
  | "feDropShadow" =>
    let (sx, sy) := stdDevOf (attr a "stdDeviation") (512, 512) scx scy
    let (r, g, b, al) := floodOf P p
    some (.dropShadow inp (numAttrScaled a "dx" 512 scx) (numAttrScaled a "dy" 512 scy)
      sx sy r g b al)
  | "feMerge" =>
    some (.merge (p.children.map fun (_, ca) => resolveInput names (attr ca "in")))
  | "feBlend" => some (.blend inp inp2 (blendModeOf (attr a "mode")))
  | "feComposite" =>
    let op : CompOp := match (attr a "operator").map trim with
      | some t =>
        if eqAscii t "in" then .inn else if eqAscii t "out" then .out
        else if eqAscii t "atop" then .atop else if eqAscii t "xor" then .xor
        else if eqAscii t "arithmetic" then
          .arith (f32Attr a "k1" 0) (f32Attr a "k2" 0) (f32Attr a "k3" 0) (f32Attr a "k4" 0)
        else .over
      | none => .over
    some (.composite inp inp2 op)
  | "feColorMatrix" => some (.colorMatrix inp (colorMatrixOf a))
  | "feMorphology" =>
    let (rx, ry) := radiusOf (attr a "radius") scx scy
    some (.morphology inp (morphOpOf (attr a "operator")) rx ry)
  | "feComponentTransfer" => Id.run do
    let mut fs : Array TF := #[.identity, .identity, .identity, .identity]
    for (cn, ca) in p.children do
      let slot := if cn == "feFuncR" then 0 else if cn == "feFuncG" then 1
        else if cn == "feFuncB" then 2 else if cn == "feFuncA" then 3 else 4
      if slot < 4 then
        match transferOf ca with
        | some (some f) => fs := fs.setIfInBounds slot f
        | some none => return none
        | none => pure ()
    return some (.transfer inp (fs.getD 0 .identity) (fs.getD 1 .identity)
      (fs.getD 2 .identity) (fs.getD 3 .identity))
  | _ => none

/-- `resolve_primitive_region`.  Coordinates are `try_convert_length`s in
`primitiveUnits` (16.16); `none` stops collecting primitives (usvg's `break`).
The `objectBoundingBox` case keeps usvg's own quirk ("TODO: wrong"): the
filter region is bbox-transformed *by* the subregion numbers. -/
def primRegion (p : RawPrim) (obb : Bool) (bbox : Option URect) (region : URect)
    (vbW vbH fontSize : Fx) : Option URect :=
  let get := fun (n : String) (ref : Fx) =>
    (attr p.attrs n).bind (lenAll · fontSize) |>.map (convLen obb ref)
  let x := get "x" vbW
  let y := get "y" vbH
  let w := get "width" vbW
  let h := get "height" vbH
  let f16 := fun (v : Int) => Int.ediv (v + 128) 256
  if p.name == "feFlood" && obb then
    match bbox with
    | none => none
    | some b => bboxT16 (x.getD 0) (y.getD 0) (w.getD 65536) (h.getD 65536) b
  else if obb then
    let sx := x.getD 0
    let sy := y.getD 0
    let sw := w.getD 65536
    let sh := h.getD 65536
    if sw > 0 && sh > 0 then
      mkRect (mul16 sw region.x + f16 sx) (mul16 sh region.y + f16 sy)
        (mul16 sw region.w) (mul16 sh region.h)
    else none
  else
    mkRect ((x.map f16).getD region.x) ((y.map f16).getD region.y)
      ((w.map f16).getD region.w) ((h.map f16).getD region.h)

/-- The result of resolving an element's `filter` value. -/
inductive Outcome where
  /-- Nothing to do: no filter, `none`, a parse error, or a primitive this
  renderer does not implement (so the element renders as it did before). -/
  | noFilter
  /-- usvg removes the element (an invalid reference, an invalid region). -/
  | drop
  | filters (fs : Array Resolved)
deriving Inhabited

/-- What `resolve` needs to know about the referencing element. -/
structure ElemCtx where
  /-- The object bounding box in the element's user space, if non-empty. -/
  bbox : Option URect
  /-- The CSS `color` in force (a `drop-shadow()` without a colour uses it). -/
  color : Rgba
  fontSize : Fx
  /-- The viewport a `userSpaceOnUse` percentage resolves against. -/
  vbW : Fx
  vbH : Fx

/-- `convert_url` for filter `fi`.  `.error` is usvg's `Err(())` (element
dropped), `.unsupported` a primitive we do not implement. -/
inductive UrlRes where
  | ok (f : Resolved)
  | error
  | unsupported
deriving Inhabited

def convertUrl (P : Parsers) (tab : Table) (fi : Nat) (cx : ElemCtx) : UrlRes := Id.run do
  let chain := hrefChain tab fi
  let obb := unitsOf (chainAttr tab chain "filterUnits") true
  let pobb := unitsOf (chainAttr tab chain "primitiveUnits") false
  let get := fun (n : String) (ref : Fx) (dflt : Int) =>
    ((chainAttr tab chain n).bind (lenAll · cx.fontSize) |>.map (convLen obb ref)).getD dflt
  -- -10% / -10% / 120% / 120%, on the 16.16 grid of the units in force
  let fx := get "x" cx.vbW (if obb then -6554 else Int.ediv (-10 * cx.vbW * 256) 100)
  let fy := get "y" cx.vbH (if obb then -6554 else Int.ediv (-10 * cx.vbH * 256) 100)
  let fw := get "width" cx.vbW (if obb then 78643 else Int.ediv (120 * cx.vbW * 256) 100)
  let fh := get "height" cx.vbH (if obb then 78643 else Int.ediv (120 * cx.vbH * 256) 100)
  let f16 := fun (v : Int) => Int.ediv (v + 128) 256
  let mut region : URect := default
  if obb then
    match cx.bbox with
    | some b =>
      match bboxT16 fx fy fw fh b with
      | some r => region := r
      | none => return .error
    | none => return .error
  else
    match mkRect (f16 fx) (f16 fy) (f16 fw) (f16 fh) with
    | some r => region := r
    | none => return .error
  -- `find_filter_with_primitives`: the first element of the chain with children.
  let mut src : Option Nat := none
  for o in chain do
    match o with
    | none => return .error
    | some n =>
      if (tab.filters.getD n default).hasChildren then
        src := some n
        break
  let some si := src | return .error
  let raw := (tab.filters.getD si default).prims
  if raw.size > maxPrims then return .unsupported
  let mut scx : Fx := 256
  let mut scy : Fx := 256
  if pobb then
    match cx.bbox with
    | some b =>
      scx := b.w
      scy := b.h
    | none => return .error
  let mut prims : Array Prim := #[]
  let mut names : Array String := #[]
  let mut idx : Nat := 1
  for p in raw do
    if !isPrimitive p.name then continue
    if isKnownUnsupported p.name then return .unsupported
    let some sub := primRegion p pobb cx.bbox region cx.vbW cx.vbH cx.fontSize | break
    let some kind := convertPrim P p names scx scy | return .unsupported
    -- `gen_result`: an explicit name, or the next free `resultN`.
    let mut name := ""
    match attr p.attrs "result" with
    | some v =>
      idx := idx + 1
      name := toStr v
    | none =>
      for _ in [0:maxPrims + 2] do
        name := s!"result{idx}"
        idx := idx + 1
        if !names.contains name then break
    names := names.push name
    prims := prims.push ⟨sub, p.linear, kind⟩
  if prims.isEmpty then return .error
  return .ok ⟨region, prims⟩

/-! ### CSS filter functions -/

/-- Parse a colour at `i` for `drop-shadow()`: a `#hex`, a functional colour
up to its `)`, or a keyword.  Returns the colour and the index after it. -/
def colorAt (P : Parsers) (bs : ByteArray) (i : Nat) : Option (Rgba × Nat) :=
  let c := at' bs i
  if c == 35 then
    let j := skipWhile bs (i + 1) (fun c => isAlpha c || isDigit c)
    (P.color (bs.extract i j)).map (·, j)
  else if isAlpha c then
    let j := skipWhile bs i (fun c => isAlpha c || c == 45)
    if at' bs j == 40 then
      let k := findByte bs j 41
      if k ≥ bs.size then none else (P.color (bs.extract i (k + 1))).map (·, k + 1)
    else if eqAsciiCI (bs.extract i j) "currentColor" then none
    else (P.color (bs.extract i j)).map (·, j)
  else none

/-- A filter-function length (percentages rejected), 16.16 user units. -/
def fnLen (bs : ByteArray) (i : Nat) (fontSize : Fx) (nonNeg : Bool) : Option (Int × Nat) :=
  match lenAt bs i fontSize with
  | some (.num v, j) => if nonNeg && v < 0 then none else some (v, j)
  | _ => none

/-- `parse_generic_color_func`: `()` is 1, a number or percentage, never
negative.  As `(neg, mant, exp)` of the value (a percentage divided by 100). -/
def fnAmount (bs : ByteArray) (i : Nat) : Option ((Nat × Int) × Nat) :=
  if at' bs i == 41 then some ((1, 0), i)
  else
    match parseDecimal bs i with
    | some (neg, m, e, j) =>
      if neg && m != 0 then none
      else if at' bs j == 37 then some ((m, e - 2), j + 1)
      else some ((m, e), j)
    | none => none

def decF32 (d : Nat × Int) : F32 := f32OfDec false d.1 d.2
def decMin1 (d : Nat × Int) : F32 := let v := decF32 d; if F32.lt F32.one v then F32.one else v

/-- The filter-function kinds of `parser/filter.rs` (`convert_*_function`), in
binary32 as usvg computes their coefficients. -/
def grayscaleM (a : F32) : CMKind :=
  let r := fun (n d : Nat) => ofRatBig n d
  let t := F32.sub F32.one a
  .matrix #[F32.add (r 2126 10000) (F32.mul (r 7874 10000) t),
            F32.sub (r 7152 10000) (F32.mul (r 7152 10000) t),
            F32.sub (r 722 10000) (F32.mul (r 722 10000) t), 0, 0,
            F32.sub (r 2126 10000) (F32.mul (r 2126 10000) t),
            F32.add (r 7152 10000) (F32.mul (r 2848 10000) t),
            F32.sub (r 722 10000) (F32.mul (r 722 10000) t), 0, 0,
            F32.sub (r 2126 10000) (F32.mul (r 2126 10000) t),
            F32.sub (r 7152 10000) (F32.mul (r 7152 10000) t),
            F32.add (r 722 10000) (F32.mul (r 9278 10000) t), 0, 0,
            0, 0, 0, F32.one, 0]

def sepiaM (a : F32) : CMKind :=
  let r := fun (n d : Nat) => ofRatBig n d
  let t := F32.sub F32.one a
  .matrix #[F32.add (r 393 1000) (F32.mul (r 607 1000) t),
            F32.sub (r 769 1000) (F32.mul (r 769 1000) t),
            F32.sub (r 189 1000) (F32.mul (r 189 1000) t), 0, 0,
            F32.sub (r 349 1000) (F32.mul (r 349 1000) t),
            F32.add (r 686 1000) (F32.mul (r 314 1000) t),
            F32.sub (r 168 1000) (F32.mul (r 168 1000) t), 0, 0,
            F32.sub (r 272 1000) (F32.mul (r 272 1000) t),
            F32.sub (r 534 1000) (F32.mul (r 534 1000) t),
            F32.add (r 131 1000) (F32.mul (r 869 1000) t), 0, 0,
            0, 0, 0, F32.one, 0]

/-- One CSS filter function starting at `i` (after whitespace): the kind and
the index after its `)`, or `none` on a parse error (which makes usvg drop
the *whole* list, `Ok(Vec::new())`).  `url(#id)` is `Sum.inl id`. -/
def parseFn (P : Parsers) (bs : ByteArray) (i : Nat) (cx : ElemCtx) :
    Option ((String ⊕ Kind) × Nat) := Id.run do
  let j := skipWhile bs i (fun c => isAlpha c || isDigit c || c == 45)
  let name := toStr (bs.extract i j)
  let mut k := skipWs bs j
  if at' bs k != 40 then return none
  k := skipWs bs (k + 1)
  let close := fun (v : String ⊕ Kind) (k : Nat) =>
    let k := skipWs bs k
    if at' bs k == 41 then some (v, skipWs bs (k + 1)) else none
  match name with
  | "url" =>
    if at' bs k != 35 then return none
    let e := skipWhile bs (k + 1) (fun c => c != 32 && c != 41)
    if e == k + 1 then return none
    return close (.inl (toStr (bs.extract (k + 1) e))) e
  | "blur" =>
    if at' bs k == 41 then return close (.inr (.blur .source 0 0)) k
    match fnLen bs k cx.fontSize true with
    | some (v, e) => return close (.inr (.blur .source v v)) e
    | none => return none
  | "drop-shadow" =>
    if at' bs k == 41 then return none
    let mut col : Option Rgba := none
    let mut cur := false
    match colorAt P bs k with
    | some (c, e) => col := some c; k := skipWs bs e
    | none =>
      if startsWith bs k "currentColor" then cur := true; k := skipWs bs (k + 12)
    let some (dx, e1) := fnLen bs k cx.fontSize false | return none
    k := skipWs bs e1
    let some (dy, e2) := fnLen bs k cx.fontSize false | return none
    k := skipWs bs e2
    let mut sd : Int := 0
    match fnLen bs k cx.fontSize true with
    | some (v, e) => sd := v; k := skipWs bs e
    | none => pure ()
    if col.isNone && !cur then
      match colorAt P bs k with
      | some (c, e) => col := some c; k := skipWs bs e
      | none => if startsWith bs k "currentColor" then k := k + 12
    let c := col.getD cx.color
    return close (.inr (.dropShadow .source dx dy sd sd c.r c.g c.b c.a)) k
  | "hue-rotate" =>
    if at' bs k == 41 then return close (.inr (.colorMatrix .source (.hueRotate 0))) k
    -- `Angle::to_degrees() as f32`: the exact value, rounded once.
    let some (neg, m, ex, e) := parseDecimal bs k | return none
    let ex := if ex > 60 then 60 else if ex < -60 then -60 else ex
    let (n, d) : Nat × Nat := if ex ≥ 0 then (m * 10 ^ ex.toNat, 1) else (m, 10 ^ (-ex).toNat)
    let sg := fun (v : F32) => if neg then F32.neg v else v
    let (deg, e) :=
      if startsWith bs e "deg" then (some (sg (ofRatBig n d)), e + 3)
      else if startsWith bs e "grad" then (some (sg (ofRatBig (n * 9) (d * 10))), e + 4)
      else if startsWith bs e "rad" then (some (sg (ofRatBig (n * 180 * piDen) (d * piNum))), e + 3)
      else if startsWith bs e "turn" then (some (sg (ofRatBig (n * 360) d)), e + 4)
      else if m == 0 then (some 0, e) else (none, e)
    match deg with
    | some d => return close (.inr (.colorMatrix .source (.hueRotate d))) e
    | none => return none
  | _ =>
    let some (amt, e) := fnAmount bs k | return none
    let kind : Option Kind := match name with
      | "grayscale" => some (.colorMatrix .source (grayscaleM (decMin1 amt)))
      | "sepia" => some (.colorMatrix .source (sepiaM (decMin1 amt)))
      | "saturate" => some (.colorMatrix .source (.saturate (decF32 amt)))
      | "invert" =>
        let a := decMin1 amt
        let t := TF.table #[a, F32.sub F32.one a]
        some (.transfer .source t t t .identity)
      | "opacity" => some (.transfer .source .identity .identity .identity (.table #[0, decMin1 amt]))
      | "brightness" =>
        let l := TF.linear (decF32 amt) 0
        some (.transfer .source l l l .identity)
      | "contrast" =>
        let a := decF32 amt
        let half := ofRatBig 1 2
        let l := TF.linear a (F32.add (F32.neg (F32.mul half a)) half)
        some (.transfer .source l l l .identity)
      | _ => none
    match kind with
    | some kd => return close (.inr kd) e
    | none => return none

/-- `filter::convert`: an element's whole `filter` value. -/
def resolve (P : Parsers) (tab : Table) (raw : ByteArray) (cx : ElemCtx) : Outcome := Id.run do
  let t := trim raw
  if t.size == 0 || eqAscii t "none" then return .noFilter
  let mut out : Array Resolved := #[]
  let mut invalidUrl := false
  let mut i := 0
  for _ in [0:maxListLen + 1] do
    i := skipWs t i
    if i ≥ t.size then break
    if out.size ≥ maxListLen then return .noFilter
    match parseFn P t i cx with
    | none => return .noFilter
    | some (item, j) =>
      i := j
      match item with
      | .inl id =>
        match tab.ids.get? id with
        | some fi =>
          match convertUrl P tab fi cx with
          | .ok f => out := out.push f
          | .error => invalidUrl := true
          | .unsupported => return .noFilter
        | none => invalidUrl := true
      | .inr kind =>
        -- A function's region is a fixed fraction of the object box; without
        -- a box the function is skipped (a warning in usvg, not an error).
        match cx.bbox with
        | none => pure ()
        | some b =>
          let reg? := match kind with
            | .dropShadow .. | .blur .. => bboxT16 (-32768) (-32768) 131072 131072 b
            | _ => bboxT16 (-6554) (-6554) 78643 78643 b
          match reg? with
          | some reg => out := out.push ⟨reg, #[⟨reg, false, kind⟩]⟩
          | none => pure ()
  if i < t.size then return .noFilter
  if out.isEmpty && invalidUrl then return .drop
  if out.isEmpty then return .noFilter
  return .filters out

end Filter
end LeanSvg
