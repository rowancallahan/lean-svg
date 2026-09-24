import LeanSvg.Xml
import LeanSvg.Css
import LeanSvg.Text
import LeanSvg.FontSet
import LeanSvg.Use

/-!
# `foreignObject` HTML labels (T104)

Mermaid writes every flowchart/state/class/ER/mindmap label as XHTML inside a
`<foreignObject>`: `<div style="line-height: 1.5; text-align: center; …">
<span class="nodeLabel"><p>label</p></span></div>`.  usvg skips
`foreignObject`, so resvg draws none of that text; Chromium lays it out as
HTML.  This module renders a small, bounded subset of it, as Chromium would,
by rewriting the event stream before `Svg.interpret` sees it (like
`Use.expand`): each `foreignObject` becomes a `<g>` holding one SVG `<text>`
per line box, so the ordinary text engine shapes and paints the glyphs.

The subset:

* Elements `div`, `p` (blocks: a boundary starts a new line), `span`, `b`,
  `strong`, `i`, `em` (inline) and `br` (a forced line break), in the XHTML
  namespace (`Xml.parse` delivers them as `html:<name>`).  Any other element
  inside the `foreignObject`, and a `display: none` one, is skipped with its
  subtree.  No scripting, no images, no external resources, no tables.
* CSS from inline `style` and the document's `<style>` rules, matched against
  the whole element chain (so `#my-svg span {…}` applies), for `color`,
  `font-size` (`px`, `pt`, `em`, `rem`, `%`, unitless on SVG elements),
  `font-weight`, `font-style`, `font-family`, `text-align`, `line-height`
  (`normal`, a number, a length) and `white-space` (`nowrap`/`pre` do not
  wrap; everything else does).  These properties inherit from the SVG
  ancestors too (their presentation attributes and CSS), as in a browser.
  `b`/`strong` default to bold and `i`/`em` to italic.
* White space collapses as in `white-space: normal`; words wrap greedily at
  the box width, measured with the embedded face that will draw them
  (advances without kerning).  Lines stack from the box top; each line box is
  `line-height` tall with the text centred in it on the face's ascent and
  descent (CSS half-leading), so the baseline is
  `top + (lineHeight − (ascent − descent))/2 + ascent`.  `text-align` places
  the line in the box (`text-anchor` start/middle/end).

A `div`/`p` with a `background-color` paints it as a rect the width of the box
over that block's line boxes (Mermaid's edge-label boxes; its blocks are as
wide as the box, which Mermaid sized to the text).  Not reproduced:
margins/padding/borders (Mermaid resets `p`'s margin), inline (`span`)
backgrounds, the clip to the
`foreignObject` box, mixed font sizes within one line (the first run's size
sets the line box), bidi, and `white-space: pre`'s preserved spaces.  A
`foreignObject` that is a direct child of `<switch>` is left alone, so the
switch keeps choosing its SVG fallback exactly as before.  A zero-size box
renders nothing, as in Chromium.

Bounds: one pass over the events; the output is checked against
`Xml.maxElements` like `Use.expand`'s, and every loop is over an array. -/

namespace LeanSvg
namespace ForeignObject

open Bytes

/-- The inherited properties this subset understands.  Colours and families
stay raw CSS text and go straight into the generated `style`. -/
structure HStyle where
  color : ByteArray := "black".toUTF8
  /-- `Fx` (1/256 px). -/
  size : Int := 16 * 256
  weight : Nat := 400
  italic : Bool := false
  family : ByteArray := ByteArray.empty
  /-- 0 start, 1 centre, 2 end. -/
  align : Nat := 0
  /-- `none` = `normal`; `(true, f)` a factor `f/256` of the font size;
  `(false, px)` a length in `Fx`. -/
  lineHeight : Option (Bool × Int) := none
  wrap : Bool := true
deriving Inhabited, BEq

inductive Item where
  | text (t : ByteArray) (st : HStyle)
  | br (st : HStyle)
  | block
  /-- A block with a `background-color` opens / closes. -/
  | bgStart (color : ByteArray)
  | bgEnd
deriving Inhabited

/-- A decimal with an optional unit, value in `Fx`: `12.5px` → `(3200, "px")`. -/
def parseNum (v : ByteArray) : Option (Int × String) := Id.run do
  let t := lower (trim v)
  let mut i := 0
  let neg := at' t 0 == 45
  if neg || at' t 0 == 43 then i := 1
  let mut ip : Nat := 0
  let mut fp : Nat := 0
  let mut fd : Nat := 0
  let mut digits := 0
  for _ in [0:t.size] do
    if i < t.size && isDigit (at' t i) then
      ip := ip * 10 + (at' t i).toNat - 48
      digits := digits + 1
      i := i + 1
  if i < t.size && at' t i == 46 then
    i := i + 1
    for _ in [0:t.size] do
      if i < t.size && isDigit (at' t i) then
        if fd < 6 then
          fp := fp * 10 + (at' t i).toNat - 48
          fd := fd + 1
        digits := digits + 1
        i := i + 1
  if digits == 0 then return none
  let scale := 10 ^ fd
  let mag : Int := ((ip * scale + fp) * 256 * 2 + scale) / (2 * scale)
  return some (if neg then -mag else mag, toStr (t.extract i t.size))

/-- `font-size` against the parent's size, `none` when not understood. -/
def fontSize (v : ByteArray) (parent : Int) (svgAttr : Bool) : Option Int :=
  let t := lower (trim v)
  let kw := [("xx-small", 9), ("x-small", 10), ("small", 13), ("medium", 16),
             ("large", 18), ("x-large", 24), ("xx-large", 32)]
  match kw.find? (fun (k, _) => eqAscii t k) with
  | some (_, px) => some (px * 256)
  | none =>
    (parseNum t).bind fun (n, u) =>
      if u == "px" || (u == "" && (svgAttr || n == 0)) then some n
      else if u == "pt" then some (n * 4 / 3)
      else if u == "em" then some (n * parent / 256)
      else if u == "rem" then some (n * 16)
      else if u == "%" then some (n * parent / 25600)
      else none

def fontWeight (v : ByteArray) (parent : Nat) : Option Nat :=
  let t := lower (trim v)
  if eqAscii t "normal" then some 400
  else if eqAscii t "bold" then some 700
  else if eqAscii t "bolder" then some (if parent < 350 then 400 else if parent < 550 then 700 else 900)
  else if eqAscii t "lighter" then some (if parent < 550 then 100 else if parent < 750 then 400 else 700)
  else match parseNum t with
    | some (n, "") => if n > 0 && n ≤ 1000 * 256 then some (n.toNat / 256) else none
    | _ => none

/-- The winning declaration of `n`: `!important` CSS, `style=""`, normal CSS,
then (SVG elements only) the presentation attribute, then `ua`. -/
def winning (imp styleD normal : Array (String × ByteArray)) (attrs : Array Xml.Attr)
    (svg : Bool) (ua : Option ByteArray) (n : String) : Option ByteArray :=
  let last := fun (ds : Array (String × ByteArray)) =>
    (ds.filter (fun d => d.1 == n)).back?.map (·.2)
  (last imp).orElse fun _ => (last styleD).orElse fun _ => (last normal).orElse fun _ =>
    (if svg then (attrs.find? (·.name == n)).map (·.value) else none).orElse fun _ => ua

/-- Cascade one element: `parent`'s inherited values overridden by whatever
the element itself declares.  Returns the style and whether the element is
`display: none`. -/
def cascade (rules : Array Css.Rule) (chain : Array Css.ElemInfo) (parent : HStyle)
    (local_ : String) (attrs : Array Xml.Attr) (svg : Bool) : HStyle × Bool × Option ByteArray :=
  let (normal, imp) := Css.matchingDeclsSplit rules chain
  let styleD := match attrs.find? (·.name == "style") with
    | some a => ((Css.parseDeclarations a.value 0 a.value.size).1).map (fun d => (d.name, d.value))
    | none => #[]
  let ua := fun (n : String) =>
    if !svg && n == "font-weight" && (local_ == "b" || local_ == "strong") then some "bold".toUTF8
    else if !svg && n == "font-style" && (local_ == "i" || local_ == "em") then some "italic".toUTF8
    else none
  let w := fun (n : String) => winning imp styleD normal attrs svg (ua n) n
  let keep := fun (v : ByteArray) => let t := lower (trim v)
    eqAscii t "inherit" || eqAscii t "currentcolor" || eqAscii t "initial" || eqAscii t "unset"
  let st := parent
  let st := match w "color" with
    | some v => if keep v then st else { st with color := trim v }
    | none => st
  let st := match (w "font-size").bind (fontSize · parent.size svg) with
    | some s => if s > 0 then { st with size := s } else st
    | none => st
  let st := match (w "font-weight").bind (fontWeight · parent.weight) with
    | some x => { st with weight := x }
    | none => st
  let st := match w "font-style" with
    | some v => let t := lower (trim v)
      if eqAscii t "italic" || startsWith t 0 "oblique" then { st with italic := true }
      else if eqAscii t "normal" then { st with italic := false } else st
    | none => st
  let st := match w "font-family" with
    | some v => if keep v then st else { st with family := trim v }
    | none => st
  let st := match w "text-align" with
    | some v => let t := lower (trim v)
      if eqAscii t "center" || eqAscii t "-webkit-center" then { st with align := 1 }
      else if eqAscii t "right" || eqAscii t "end" then { st with align := 2 }
      else if eqAscii t "left" || eqAscii t "start" || eqAscii t "justify" then { st with align := 0 }
      else st
    | none => st
  let st := match w "line-height" with
    | some v =>
      if eqAscii (lower (trim v)) "normal" then { st with lineHeight := none }
      else match parseNum v with
        | some (n, "") => if n > 0 then { st with lineHeight := some (true, n) } else st
        | some (n, "px") => if n > 0 then { st with lineHeight := some (false, n) } else st
        | some (n, "em") => if n > 0 then { st with lineHeight := some (false, n * st.size / 256) } else st
        | some (n, "%") => if n > 0 then { st with lineHeight := some (false, n * st.size / 25600) } else st
        | _ => st
    | none => st
  let st := match w "white-space" with
    | some v => let t := lower (trim v)
      { st with wrap := !(eqAscii t "nowrap" || eqAscii t "pre") }
    | none => st
  let hidden := match w "display" with
    | some v => eqAscii (lower (trim v)) "none"
    | none => false
  -- not inherited; only used on blocks (`div`/`p`)
  let bg := (w "background-color").bind fun v =>
    let t := lower (trim v)
    if eqAscii t "transparent" || keep v || eqAscii t "none" then none else some (trim v)
  (st, hidden, bg)

/-- The embedded face that draws this style (Noto Sans by weight/slant). -/
def faceOf (st : HStyle) : Except String Font :=
  let k := Text.baseFont 0 (Text.pickFace st.weight st.italic)
  match (FontSet.entries[k]?).bind (fun e => e.font ()) with
  | some f => if f.unitsPerEm == 0 then throw "foreignObject: embedded font has no units per em"
              else pure f
  | none => throw "foreignObject: embedded font missing"

/-- Advance width of `t` in `Fx`, no kerning. -/
def measure (t : ByteArray) (st : HStyle) : Except String Int := do
  let f ← faceOf st
  let mut units : Nat := 0
  for cp in Text.decodeUtf8 t do
    units := units + f.advance (f.glyphId cp)
  return (units : Int) * st.size / f.unitsPerEm

def isWs (c : UInt8) : Bool := c == 32 || c == 9 || c == 10 || c == 13

/-- Split a text run into words and single spaces. -/
def tokens (t : ByteArray) : Array (Option ByteArray) := Id.run do
  let mut out : Array (Option ByteArray) := #[]
  let mut start := 0
  let mut inWord := false
  for i in [0:t.size] do
    let ws := isWs (at' t i)
    if ws && inWord then
      out := out.push (some (t.extract start i))
      inWord := false
    if ws then
      if out.back? != some none then out := out.push none
    else if !inWord then
      start := i
      inWord := true
  if inWord then out := out.push (some (t.extract start t.size))
  return out

/-- One line box: its pieces (text, style) and the style it was started in. -/
structure Line where
  pieces : Array (ByteArray × HStyle) := #[]
  st : HStyle := {}
deriving Inhabited

/-- Greedy line breaking of the collected items at box width `boxW`.  Also
returns each block background as (colour, first line, end line), in the order
the blocks opened. -/
def breakLines (items : Array Item) (boxW : Int) :
    Except String (Array Line × Array (ByteArray × Nat × Nat)) := do
  let mut lines : Array Line := #[]
  let mut bgs : Array (ByteArray × Nat × Nat) := #[]
  let mut bgOpen : Array Nat := #[]
  let mut cur : Line := {}
  let mut curW : Int := 0
  let mut space : Option HStyle := none
  for it in items do
    match it with
    | .block =>
      if !cur.pieces.isEmpty then
        lines := lines.push cur
        cur := {}
        curW := 0
      space := none
    | .bgStart c =>
      bgOpen := bgOpen.push bgs.size
      bgs := bgs.push (c, lines.size, lines.size)
    | .bgEnd =>
      match bgOpen.back? with
      | some k =>
        bgOpen := bgOpen.pop
        bgs := bgs.modify k fun (c, a, _) => (c, a, lines.size)
      | none => pure ()
    | .br st =>
      lines := lines.push (if cur.pieces.isEmpty then { cur with st := st } else cur)
      cur := {}
      curW := 0
      space := none
    | .text t st =>
      for tok in tokens t do
        match tok with
        | none => if !cur.pieces.isEmpty then space := some st
        | some word =>
          let ww ← measure word st
          let sw ← match space with
            | some s => measure " ".toUTF8 s
            | none => pure 0
          if !cur.pieces.isEmpty && st.wrap && boxW > 0 && curW + sw + ww > boxW then
            lines := lines.push cur
            cur := {}
            curW := 0
            space := none
          if cur.pieces.isEmpty then cur := { cur with st := st }
          match space with
          | some s =>
            cur := { cur with pieces := cur.pieces.push (" ".toUTF8, s) }
            curW := curW + sw
          | none => pure ()
          space := none
          -- merge with the previous piece when the style is the same
          cur := match cur.pieces.back? with
            | some (pt, ps) =>
              if ps == st then { cur with pieces := cur.pieces.pop.push (pt ++ word, ps) }
              else { cur with pieces := cur.pieces.push (word, st) }
            | none => { cur with pieces := cur.pieces.push (word, st) }
          curW := curW + ww
  if !cur.pieces.isEmpty then lines := lines.push cur
  -- a space piece merged into its neighbour only when styles agree; fold
  -- the leftovers too so a line is as few `tspan`s as possible
  let merged := lines.map fun l =>
    { l with pieces := l.pieces.foldl (fun acc (t, s) => match acc.back? with
        | some (pt, ps) => if ps == s then acc.pop.push (pt ++ t, ps) else acc.push (t, s)
        | none => acc.push (t, s)) #[] }
  return (merged, bgs)

def props (st : HStyle) : String :=
  s!"fill:{toStr st.color};font-size:{Use.fmtFixed st.size 8}px;font-weight:{st.weight};" ++
  s!"font-style:{if st.italic then "italic" else "normal"};" ++
  (if st.family.isEmpty then "" else s!"font-family:{toStr st.family};")

/-- The events standing in for one `foreignObject`. -/
def emit (foAttrs : Array Xml.Attr) (items : Array Item) : Except String (Array Xml.Event) := do
  let num := fun (n : String) => match foAttrs.find? (·.name == n) with
    | some a => match parseNum a.value with
      | some (v, u) => if u == "" || u == "px" then v else 0
      | none => 0
    | none => 0
  let x := num "x"
  let y := num "y"
  let w := num "width"
  let h := num "height"
  if w ≤ 0 || h ≤ 0 then return #[]
  let (lines, bgs) ← breakLines items w
  if lines.all (·.pieces.isEmpty) then return #[]
  let tr := match foAttrs.find? (·.name == "transform") with
    | some a => toStr a.value ++ " "
    | none => ""
  let keepAttr := fun (a : Xml.Attr) =>
    !(a.name == "x" || a.name == "y" || a.name == "width" || a.name == "height" ||
      a.name == "transform" || a.name == "id")
  let gAttrs := (foAttrs.filter keepAttr).push
    (Use.mkAttr "transform" s!"{tr}translate({Use.fmtFixed x 8} {Use.fmtFixed y 8})")
  let mut out : Array Xml.Event := #[.open_ "g" gAttrs]
  -- line box tops and baselines first, so block backgrounds go underneath
  let mut tops : Array Int := #[0]
  let mut bases : Array Int := #[]
  for l in lines do
    let st := match l.pieces[0]? with
      | some (_, s) => s
      | none => l.st
    let f ← faceOf st
    let upem : Int := f.unitsPerEm
    let asc := f.ascent * st.size / upem
    let desc := -f.descent * st.size / upem
    let lh := match st.lineHeight with
      | some (true, k) => k * st.size / 256
      | some (false, px) => px
      | none => (f.ascent - f.descent + f.lineGap) * st.size / upem
    let top := tops.back?.getD 0
    bases := bases.push (top + Int.ediv (lh - (asc + desc)) 2 + asc)
    tops := tops.push (top + lh)
  for (c, a, e) in bgs do
    let y0 := tops.getD a 0
    let y1 := tops.getD e 0
    if y1 > y0 then
      out := (out.push (.open_ "rect" #[Use.mkAttr "width" (Use.fmtFixed w 8),
        Use.mkAttr "y" (Use.fmtFixed y0 8), Use.mkAttr "height" (Use.fmtFixed (y1 - y0) 8),
        Use.mkAttr "style" s!"fill:{toStr c};fill-opacity:1;stroke:none;opacity:1"])).push .close
  for i in [0:lines.size] do
    let l := lines.getD i default
    let st := match l.pieces[0]? with
      | some (_, s) => s
      | none => l.st
    let base := bases.getD i 0
    if l.pieces.isEmpty then continue
    let (ax, anchor) := if st.align == 1 then (Int.ediv w 2, "middle")
      else if st.align == 2 then (w, "end") else (0, "start")
    out := out.push (.open_ "text" #[Use.mkAttr "x" (Use.fmtFixed ax 8),
      Use.mkAttr "y" (Use.fmtFixed base 8),
      Use.mkAttr "style" (props st ++ s!"text-anchor:{anchor};stroke:none;fill-opacity:1;" ++
        "letter-spacing:normal;word-spacing:normal;text-decoration:none;" ++
        "writing-mode:horizontal-tb;dominant-baseline:auto;font-variant:normal")])
    for (t, s) in l.pieces do
      out := (out.push (.open_ "tspan" #[Use.mkAttr "style" (props s)])).push (.text t) |>.push .close
    out := out.push .close
  return out.push .close

def isHtml (nm : String) : Bool := nm.startsWith "html:"

def supported : List String := ["div", "p", "span", "b", "strong", "i", "em", "br"]

/-- Rewrite every `foreignObject` holding XHTML (see the module doc).  A
document without any is returned unchanged, without a cascade pass. -/
def rewrite (rules : Array Css.Rule) (events : Array Xml.Event) : Except String (Array Xml.Event) := do
  if !events.any (fun e => match e with | .open_ nm _ => isHtml nm | _ => false) then
    return events
  let mut out : Array Xml.Event := Array.emptyWithCapacity events.size
  let mut names : Array String := #[]
  let mut styles : Array HStyle := #[]
  let mut chain : Array Css.ElemInfo := #[]
  let mut cc : Array Nat := #[0]
  -- inside a rewritten `foreignObject`: its depth (in `names`) and attrs
  let mut foDepth : Nat := 0
  let mut foAttrs : Array Xml.Attr := #[]
  let mut items : Array Item := #[]
  let mut skip : Nat := 0
  -- per open element: did it push a `bgStart`
  let mut bgPushed : Array Bool := #[]
  for ev in events do
    match ev with
    | .open_ nm attrs =>
      let isFirst := cc.back?.getD 0 == 0
      cc := match cc.back? with
        | some c => cc.pop.push (c + 1)
        | none => cc
      let local_ := if isHtml nm then (nm.drop 5).toString else nm
      let info := Css.buildElemInfo local_ (attrs.map (fun a => (a.name, toStr a.value))) isFirst
      chain := chain.push info
      cc := cc.push 0
      let parent := styles.back?.getD {}
      let parentName := names.back?.getD ""
      names := names.push nm
      let block := local_ == "div" || local_ == "p"
      if foDepth > 0 then
        if skip > 0 then
          skip := skip + 1
          styles := styles.push parent
          bgPushed := bgPushed.push false
        else if isHtml nm && supported.contains local_ then
          let (st, hidden, bg) := cascade rules chain parent local_ attrs false
          styles := styles.push st
          let bg := if hidden || !block then none else bg
          bgPushed := bgPushed.push bg.isSome
          if hidden then skip := 1
          else if local_ == "br" then items := items.push (.br st)
          else if block then
            items := items.push .block
            match bg with
            | some c => items := items.push (.bgStart c)
            | none => pure ()
        else
          bgPushed := bgPushed.push false
          styles := styles.push parent
          skip := 1
      else
        let (st, _, _) := cascade rules chain parent nm attrs (!isHtml nm)
        styles := styles.push st
        bgPushed := bgPushed.push false
        if nm == "foreignObject" && parentName != "switch" then
          foDepth := names.size
          foAttrs := attrs
          items := #[]
        else out := out.push ev
    | .close =>
      let nm := names.back?.getD ""
      let depth := names.size
      let hadBg := bgPushed.back?.getD false
      bgPushed := bgPushed.pop
      names := names.pop
      styles := styles.pop
      chain := chain.pop
      cc := cc.pop
      if foDepth > 0 then
        if depth == foDepth then
          out := out ++ (← emit foAttrs items)
          foDepth := 0
          skip := 0
        else if skip > 0 then skip := skip - 1
        else if nm == "html:div" || nm == "html:p" then
          items := items.push .block
          if hadBg then items := items.push .bgEnd
      else out := out.push .close
    | .text t =>
      if foDepth > 0 then
        if skip == 0 && names.size > foDepth then
          items := items.push (.text t (styles.back?.getD {}))
      else out := out.push ev
  let elems := out.foldl (fun n e => match e with | .open_ .. => n + 1 | _ => n) 0
  if elems > Xml.maxElements then
    throw s!"foreignObject: more than {Xml.maxElements} elements after rewriting"
  return out

end ForeignObject
end LeanSvg
