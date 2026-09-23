import LeanSvg.Xml
import LeanSvg.Geom
import Std.Data.HashMap

/-!
# `use` and `symbol` (T47)

`use` is resolved on the event stream, before `Svg.interpret` sees it, the way
usvg's tree builder resolves it (`svgtree/parse.rs`, `parse_svg_use_element`):
the referenced element's subtree is copied in as the `use` element's only
child, so style inheritance runs from the `use` element, not the definition
site.  The `use` element itself is kept as it is; `interpret` treats it as a
`g` whose `x`/`y` post-multiply its transform (usvg's `use_node::convert`).

A `symbol` target is not copied as a `symbol` but as the pieces usvg builds
from it (`use_node.rs`): an optional viewport clip — a generated `clipPath`
with one rect `(0, 0, w, h)`, since `interpret` has already translated by
`x`/`y` — and a `g` carrying the symbol's own attributes with the `viewBox`
transform in place of its `transform`.

Only `#id` references are followed, and only into the same event array; there
is no path to anything outside the input.

Bounds.  Recursion is on `maxDepth` fuel: a chain of more than `maxDepth`
nested `use` expansions is an error (usvg errors too, at its 1024 node depth
limit, which is where a reference cycle its own checks miss ends up).  The
output may hold at most `Xml.maxElements` elements — the same cap the parser
puts on a document — so the expanded stream is never bigger than a document
the parser itself would accept, and every bound downstream of the parser
carries over unchanged.  `maxWork` bounds the events scanned, including the
recursion checks, which copy nothing.  Exceeding any of them rejects the
document; a "billion laughs" of nested `use` fails fast instead of expanding.
-/

namespace LeanSvg
namespace Use

open Bytes

/-- Nesting bound for `use` expansion; `Svg` checks it against
`maxLayerDepth`. -/
def maxDepth : Nat := 10

/-- Largest number of elements the expanded stream may contain. -/
def maxElements : Nat := Xml.maxElements

/-- Largest number of events the expansion may visit, copies and recursion
checks together. -/
def maxWork : Nat := 16 * Xml.maxElements

/-- Prefix of the ids given to generated viewport `clipPath`s.  A document
that uses it itself is rejected rather than risking a silent clash. -/
def clipIdPrefix : String := "lean-svg:use-viewport:"

def attr (attrs : Array Xml.Attr) (name : String) : Option ByteArray :=
  (attrs.find? (fun a => a.name == name)).map (·.value)

/-- The link of a `use`: an unprefixed `href` wins over `xlink:href`
regardless of order (SVG 2).  Only a same-document `#id` is a link. -/
def hrefId (attrs : Array Xml.Attr) : Option String :=
  match (attr attrs "href").orElse (fun _ => attr attrs "xlink:href") with
  | none => none
  | some v =>
    let t := trim v
    if at' t 0 == 35 && t.size ≥ 2 then some (toStr (t.extract 1 t.size)) else none

/-- Elements a `use` can usefully copy: usvg's graphic elements plus the
containers `convert_element` descends into.  Any other target renders
nothing in usvg (the copy is not a graphic), so nothing is copied. -/
def isGraphicTarget (name : String) : Bool :=
  ["g", "switch", "svg", "symbol", "a", "use", "circle", "ellipse", "image", "line",
   "path", "polygon", "polyline", "rect", "text"].contains name

/-- Definitions `interpret` indexes by id.  usvg drops every `id` in a copy;
we keep them (CSS `#id` selectors must still match the copy, as usvg matches
CSS against the original node) except on these, so a copy never shadows the
original definition. -/
def isDefLike (name : String) : Bool :=
  ["clipPath", "linearGradient", "radialGradient", "mask", "pattern", "filter",
   "marker"].contains name

/-- A length or percentage: `(value, isPercent)`. -/
def lenPct (bs : ByteArray) : Option (Fx × Bool) :=
  let t := trim bs
  match parseNumber t 0 with
  | none => none
  | some (v, j) =>
    if at' t j == 37 then (if j + 1 == t.size then some (v, true) else none)
    else (parseLengthAll t).map (·, false)

def resolveLen (l : Fx × Bool) (ref : Fx) : Fx :=
  if l.2 then Int.ediv (l.1 * ref) 25600 else l.1

/-- Round `n / d` to nearest, halves away from zero; `d > 0`. -/
def divRound (n d : Int) : Int :=
  if n ≥ 0 then Int.ediv (2 * n + d) (2 * d) else -(Int.ediv (-2 * n + d) (2 * d))

/-! ## Viewport transform

Separate from the expansion so nested `<svg>` (T48) can share it. -/

/-- `preserveAspectRatio`: per axis `0`/`1`/`2` for min/mid/max, `none` for
`align="none"`, and `slice`.  Unparseable values give the default
`xMidYMid meet`. -/
def parseAspect (v : Option ByteArray) : Option (Nat × Nat) × Bool :=
  let dflt : Option (Nat × Nat) × Bool := (some (1, 1), false)
  match v with
  | none => dflt
  | some raw =>
    let toks := ((toStr (trim raw)).splitOn " ").filter (· ≠ "")
    let toks := if toks.head? == some "defer" then toks.drop 1 else toks
    let names := ["Min", "Mid", "Max"]
    let aligns : List (String × Nat × Nat) :=
      (List.range 3).flatMap fun x => (List.range 3).map fun y =>
        ("x" ++ names.getD x "" ++ "Y" ++ names.getD y "", x, y)
    let align : Option (Option (Nat × Nat)) := match toks.head? with
      | some "none" => some none
      | some a => (aligns.find? (·.1 == a)).map (fun p => some p.2)
      | none => none
    match align, toks.drop 1 with
    | some al, [] => (al, false)
    | some al, ["meet"] => (al, false)
    | some al, ["slice"] => (al, true)
    | _, _ => dflt

/-- usvg's `ViewBox::to_transform`: map the `viewBox` `(vx, vy, vw, vh)` onto
a `w × h` viewport.  `none` when either is empty. -/
def viewBoxMat (vb : Fx × Fx × Fx × Fx) (aspect : Option (Nat × Nat) × Bool)
    (w h : Fx) : Option Mat :=
  let (vx, vy, vw, vh) := vb
  if vw ≤ 0 || vh ≤ 0 || w ≤ 0 || h ≤ 0 then none
  else
    let sx := divRound (w * 65536) vw
    let sy := divRound (h * 65536) vh
    let (sx, sy) := match aspect with
      | (none, _) => (sx, sy)
      | (some _, slice) =>
        let s := if slice then Max.max sx sy else Min.min sx sy
        (s, s)
    let x := -divRound (vx * sx) 65536
    let y := -divRound (vy * sy) 65536
    let remW := w - divRound (vw * sx) 65536
    let remH := h - divRound (vh * sy) 65536
    let off (k : Nat) (rem : Fx) : Fx := if k == 0 then 0 else if k == 1 then divRound rem 2 else rem
    let (ax, ay) := aspect.1.getD (0, 0)
    some (Mat.mk' sx 0 0 sy (x + off ax remW) (y + off ay remH))

/-! ## Expansion -/

/-- `v / 2^bits` as an exact decimal. -/
def fmtFixed (v : Int) (bits : Nat) : String :=
  let a := v.natAbs
  let digits := toString ((a % 2 ^ bits) * 5 ^ bits)
  (if v < 0 then "-" else "") ++ toString (a / 2 ^ bits) ++ "." ++
    String.ofList (List.replicate (bits - digits.length) '0') ++ digits

def fmtMat (m : Mat) : String :=
  s!"matrix({fmtFixed m.a 16} {fmtFixed m.b 16} {fmtFixed m.c 16} {fmtFixed m.d 16} " ++
  s!"{fmtFixed m.e 8} {fmtFixed m.f 8})"

def mkAttr (name value : String) : Xml.Attr := ⟨name, value.toUTF8⟩

structure Ctx where
  events : Array Xml.Event
  /-- Index of the matching `close` for every `open_`. -/
  endOf : Array Nat
  /-- For every `use`: the index of the element its link names (first
  element with that id, like usvg's `id_map`). -/
  target : Array (Option Nat)

structure St where
  out : Array Xml.Event := #[]
  elems : Nat := 0
  work : Nat := 0
  clipN : Nat := 0
  /-- `clipPath` elements with an `id` emitted so far, generated ones included:
  `interpret` collects at most `maxClips` of them, and a viewport clip past
  that would be dropped silently, so generating one there is an error. -/
  clipPaths : Nat := 0
  maxClips : Nat := 0

def St.tick (st : St) : Except String St :=
  if st.work ≥ maxWork then throw "use: expansion exceeds the work budget"
  else pure { st with work := st.work + 1 }

def St.emit (st : St) (e : Xml.Event) : Except String St :=
  match e with
  | .open_ name attrs =>
    if st.elems ≥ maxElements then throw "use: expansion exceeds the element budget"
    else
      let k := if name == "clipPath" && (attr attrs "id").isSome then 1 else 0
      pure { st with out := st.out.push e, elems := st.elems + 1, clipPaths := st.clipPaths + k }
  | _ => pure { st with out := st.out.push e }

/-- usvg's recursion checks for the `use` at `j` whose link is `t`, reached
while copying for the `use` at `origin`: the link is the `use` itself or the
origin, or some `use` inside the link points back at `j` or at the link. -/
def isRecursive (c : Ctx) (j t : Nat) (origin : Option Nat) (st : St) :
    Except String (Bool × St) := do
  if t == j || origin == some t then return (true, st)
  let mut st := st
  for k in [t + 1 : c.endOf.getD t 0] do
    st ← st.tick
    match c.events.getD k default, c.target.getD k none with
    | .open_ "use" _, some t2 => if t2 == j || t2 == t then return (true, st)
    | _, _ => pure ()
  return (false, st)

/-- The attributes of the `g` that stands in for a copied `symbol`: its own,
minus what only the `use` machinery reads, plus the `viewBox` transform
(usvg overrides the symbol's own `transform` with it). -/
def symbolGroupAttrs (attrs : Array Xml.Attr) (vbMat : Option Mat) : Array Xml.Attr :=
  let drop := ["transform", "transform-origin", "x", "y", "width", "height", "viewBox",
               "preserveAspectRatio", "refX", "refY"]
  let kept := attrs.filter (fun a => !drop.contains a.name)
  match vbMat with
  | some m => kept.push (mkAttr "transform" (fmtMat m))
  | none => kept

/-- Copy `events[lo:hi]` into `st.out`, expanding every `use` met on the way.
`origin` is the `use` whose link is being copied (`none` for the document
itself), `vp` the viewport percentages resolve against, `copy` whether this
is a copy (which drops `style` elements and definition ids). -/
def expandRange (c : Ctx) : (fuel : Nat) → (lo hi : Nat) → (origin : Option Nat) →
    (vp : Fx × Fx) → (copy : Bool) → St → Except String St
  | 0, _, _, _, _, _, _ => throw s!"use: references nested deeper than {maxDepth}"
  | fuel + 1, lo, hi, origin, vp, copy, st0 => do
    let mut st := st0
    let mut skipTo := lo
    for j in [lo:hi] do
      if j < skipTo then continue
      st ← st.tick
      match c.events.getD j default with
      | .open_ name attrs =>
        if copy && name == "style" then
          skipTo := c.endOf.getD j j + 1
        else if name == "use" then
          skipTo := c.endOf.getD j j + 1
          st ← st.emit (.open_ name attrs)
          let link ← match c.target.getD j none with
            | none => pure none
            | some t =>
              match c.events.getD t default with
              | .open_ tname tattrs =>
                if !isGraphicTarget tname then pure none
                else do
                  let (rec_, st') ← isRecursive c j t origin st
                  st := st'
                  pure (if rec_ then none else some (t, tname, tattrs))
              | _ => pure none
          match link with
          | none => pure ()
          | some (t, tname, tattrs) =>
            let tEnd := c.endOf.getD t t
            if tname == "symbol" then
              -- `use_node::convert`, `linked_to_symbol`.
              let wAttr := (attr attrs "width").bind lenPct
              let hAttr := (attr attrs "height").bind lenPct
              let vw := match wAttr with | some l => resolveLen l vp.1 | none => vp.1
              let vh := match hAttr with | some l => resolveLen l vp.2 | none => vp.2
              let vp' := if vw > 0 && vh > 0 then (vw, vh) else vp
              let w := resolveLen (wAttr.getD (25600, true)) vp'.1
              let h := resolveLen (hAttr.getD (25600, true)) vp'.2
              let vb : Option (Fx × Fx × Fx × Fx) := (attr tattrs "viewBox").bind fun v =>
                let ns := parseNumberList v
                if ns.size == 4 then some (ns.getD 0 0, ns.getD 1 0, ns.getD 2 0, ns.getD 3 0)
                else none
              let vbMat := vb.bind fun vb =>
                viewBoxMat vb (parseAspect (attr tattrs "preserveAspectRatio")) w h
              let overflow := (attr tattrs "overflow").map (fun v => toStr (trim v))
              let clip := !(overflow == some "visible" || overflow == some "auto") && w > 0 && h > 0
              if clip then
                if st.clipPaths ≥ st.maxClips then
                  throw s!"use: more than {st.maxClips} clipPaths with symbol viewports"
                let cid := clipIdPrefix ++ toString st.clipN
                st := { st with clipN := st.clipN + 1 }
                st ← st.emit (.open_ "clipPath" #[mkAttr "id" cid])
                st ← st.emit (.open_ "rect" #[mkAttr "x" "0", mkAttr "y" "0",
                  mkAttr "width" (fmtFixed w 8), mkAttr "height" (fmtFixed h 8),
                  mkAttr "visibility" "visible"])
                st ← st.emit .close
                st ← st.emit .close
                st ← st.emit (.open_ "g" #[mkAttr "clip-path" s!"url(#{cid})"])
              st ← st.emit (.open_ "g" (symbolGroupAttrs tattrs vbMat))
              st ← expandRange c fuel (t + 1) tEnd (some j) vp' true st
              st ← st.emit .close
              if clip then st ← st.emit .close
            else if tname == "svg" then
              -- `linked_to_svg`: the `use` element's `width`/`height`, when
              -- given, replace the `svg`'s own.
              let over := #["width", "height"].filterMap fun n => (attr attrs n).map (⟨n, ·⟩)
              let svgAttrs := (tattrs.filter fun a => !(over.any (·.name == a.name))) ++ over
              st ← st.emit (.open_ "svg" svgAttrs)
              st ← expandRange c fuel (t + 1) tEnd (some j) vp true st
              st ← st.emit .close
            else
              st ← expandRange c fuel t (tEnd + 1) (some j) vp true st
          st ← st.emit .close
        else if copy && isDefLike name then
          st ← st.emit (.open_ name (attrs.filter (·.name != "id")))
        else
          st ← st.emit (.open_ name attrs)
      | e => st ← st.emit e
    return st

/-- Expand every `use` in `events`.  A document without `use` comes back
unchanged.  `vp` is the root viewport (what percentages resolve against),
`maxClips` how many `clipPath`s `interpret` will collect. -/
def expand (events : Array Xml.Event) (vp : Fx × Fx) (maxClips : Nat) :
    Except String (Array Xml.Event) := do
  if !events.any (fun e => match e with | .open_ "use" _ => true | _ => false) then
    return events
  let mut endOf : Array Nat := Array.replicate events.size 0
  let mut stack : Array Nat := #[]
  let mut ids : Std.HashMap String Nat := {}
  for i in [0:events.size] do
    match events.getD i default with
    | .open_ _ attrs =>
      stack := stack.push i
      match attr attrs "id" with
      | some v =>
        let s := toStr v
        if s.startsWith clipIdPrefix then throw s!"use: id prefix {clipIdPrefix} is reserved"
        if !ids.contains s then ids := ids.insert s i
      | none => pure ()
    | .close =>
      endOf := endOf.setIfInBounds (stack.back?.getD 0) i
      stack := stack.pop
    | .text _ => pure ()
  let target := events.map fun e => match e with
    | .open_ "use" attrs => (hrefId attrs).bind ids.get?
    | _ => none
  let st ← expandRange ⟨events, endOf, target⟩ (maxDepth + 1) 0 events.size none vp false
    { maxClips }
  return st.out

end Use
end LeanSvg
