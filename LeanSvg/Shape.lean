import LeanSvg.Font
import LeanSvg.ShapeData

/-!
# OpenType layout: GSUB and GPOS (T93)

A pure, total port of the parts of harfrust 0.12.0 (the HarfBuzz port resvg
0.48.1 shapes with) that complex scripts need: the feature map with its
stages and pauses, the skipping iterator, every GSUB lookup type (single,
multiple, alternate, ligature, context, chained context, extension, reverse
chained) and every GPOS lookup type (single, pair, cursive, mark-to-base,
mark-to-ligature, mark-to-mark, context, chained context, extension), plus
GDEF glyph classes, mark attachment classes and mark filtering sets.  The
shapers that drive it (default, Arabic, Hebrew, Indic) are in
`LeanSvg/ShapeRun.lean`.

The buffer model is HarfBuzz's: GSUB reads `info` from `idx` and writes the
result to `out` (`haveOutput`), then swaps; GPOS works in place on `pos`.
Everything is read straight from the font's bytes with the bounds-checked
`Font.u16`/`u32` (reads past the end give `0`), so a corrupt table can only
produce wrong glyphs, never a crash.

Bounds (all fixed, all documented where they bite):
* nested lookups (a context lookup calling another) go at most
  `maxNesting` deep (fuel, structural recursion);
* the glyph sequence may grow to at most `16 * n + 256` glyphs for an
  `n`-character run (`maxLenFor`); a lookup that would exceed it stops the
  run's shaping there (harfrust sets `successful = false` the same way);
* every lookup pass over the buffer is a `for` loop over a fixed range, and
  the whole shaping call has an operation budget (`opsFor`) that each
  subtable application and cluster merge spends, as harfrust's `max_ops`;
* context matching looks at most `maxContext` glyphs ahead or behind.

Not implemented (not needed by the embedded fonts, documented in
`tasks/T93-shaping-bidi.md`): `FeatureVariations`, device/variation deltas in
value records and anchors, anchor format 2 contour points, the `rand`
feature, AAT tables.
-/

namespace LeanSvg
namespace Shape

open LeanSvg.Font (u8 u16 u32 i16)

/-! ## Limits -/

/-- harfrust's `MAX_NESTING_LEVEL` is 64; no real font nests more than a few
levels (the embedded ones: 2). -/
def maxNesting : Nat := 16

/-- harfrust's `MAX_CONTEXT_LENGTH`. -/
def maxContext : Nat := 64

/-- The most glyphs a run of `n` characters may grow to. -/
def maxLenFor (n : Nat) : Nat := 16 * n + 256

/-- The operation budget of one shaping call over `n` characters. -/
def opsFor (n : Nat) : Nat := 4096 * n + 65536

/-! ## Glyph records -/

/-- One glyph of the buffer: harfrust's `GlyphInfo` with its shaper variables
as named fields. -/
structure GInfo where
  /-- The Unicode codepoint (after mirroring/normalisation). -/
  cp : Nat := 0
  /-- The glyph id (valid once characters are mapped). -/
  gid : Nat := 0
  /-- The character index (in the run) this glyph belongs to. -/
  cluster : Nat := 0
  mask : Nat := 0
  /-- General category (`ShapeData.genCat` numbering), which a ligature can
  change. -/
  gc : Nat := 0
  /-- Modified combining class. -/
  ccc : Nat := 0
  /-- Unicode flags: `0x20` default-ignorable, `0x40` hidden, `0x80`
  grapheme continuation, `0x100` ZWJ, `0x200` ZWNJ. -/
  uflags : Nat := 0
  /-- Glyph props: `2` base, `4` ligature, `8` mark, `0x10` substituted,
  `0x20` ligated, `0x40` multiplied, bits 8.. the mark attachment class. -/
  gprops : Nat := 0
  /-- Ligature props: `lig_id << 5 | 0x10 (is ligature base) | component`. -/
  lig : Nat := 0
  syl : Nat := 0
  /-- Shaper category: the Indic category, or the Arabic shaping action. -/
  cat : Nat := 0
  /-- Indic position. -/
  ipos : Nat := 0
  /-- The glyph the normaliser chose for `cp` (harfrust's
  `normalizer_glyph_index`). -/
  ngid : Nat := 0
deriving Inhabited, Repr

/-- A glyph's position, in font units. -/
structure GPos where
  xAdv : Int := 0
  yAdv : Int := 0
  xOff : Int := 0
  yOff : Int := 0
  /-- Relative index of the glyph this one is attached to (0: none). -/
  chain : Int := 0
  /-- `1` mark attachment, `2` cursive. -/
  atype : Nat := 0
deriving Inhabited, Repr

namespace GInfo
def isIgnorable (g : GInfo) : Bool := g.uflags &&& 0x20 != 0 && g.gprops &&& 0x10 == 0
def isHidden (g : GInfo) : Bool := g.uflags &&& 0x40 != 0
def isContinuation (g : GInfo) : Bool := g.uflags &&& 0x80 != 0
def isZwj (g : GInfo) : Bool := g.gc == 1 && g.uflags &&& 0x100 != 0
def isZwnj (g : GInfo) : Bool := g.gc == 1 && g.uflags &&& 0x200 != 0
def isUnicodeMark (g : GInfo) : Bool := g.gc == 10 || g.gc == 11 || g.gc == 12
def ligId (g : GInfo) : Nat := g.lig >>> 5
def ligatedInternal (g : GInfo) : Bool := g.lig &&& 0x10 != 0
def ligComp (g : GInfo) : Nat := if g.ligatedInternal then 0 else g.lig &&& 0x0F
def ligNumComps (g : GInfo) : Nat :=
  if g.gprops &&& 4 != 0 && g.ligatedInternal then g.lig &&& 0x0F else 1
def isBase (g : GInfo) : Bool := g.gprops &&& 2 != 0
def isLigature (g : GInfo) : Bool := g.gprops &&& 4 != 0
def isMark (g : GInfo) : Bool := g.gprops &&& 8 != 0
def substituted (g : GInfo) : Bool := g.gprops &&& 0x10 != 0
def ligated (g : GInfo) : Bool := g.gprops &&& 0x20 != 0
def multiplied (g : GInfo) : Bool := g.gprops &&& 0x40 != 0
def ligatedAndDidntMultiply (g : GInfo) : Bool := g.ligated && !g.multiplied
def setLigForLigature (g : GInfo) (id n : Nat) : GInfo :=
  { g with lig := (id % 8) <<< 5 ||| 0x10 ||| (n &&& 0x0F) }
def setLigForMark (g : GInfo) (id comp : Nat) : GInfo :=
  { g with lig := (id % 8) <<< 5 ||| (comp &&& 0x0F) }
end GInfo

/-- harfrust's `is_default_ignorable` (Default_Ignorable_Code_Point minus
the Hangul fillers and U+1BCA0..1BCA3, which fonts draw). -/
def isDefaultIgnorable (ch : Nat) : Bool :=
  ch == 0x00AD || ch == 0x034F || ch == 0x061C || (0x17B4 ≤ ch && ch ≤ 0x17B5) ||
  (0x180B ≤ ch && ch ≤ 0x180E) || (0x200B ≤ ch && ch ≤ 0x200F) || (0x202A ≤ ch && ch ≤ 0x202E) ||
  (0x2060 ≤ ch && ch ≤ 0x206F) || (0xFE00 ≤ ch && ch ≤ 0xFE0F) || ch == 0xFEFF ||
  (0xFFF0 ≤ ch && ch ≤ 0xFFF8) || (0x1D173 ≤ ch && ch ≤ 0x1D17A) || (0xE0000 ≤ ch && ch ≤ 0xE0FFF)

/-- harfrust's `init_unicode_props` for a fresh character:
`(general category, modified combining class, flags)`. -/
def unicodeProps (cp : Nat) : Nat × Nat × Nat := Id.run do
  let gc := ShapeData.genCat cp
  let ign := cp ≥ 0x80 && isDefaultIgnorable cp
  let mut f := if ign then 0x20 else 0
  f := if ign && cp == 0x200C then f ||| 0x200 else f
  f := if ign && cp == 0x200D then f ||| 0x100 else f
  f := if ign && ((0x180B ≤ cp && cp ≤ 0x180D) || cp == 0x180F || (0xE0020 ≤ cp && cp ≤ 0xE007F)
      || cp == 0x034F) then f ||| 0x40 else f
  let isMarkGc := gc == 10 || gc == 11 || gc == 12
  f := if cp ≥ 0x80 && isMarkGc then f ||| 0x80 else f
  let ccc := if isMarkGc then ShapeData.modCcc cp else 0
  (gc, ccc, f)

/-! ## The font's layout tables -/

/-- Absolute offsets of what the engine reads, `0` for absent. -/
structure Layout where
  bs : ByteArray
  gsub : Nat := 0
  gpos : Nat := 0
  classDef : Nat := 0
  markAttach : Nat := 0
  markSets : Nat := 0
deriving Inhabited

/-- The `(offset, length)` of table `tag` in the font's directory. -/
def findTable (bs : ByteArray) (tag : Nat) : Option (Nat × Nat) := Id.run do
  let n := u16 bs 4
  for i in [0:n] do
    let d := 12 + 16 * i
    if d + 16 ≤ bs.size && u32 bs d == tag then
      let off := u32 bs (d + 8)
      if off < bs.size then return some (off, u32 bs (d + 12))
  return none

def tagGSUB : Nat := 0x47535542
def tagGPOS : Nat := 0x47504F53
def tagGDEF : Nat := 0x47444546

/-- Locate GSUB, GPOS and GDEF.  A GSUB/GPOS whose major version is not 1 is
treated as absent. -/
def Layout.ofBytes (bs : ByteArray) : Layout := Id.run do
  let mut l : Layout := { bs := bs }
  match findTable bs tagGSUB with
  | some (o, len) => if len ≥ 10 && u16 bs o == 1 then l := { l with gsub := o }
  | none => pure ()
  match findTable bs tagGPOS with
  | some (o, len) => if len ≥ 10 && u16 bs o == 1 then l := { l with gpos := o }
  | none => pure ()
  match findTable bs tagGDEF with
  | some (o, len) =>
    if len ≥ 12 && u16 bs o == 1 then
      let rel := fun (k : Nat) => let v := u16 bs (o + k); if v == 0 then 0 else o + v
      l := { l with classDef := rel 4, markAttach := rel 10 }
      if u16 bs (o + 2) ≥ 2 && len ≥ 14 then l := { l with markSets := rel 12 }
  | none => pure ()
  return l

namespace Layout

def hasClasses (l : Layout) : Bool := l.classDef != 0

/-- harfrust's `glyph_props`: GDEF class 1 base, 2 ligature, 3 mark (with its
mark attachment class in bits 8..). -/
def glyphProps (l : Layout) (gid : Nat) : Nat :=
  match Font.classOf l.bs l.classDef gid with
  | 1 => 2
  | 2 => 4
  | 3 => (Font.classOf l.bs l.markAttach gid % 256) <<< 8 ||| 8
  | _ => 0

/-- Whether `gid` is in GDEF mark glyph set `set`. -/
def isMarkGlyph (l : Layout) (gid set : Nat) : Bool :=
  let ms := l.markSets
  if ms == 0 || u16 l.bs ms != 1 || set ≥ u16 l.bs (ms + 2) then false
  else (Font.coverageIndex l.bs (ms + u32 l.bs (ms + 4 + 4 * set)) gid).isSome

/-- The table's base offset, `0` if absent. -/
def base (l : Layout) (gpos : Bool) : Nat := if gpos then l.gpos else l.gsub

def lookupCount (l : Layout) (gpos : Bool) : Nat :=
  let t := l.base gpos
  if t == 0 then 0 else u16 l.bs (t + u16 l.bs (t + 8))

/-- Absolute offset of lookup `li`. -/
def lookupOff (l : Layout) (gpos : Bool) (li : Nat) : Nat :=
  let t := l.base gpos
  let ll := t + u16 l.bs (t + 8)
  ll + u16 l.bs (ll + 2 + 2 * li)

/-- The script table for the first of `tags` the table lists, else `DFLT`,
`dflt`, `latn` (read-fonts' `ScriptList::select`): `(script offset, tag)`. -/
def selectScript (l : Layout) (gpos : Bool) (tags : Array Nat) : Option (Nat × Nat) := Id.run do
  let t := l.base gpos
  if t == 0 then return none
  let sl := t + u16 l.bs (t + 4)
  let n := u16 l.bs sl
  for tag in tags ++ #[0x44464C54, 0x64666C74, 0x6C61746E] do
    for i in [0:n] do
      if u32 l.bs (sl + 2 + 6 * i) == tag then return some (sl + u16 l.bs (sl + 6 + 6 * i), tag)
  return none

/-- The script's default LangSys (usvg never sets a language). -/
def defaultLangSys (l : Layout) (script : Nat) : Option Nat :=
  let o := u16 l.bs script
  if o == 0 then none else some (script + o)

def featureListOff (l : Layout) (gpos : Bool) : Nat :=
  let t := l.base gpos
  t + u16 l.bs (t + 6)

/-- The first feature index the LangSys lists whose tag is `tag`. -/
def findFeature (l : Layout) (gpos : Bool) (ls tag : Nat) : Option Nat := Id.run do
  let fl := l.featureListOff gpos
  let fc := u16 l.bs fl
  for k in [0:u16 l.bs (ls + 4)] do
    let fi := u16 l.bs (ls + 6 + 2 * k)
    if fi < fc && u32 l.bs (fl + 2 + 6 * fi) == tag then return some fi
  return none

def featureTag (l : Layout) (gpos : Bool) (fi : Nat) : Nat :=
  u32 l.bs (l.featureListOff gpos + 2 + 6 * fi)

/-- The lookup indices of feature `fi` (those below the lookup count). -/
def featureLookups (l : Layout) (gpos : Bool) (fi : Nat) : Array Nat := Id.run do
  let fl := l.featureListOff gpos
  let f := fl + u16 l.bs (fl + 2 + 6 * fi + 4)
  let lc := l.lookupCount gpos
  let mut out := #[]
  for k in [0:u16 l.bs (f + 2)] do
    let li := u16 l.bs (f + 4 + 2 * k)
    if li < lc then out := out.push li
  return out

end Layout

/-! ## The feature map (harfrust `hb_ot_map_builder_t`) -/

def fGlobal : Nat := 0x01
def fHasFallback : Nat := 0x02
def fManualZwnj : Nat := 0x04
def fManualZwj : Nat := 0x08
def fManualJoiners : Nat := 0x0C
def fPerSyllable : Nat := 0x40

/-- The glyph-mask bit every global feature shares. -/
def globalBit : Nat := 1

/-- The work a shaper does between two GSUB stages. -/
inductive Pause where
  | none
  | indicSetupSyllables
  | indicInitial
  | indicFinal
  | clearSyllables
deriving BEq, Inhabited, Repr

structure FeatureInfo where
  tag : Nat
  seq : Nat
  maxValue : Nat
  flags : Nat
  stageSub : Nat
  stagePos : Nat
deriving Inhabited

/-- Features and pauses as a shaper declares them. -/
structure Builder where
  feats : Array FeatureInfo := #[]
  pauses : Array Pause := #[]
  stageSub : Nat := 0
deriving Inhabited

namespace Builder
def add (b : Builder) (tag flags : Nat) (value : Nat := 1) : Builder :=
  { b with feats := b.feats.push ⟨tag, b.feats.size, value, flags, b.stageSub, 0⟩ }
def enable (b : Builder) (tag flags : Nat) (value : Nat := 1) : Builder := b.add tag (flags ||| fGlobal) value
def disable (b : Builder) (tag : Nat) : Builder := b.add tag fGlobal 0
def pause (b : Builder) (p : Pause) : Builder :=
  { b with pauses := b.pauses.push p, stageSub := b.stageSub + 1 }
end Builder

/-- A four-letter tag. -/
def tag (s : String) : Nat :=
  let b := s.toUTF8
  u32 b 0

/-- One lookup of a stage, with the mask of the features that asked for it. -/
structure LookupMap where
  index : Nat
  mask : Nat
  autoZwnj : Bool
  autoZwj : Bool
  perSyl : Bool
deriving Inhabited, Repr

/-- A compiled plan: GSUB stages (lookups, then the pause to run), GPOS
lookups, and each kept feature's one-bit mask. -/
structure Plan where
  gsub : Array (Array LookupMap × Pause) := #[]
  gpos : Array LookupMap := #[]
  /-- Each kept feature: `(tag, one-bit mask, GSUB stage)`. -/
  masks : Array (Nat × Nat × Nat) := #[]
  globalMask : Nat := globalBit
  /-- The chosen GSUB/GPOS script tags (`0` if none). -/
  gsubScript : Nat := 0
  gposScript : Nat := 0
deriving Inhabited

def Plan.mask1 (p : Plan) (t : Nat) : Nat := ((p.masks.find? (·.1 == t)).map (·.2.1)).getD 0

/-- Stable insertion sort by `(tag, seq)`: at most a few dozen features. -/
def sortFeats (fs : Array FeatureInfo) : Array FeatureInfo := Id.run do
  let mut a := fs
  for i in [1:a.size] do
    let x := a.getD i default
    let mut j := i
    for _ in [0:i] do
      let y := a.getD (j - 1) default
      if y.tag > x.tag || (y.tag == x.tag && y.seq > x.seq) then
        a := a.setIfInBounds j y
        j := j - 1
      else break
    a := a.setIfInBounds j x
  return a

/-- Insertion sort of lookup maps by index (stable). -/
def sortLookups (ls : Array LookupMap) : Array LookupMap := Id.run do
  let mut a := ls
  for i in [1:a.size] do
    let x := a.getD i default
    let mut j := i
    for _ in [0:i] do
      let y := a.getD (j - 1) default
      if y.index > x.index then
        a := a.setIfInBounds j y
        j := j - 1
      else break
    a := a.setIfInBounds j x
  return a

/-- harfrust's `hb_ot_map_builder_t::compile` for a font, the OpenType script
tags to try, and the declared features. -/
def compilePlan (l : Layout) (scriptTags : Array Nat) (b : Builder) : Plan := Id.run do
  -- dedup (`dedup_feature_infos`, after sorting by tag)
  let sorted := sortFeats b.feats
  let mut fs : Array FeatureInfo := #[]
  for f in sorted do
    match fs.back? with
    | some g =>
      if g.tag != f.tag then fs := fs.push f
      else
        let mut g := g
        if f.flags &&& fGlobal != 0 then
          g := { g with flags := g.flags ||| fGlobal, maxValue := f.maxValue }
        else
          g := { g with flags := if g.flags &&& fGlobal != 0 then g.flags ^^^ fGlobal else g.flags,
                        maxValue := Nat.max g.maxValue f.maxValue }
        g := { g with flags := g.flags ||| (f.flags &&& fHasFallback),
                      stageSub := Nat.min g.stageSub f.stageSub, stagePos := Nat.min g.stagePos f.stagePos }
        fs := fs.setIfInBounds (fs.size - 1) g
    | none => fs := fs.push f
  let subScript := l.selectScript false scriptTags
  let posScript := l.selectScript true scriptTags
  let subLs := subScript.bind (fun (s, _) => l.defaultLangSys s)
  let posLs := posScript.bind (fun (s, _) => l.defaultLangSys s)
  -- required features
  let reqOf := fun (ls : Option Nat) (gpos : Bool) => match ls with
    | some o => let r := u16 l.bs (o + 2); if r == 0xFFFF then none else some (r, l.featureTag gpos r)
    | none => none
  let reqSub := reqOf subLs false
  let reqPos := reqOf posLs true
  let mut reqStageSub := 0
  let mut reqStagePos := 0
  -- masks
  let mut nextBit := 2
  let mut kept : Array (FeatureInfo × Option Nat × Option Nat × Nat) := #[]
  let mut masks : Array (Nat × Nat × Nat) := #[]
  for f in fs do
    if f.maxValue == 0 then continue
    if (reqSub.map (·.2)) == some f.tag then reqStageSub := f.stageSub
    if (reqPos.map (·.2)) == some f.tag then reqStagePos := f.stagePos
    let fiSub := subLs.bind (fun ls => l.findFeature false ls f.tag)
    let fiPos := posLs.bind (fun ls => l.findFeature true ls f.tag)
    let found := fiSub.isSome || fiPos.isSome
    if !found && f.flags &&& fHasFallback == 0 then continue
    let mut mask := globalBit
    if !(f.flags &&& fGlobal != 0 && f.maxValue == 1) then
      mask := nextBit
      nextBit := nextBit * 2
    kept := kept.push (f, fiSub, fiPos, mask)
    masks := masks.push (f.tag, mask, f.stageSub)
  -- lookups, stage by stage (`collect_lookup_stages`)
  let mkLookups := fun (gpos : Bool) (stage : Nat) => Id.run do
    let mut ls : Array LookupMap := #[]
    let req := if gpos then reqPos else reqSub
    let reqStage := if gpos then reqStagePos else reqStageSub
    match req with
    | some (fi, _) =>
      if reqStage == stage then
        for li in l.featureLookups gpos fi do ls := ls.push ⟨li, globalBit, true, true, false⟩
    | none => pure ()
    for (f, fiSub, fiPos, mask) in kept do
      let st := if gpos then f.stagePos else f.stageSub
      if st != stage then continue
      match (if gpos then fiPos else fiSub) with
      | some fi =>
        for li in l.featureLookups gpos fi do
          ls := ls.push ⟨li, mask, f.flags &&& fManualZwnj == 0, f.flags &&& fManualZwj == 0,
                         f.flags &&& fPerSyllable != 0⟩
      | none => pure ()
    -- sort by index, merge duplicates
    let sorted := sortLookups ls
    let mut out : Array LookupMap := #[]
    for m in sorted do
      match out.back? with
      | some p =>
        if p.index == m.index then
          out := out.setIfInBounds (out.size - 1)
            { p with mask := p.mask ||| m.mask, autoZwnj := p.autoZwnj && m.autoZwnj,
                     autoZwj := p.autoZwj && m.autoZwj }
        else out := out.push m
      | none => out := out.push m
    return out
  let mut gsub : Array (Array LookupMap × Pause) := #[]
  for s in [0:b.pauses.size + 1] do
    gsub := gsub.push (mkLookups false s, b.pauses.getD s .none)
  return { gsub := gsub, gpos := mkLookups true 0, masks := masks, globalMask := globalBit,
           gsubScript := (subScript.map (·.2)).getD 0, gposScript := (posScript.map (·.2)).getD 0 }

/-! ## The buffer and the apply context -/

structure St where
  lay : Layout
  isGpos : Bool := false
  info : Array GInfo := #[]
  out : Array GInfo := #[]
  pos : Array GPos := #[]
  idx : Nat := 0
  haveOutput : Bool := false
  ok : Bool := true
  ops : Nat := 0
  maxLen : Nat := 0
  serial : Nat := 0
  lookupMask : Nat := 1
  lookupProps : Nat := 0
  autoZwj : Bool := true
  autoZwnj : Bool := true
  perSyl : Bool := false
  matchPos : Array Nat := #[]
  /-- Direction of the run: `true` for right-to-left (GPOS cursive and mark
  offsets depend on it). -/
  rtl : Bool := false
deriving Inhabited

abbrev M := StateM St

namespace St
def len (s : St) : Nat := s.info.size
def cur (s : St) (k : Nat := 0) : GInfo := s.info.getD (s.idx + k) default
/-- The glyphs before `idx`: the output if there is one, else `info`. -/
def backArr (s : St) : Array GInfo := if s.haveOutput then s.out else s.info
def backtrackLen (s : St) : Nat := if s.haveOutput then s.out.size else s.idx
def lookaheadLen (s : St) : Nat := s.len - s.idx
end St

def spend (n : Nat) : M Unit := modify fun s =>
  if s.ops < n then { s with ops := 0, ok := false } else { s with ops := s.ops - n }

def setCur (g : GInfo) : M Unit := modify fun s => { s with info := s.info.setIfInBounds s.idx g }

def nextGlyph : M Unit := modify fun s =>
  if s.haveOutput then
    if s.out.size ≥ s.maxLen then { s with ok := false }
    else { s with out := s.out.push (s.cur), idx := s.idx + 1 }
  else { s with idx := s.idx + 1 }

def nextGlyphs (n : Nat) : M Unit := do
  for _ in [0:n] do nextGlyph

def skipGlyph : M Unit := modify fun s => { s with idx := s.idx + 1 }

/-- Replace the current glyph by `g` (to the output) and advance. -/
def bufReplace (g : Nat) : M Unit := modify fun s =>
  if s.out.size ≥ s.maxLen then { s with ok := false }
  else { s with out := s.out.push { s.cur with gid := g }, idx := s.idx + 1 }

/-- Output a copy of the current glyph as `g` without advancing. -/
def bufOutput (g : Nat) : M Unit := modify fun s =>
  if s.out.size ≥ s.maxLen then { s with ok := false }
  else if s.idx < s.len then { s with out := s.out.push { s.cur with gid := g } }
  else match s.out.back? with
    | some b => { s with out := s.out.push { b with gid := g } }
    | none => s

/-- `merge_clusters(start, end)` over `info`. -/
def mergeClusters (start stop : Nat) : M Unit := do
  if stop < start + 2 then return
  spend (stop - start)
  modify fun s => Id.run do
    let mut info := s.info
    let mut out := s.out
    let mut cl := (info.getD start default).cluster
    for i in [start:stop] do cl := Nat.min cl (info.getD i default).cluster
    let mut e := stop
    if cl != (info.getD (e - 1) default).cluster then
      for _ in [0:info.size] do
        if e < info.size && (info.getD (e - 1) default).cluster == (info.getD e default).cluster then e := e + 1
        else break
    let mut b := start
    if cl != (info.getD b default).cluster then
      for _ in [0:info.size] do
        if s.idx < b && (info.getD (b - 1) default).cluster == (info.getD b default).cluster then b := b - 1
        else break
    if s.idx == b && (info.getD b default).cluster != cl then
      let old := (info.getD b default).cluster
      let mut i := out.size
      for _ in [0:out.size] do
        if i != 0 && (out.getD (i - 1) default).cluster == old then
          out := out.setIfInBounds (i - 1) { out.getD (i - 1) default with cluster := cl }
          i := i - 1
        else break
    for i in [b:e] do info := info.setIfInBounds i { info.getD i default with cluster := cl }
    return { s with info := info, out := out }

/-- `merge_out_clusters(start, end)` over `out`. -/
def mergeOutClusters (start stop : Nat) : M Unit := do
  if stop < start + 2 then return
  spend (stop - start)
  modify fun s => Id.run do
    let mut info := s.info
    let mut out := s.out
    let mut cl := (out.getD start default).cluster
    for i in [start:stop] do cl := Nat.min cl (out.getD i default).cluster
    let mut b := start
    for _ in [0:out.size] do
      if b != 0 && (out.getD (b - 1) default).cluster == (out.getD b default).cluster then b := b - 1
      else break
    let mut e := stop
    for _ in [0:out.size] do
      if e < out.size && (out.getD (e - 1) default).cluster == (out.getD e default).cluster then e := e + 1
      else break
    if e == out.size then
      let last := (out.getD (e - 1) default).cluster
      let mut i := s.idx
      for _ in [0:info.size] do
        if i < info.size && (info.getD i default).cluster == last then
          info := info.setIfInBounds i { info.getD i default with cluster := cl }
          i := i + 1
        else break
    for i in [b:e] do out := out.setIfInBounds i { out.getD i default with cluster := cl }
    return { s with info := info, out := out }

/-- `delete_glyph`: drop the current glyph, keeping its cluster alive. -/
def deleteGlyph : M Unit := do
  let s ← get
  let c := s.cur.cluster
  if (s.idx + 1 < s.len && c == (s.cur 1).cluster) ||
     (s.out.size != 0 && c == (s.out.getD (s.out.size - 1) default).cluster) then
    skipGlyph; return
  if s.out.size != 0 then
    let old := (s.out.getD (s.out.size - 1) default).cluster
    if c < old then
      modify fun s => Id.run do
        let mut out := s.out
        let mut i := out.size
        for _ in [0:out.size] do
          if i != 0 && (out.getD (i - 1) default).cluster == old then
            out := out.setIfInBounds (i - 1) { out.getD (i - 1) default with cluster := c }
            i := i - 1
          else break
        return { s with out := out }
    skipGlyph; return
  if s.idx + 1 < s.len then mergeClusters s.idx (s.idx + 2)
  skipGlyph

/-- `move_to(i)`: make the output exactly `i` glyphs long. -/
def moveTo (i : Nat) : M Bool := do
  let s ← get
  if !s.haveOutput then
    set { s with idx := Nat.min i s.len }; return true
  if !s.ok then return false
  if s.out.size < i then
    let count := i - s.out.size
    if s.idx + count > s.len || s.out.size + count > s.maxLen then
      set { s with ok := false }; return false
    set { s with out := s.out ++ s.info.extract s.idx (s.idx + count), idx := s.idx + count }
  else if s.out.size > i then
    let count := s.out.size - i
    let tail := s.out.extract i s.out.size
    let mut info := s.info
    let mut idx := s.idx
    if idx < count then
      info := (Array.replicate (count - idx) (default : GInfo)) ++ info
      idx := count
    idx := idx - count
    for k in [0:count] do info := info.setIfInBounds (idx + k) (tail.getD k default)
    set { s with info := info, idx := idx, out := s.out.extract 0 i }
  return true

/-- `sync`: the output becomes the buffer. -/
def sync : M Unit := modify fun s =>
  if !s.ok then { s with haveOutput := false, out := #[], idx := 0 }
  else
    let rest := s.info.extract s.idx s.info.size
    let out := if s.out.size + rest.size > s.maxLen then s.out else s.out ++ rest
    { s with info := out, out := #[], idx := 0, haveOutput := false,
             ok := s.out.size + rest.size ≤ s.maxLen }

def clearOutput : M Unit := modify fun s => { s with haveOutput := true, out := #[], idx := 0 }

def allocLigId : M Nat := do
  let s ← get
  let mut n := s.serial + 1
  if n % 8 == 0 then n := n + 1
  set { s with serial := n }
  return n % 8

/-! ## Glyph properties and the skipping iterator -/

/-- `check_glyph_property`: may a lookup with these props see this glyph? -/
def checkProp (l : Layout) (g : GInfo) (props : Nat) : Bool :=
  if g.gprops &&& props &&& 0x0E != 0 then false
  else if g.isMark then
    if props &&& 0x10 != 0 then l.isMarkGlyph g.gid (props >>> 16)
    else if props &&& 0xFF00 != 0 then (props &&& 0xFF00) == (g.gprops &&& 0xFF00)
    else true
  else true

inductive Skip where | no | yes | maybe
deriving BEq

inductive Match where | yes | no | skip
deriving BEq

/-- `may_skip`. -/
def maySkip (s : St) (contextMatch : Bool) (props : Nat) (g : GInfo) : Skip :=
  if !checkProp s.lay g props then .yes
  else
    let ignoreZwnj := s.isGpos || (contextMatch && s.autoZwnj)
    let ignoreZwj := contextMatch || s.autoZwj
    let ignoreHidden := s.isGpos
    if g.isIgnorable && (ignoreZwnj || !g.isZwnj) && (ignoreZwj || !g.isZwj) &&
        (ignoreHidden || !g.isHidden) then .maybe
    else .no

/-- `match_at`: the verdict on glyph `g` for a matcher whose predicate is
`f` (`none`: any glyph). -/
def matchAt (s : St) (contextMatch : Bool) (props syl : Nat) (f : Option (GInfo → Bool))
    (g : GInfo) : Match :=
  let sk := maySkip s contextMatch props g
  if sk == .yes then .skip
  else
    let mask := if contextMatch then g.mask else s.lookupMask
    let perSyl := !s.isGpos && s.perSyl
    let m : Skip :=   -- reused as a tri-state: no / yes / maybe
      if g.mask &&& mask == 0 || (perSyl && syl != 0 && syl != g.syl) then .no
      else match f with
        | some p => if p g then .yes else .no
        | none => .maybe
    if m == .yes || (m == .maybe && sk == .no) then .yes
    else if sk == .no then .no
    else .skip

/-- Forward iteration: the next glyph after `from` (in `info`) the matcher
accepts, testing the `k`-th accepted one with `f k`. -/
def iterNext (s : St) (contextMatch : Bool) (props syl : Nat) (f : Option (Nat → GInfo → Bool))
    (k fromIdx : Nat) : Option Nat := Id.run do
  let mut i := fromIdx
  for _ in [0:s.len] do
    if i + 1 ≥ s.len then return none
    i := i + 1
    match matchAt s contextMatch props syl (f.map (· k)) (s.info.getD i default) with
    | .yes => return some i
    | .no => return none
    | .skip => pure ()
  return none

/-- Backward iteration over the glyphs before the current one (`backArr`). -/
def iterPrev (s : St) (contextMatch : Bool) (props syl : Nat) (f : Option (Nat → GInfo → Bool))
    (k fromIdx : Nat) : Option Nat := Id.run do
  let arr := s.backArr
  let mut i := fromIdx
  for _ in [0:arr.size + 1] do
    if i == 0 then return none
    i := i - 1
    match matchAt s contextMatch props syl (f.map (· k)) (arr.getD i default) with
    | .yes => return some i
    | .no => return none
    | .skip => pure ()
  return none

/-- `match_input`: the current glyph plus `n` more, each tested by
`f k glyph`.  `some (end, positions, total components)` on success. -/
def matchInput (n : Nat) (f : Nat → GInfo → Bool) : M (Option (Nat × Array Nat × Nat)) := do
  let s ← get
  let first := s.cur
  if n == 0 then return some (s.idx + 1, #[s.idx], first.ligNumComps)
  if n + 1 > maxContext then return none
  let syl := first.syl
  let firstId := first.ligId
  let firstComp := first.ligComp
  let mut pos : Array Nat := #[s.idx]
  let mut i := s.idx
  let mut total := 0
  let mut ligbase : Nat := 0   -- 0 not checked, 1 may not skip, 2 may skip
  for k in [0:n] do
    match iterNext s false s.lookupProps syl (some f) k i with
    | none => return none
    | some j =>
      i := j
      pos := pos.push j
      let this := s.info.getD j default
      if firstId != 0 && firstComp != 0 then
        if firstId != this.ligId || firstComp != this.ligComp then
          if ligbase == 0 then
            -- find the ligature base of the first component in the output
            let out := s.out
            let mut jj := out.size
            let mut found := false
            for _ in [0:out.size] do
              if jj > 0 && (out.getD (jj - 1) default).ligId == firstId then
                if (out.getD (jj - 1) default).ligComp == 0 then
                  jj := jj - 1; found := true; break
                jj := jj - 1
              else break
            ligbase := if found && maySkip s false s.lookupProps (out.getD jj default) == .yes then 2 else 1
          if ligbase == 1 then return none
      else
        if this.ligId != 0 && this.ligComp != 0 && this.ligId != firstId then return none
      total := total + this.ligNumComps
  return some (i + 1, pos, total + first.ligNumComps)

/-- `match_backtrack`: `n` glyphs before the current one, nearest first. -/
def matchBacktrack (n : Nat) (f : Nat → GInfo → Bool) : M Bool := do
  let s ← get
  let syl := s.cur.syl
  let mut i := s.backtrackLen
  for k in [0:n] do
    match iterPrev s true s.lookupProps syl (some f) k i with
    | none => return false
    | some j => i := j
  return true

/-- `match_lookahead`: `n` glyphs from `start` on. -/
def matchLookahead (n : Nat) (f : Nat → GInfo → Bool) (start : Nat) : M Bool := do
  let s ← get
  let syl := s.cur.syl
  if n == 0 then return true
  let mut i := start - 1
  for k in [0:n] do
    match iterNext s true s.lookupProps syl (some f) k i with
    | none => return false
    | some j => i := j
  return true

/-! ## Glyph replacement with class bookkeeping -/

/-- `set_glyph_class` on the current glyph before it is replaced by `g`. -/
def setGlyphClass (g : Nat) (classGuess : Nat) (ligature component : Bool) : M Unit := do
  let s ← get
  let c := s.cur
  let mut p := c.gprops ||| 0x10
  if ligature then p := (p ||| 0x20) - (p &&& 0x40)
  if component then p := p ||| 0x40
  if s.lay.hasClasses then p := (p &&& 0x70) ||| s.lay.glyphProps g
  else if classGuess != 0 then p := (p &&& 0x70) ||| classGuess
  setCur { c with gprops := p }

def replaceGlyph (g : Nat) : M Unit := do setGlyphClass g 0 false false; bufReplace g
def replaceGlyphInplace (g : Nat) : M Unit := do
  setGlyphClass g 0 false false
  modify fun s => { s with info := s.info.setIfInBounds s.idx { s.cur with gid := g } }
def replaceWithLigature (g classGuess : Nat) : M Unit := do
  setGlyphClass g classGuess true false; bufReplace g
def outputForComponent (g classGuess : Nat) : M Unit := do
  setGlyphClass g classGuess false true; bufOutput g

/-! ## Subtables: shared helpers -/

/-- Coverage index of `gid` in the coverage table at `off`. -/
@[inline] def cov (l : Layout) (off gid : Nat) : Option Nat := Font.coverageIndex l.bs off gid

/-- Glyph class under the ClassDef at `off`. -/
@[inline] def cls (l : Layout) (off gid : Nat) : Nat := if off == 0 then 0 else Font.classOf l.bs off gid

/-- Resolve an extension subtable (GSUB 7 / GPOS 9): `(type, offset)`. -/
def resolveExt (l : Layout) (gpos : Bool) (typ off : Nat) : Nat × Nat :=
  if (gpos && typ == 9) || (!gpos && typ == 7) then
    if u16 l.bs off == 1 then (u16 l.bs (off + 2), off + u32 l.bs (off + 4)) else (0, 0)
  else (typ, off)

/-- `ligate_input`. -/
def ligateInput (count matchEnd totalComps ligGlyph : Nat) : M Unit := do
  let s0 ← get
  mergeClusters s0.idx matchEnd
  let s ← get
  let mp := s.matchPos
  let firstI := s.info.getD (mp.getD 0 0) default
  let mut isBaseLig := firstI.isBase
  let mut isMarkLig := firstI.isMark
  for i in [1:count] do
    if !(s.info.getD (mp.getD i 0) default).isMark then
      isBaseLig := false; isMarkLig := false
  let isLig := !isBaseLig && !isMarkLig
  let klass := if isLig then 4 else 0
  let ligId ← if isLig then allocLigId else pure 0
  let first := (← get).cur
  let mut lastLigId := first.ligId
  let mut lastNumComps := first.ligNumComps
  let mut compsSoFar := lastNumComps
  if isLig then
    let mut f := first.setLigForLigature ligId totalComps
    if f.gc == 12 then f := { f with gc := 7 }
    setCur f
  replaceWithLigature ligGlyph klass
  for i in [1:count] do
    let target := mp.getD i 0
    for _ in [0:(← get).len] do
      let st ← get
      if st.idx < target && st.ok then
        if isLig then
          let c := st.cur
          let mut thisComp := c.ligComp
          if thisComp == 0 then thisComp := lastNumComps
          let newComp := compsSoFar - lastNumComps + Nat.min thisComp lastNumComps
          setCur (c.setLigForMark ligId newComp)
        nextGlyph
      else break
    let c := (← get).cur
    lastLigId := c.ligId
    lastNumComps := c.ligNumComps
    compsSoFar := compsSoFar + lastNumComps
    skipGlyph
  if !isMarkLig && lastLigId != 0 then
    modify fun st => Id.run do
      let mut info := st.info
      for i in [st.idx:info.size] do
        let g := info.getD i default
        if lastLigId != g.ligId then break
        let thisComp := g.ligComp
        if thisComp == 0 then break
        let newComp := compsSoFar - lastNumComps + Nat.min thisComp lastNumComps
        info := info.setIfInBounds i (g.setLigForMark ligId newComp)
      return { st with info := info }

/-- `apply_lookup`: run the nested lookups of a matched context.  `recurse li`
applies lookup `li` once at the current position. -/
def applyNested (inputLen matchEnd : Nat) (records : Array (Nat × Nat))
    (recurse : Nat → M Bool) : M Unit := do
  let s ← get
  let mut count := inputLen + 1
  let delta0 : Int := (s.backtrackLen : Int) - (s.idx : Int)
  let mut mp : Array Nat := (s.matchPos.extract 0 count).map (fun (p : Nat) => ((p : Int) + delta0).toNat)
  let mut stop : Int := (s.backtrackLen : Int) + (matchEnd : Int) - (s.idx : Int)
  for (seqIdx, li) in records do
    if !(← get).ok then break
    if seqIdx ≥ count then continue
    let st ← get
    let origLen := st.backtrackLen + st.lookaheadLen
    if mp.getD seqIdx 0 ≥ origLen then continue
    if !(← moveTo (mp.getD seqIdx 0)) then break
    if (← get).ops == 0 then break
    let saved := (← get).matchPos
    let _ ← recurse li
    modify fun st => { st with matchPos := saved }
    let st2 ← get
    let newLen := st2.backtrackLen + st2.lookaheadLen
    let mut delta : Int := (newLen : Int) - (origLen : Int)
    if delta == 0 then continue
    stop := stop + delta
    let here : Int := (mp.getD seqIdx 0 : Nat)
    if stop < here then
      delta := delta + (here - stop)
      stop := here
    let mut next : Int := (seqIdx + 1 : Nat)
    if delta > 0 then
      if delta.toNat + count > maxContext then break
    else
      delta := max delta (next - (count : Int))
      next := next - delta
    -- shift match positions [next, count) by delta
    let nextN := next.toNat
    let tail := mp.extract nextN count
    let newNext := (next + delta).toNat
    let newCount := ((count : Int) + delta).toNat
    let mut mp2 := mp.extract 0 newNext
    for _ in [mp2.size:newNext] do mp2 := mp2.push 0
    mp2 := (mp2.extract 0 newNext) ++ tail
    -- fill in new entries
    for j in [seqIdx + 1:newNext] do
      mp2 := mp2.setIfInBounds j (mp2.getD (j - 1) 0 + 1)
    for j in [newNext:newCount] do
      mp2 := mp2.setIfInBounds j (((mp2.getD j 0 : Nat) : Int) + delta).toNat
    mp := mp2
    count := newCount
  let _ ← moveTo stop.toNat

/-! ## GSUB subtables -/

/-- A context rule: backtrack, input (after the first glyph) and lookahead
values, and its `(sequence index, lookup index)` records. -/
structure Rule where
  back : Array Nat := #[]
  input : Array Nat := #[]
  ahead : Array Nat := #[]
  records : Array (Nat × Nat) := #[]

def readArr (bs : ByteArray) (off n : Nat) : Array Nat := Id.run do
  let mut a := Array.emptyWithCapacity n
  for k in [0:n] do a := a.push (u16 bs (off + 2 * k))
  return a

def readRecords (bs : ByteArray) (off n : Nat) : Array (Nat × Nat) := Id.run do
  let mut a := Array.emptyWithCapacity n
  for k in [0:n] do a := a.push (u16 bs (off + 4 * k), u16 bs (off + 4 * k + 2))
  return a

/-- A (non-chained) `SequenceRule`/`ClassSequenceRule` at `off`. -/
def readRule (bs : ByteArray) (off : Nat) : Rule :=
  let gc := u16 bs off
  let rc := u16 bs (off + 2)
  let ni := if gc == 0 then 0 else gc - 1
  { input := readArr bs (off + 4) ni, records := readRecords bs (off + 4 + 2 * ni) rc }

/-- A chained rule at `off`. -/
def readChainRule (bs : ByteArray) (off : Nat) : Rule :=
  let bc := u16 bs off
  let bEnd := off + 2 + 2 * bc
  let ic := u16 bs bEnd
  let ni := if ic == 0 then 0 else ic - 1
  let iEnd := bEnd + 2 + 2 * ni
  let lc := u16 bs iEnd
  let lEnd := iEnd + 2 + 2 * lc
  { back := readArr bs (off + 2) bc, input := readArr bs (bEnd + 2) ni,
    ahead := readArr bs (iEnd + 2) lc, records := readRecords bs (lEnd + 2) (u16 bs lEnd) }

/-- Try one rule: input, lookahead, backtrack, then the nested lookups.
`fb`/`fi`/`fa` test a glyph against a rule value. -/
def applyRule (r : Rule) (fb fi fa : Nat → GInfo → Bool) (recurse : Nat → M Bool) : M Bool := do
  match ← matchInput r.input.size (fun k g => fi (r.input.getD k 0) g) with
  | none => return false
  | some (matchEnd, mp, _) =>
    if !(← matchLookahead r.ahead.size (fun k g => fa (r.ahead.getD k 0) g) matchEnd) then return false
    if !(← matchBacktrack r.back.size (fun k g => fb (r.back.getD k 0) g)) then return false
    modify fun s => { s with matchPos := mp }
    applyNested r.input.size matchEnd r.records recurse
    return true

/-- Context (GSUB 5 / GPOS 7) and chained context (GSUB 6 / GPOS 8), all
three formats. -/
def applyContext (chain : Bool) (off : Nat) (recurse : Nat → M Bool) : M Bool := do
  let s ← get
  let l := s.lay
  let bs := l.bs
  let g := s.cur.gid
  let fmt := u16 bs off
  let rd := if chain then readChainRule bs else readRule bs
  if fmt == 1 then
    match cov l (off + u16 bs (off + 2)) g with
    | none => return false
    | some ix =>
      if ix ≥ u16 bs (off + 4) then return false
      let set := off + u16 bs (off + 6 + 2 * ix)
      let byGlyph := fun (v : Nat) (x : GInfo) => x.gid == v
      for k in [0:u16 bs set] do
        if ← applyRule (rd (set + u16 bs (set + 2 + 2 * k))) byGlyph byGlyph byGlyph recurse then return true
      return false
  else if fmt == 2 then
    match cov l (off + u16 bs (off + 2)) g with
    | none => return false
    | some _ =>
      let (cdB, cdI, cdA, nsets, setsAt) :=
        if chain then
          let rel := fun (k : Nat) => let v := u16 bs (off + k); if v == 0 then 0 else off + v
          (rel 4, rel 6, rel 8, u16 bs (off + 10), off + 12)
        else
          let v := u16 bs (off + 4)
          let cd := if v == 0 then 0 else off + v
          (cd, cd, cd, u16 bs (off + 6), off + 8)
      let c := cls l cdI g
      if c ≥ nsets then return false
      let so := u16 bs (setsAt + 2 * c)
      if so == 0 then return false
      let set := off + so
      let fb := fun (v : Nat) (x : GInfo) => cls l cdB x.gid == v
      let fi := fun (v : Nat) (x : GInfo) => cls l cdI x.gid == v
      let fa := fun (v : Nat) (x : GInfo) => cls l cdA x.gid == v
      for k in [0:u16 bs set] do
        if ← applyRule (rd (set + u16 bs (set + 2 + 2 * k))) fb fi fa recurse then return true
      return false
  else if fmt == 3 then
    let byCov := fun (v : Nat) (x : GInfo) => (cov l (off + v) x.gid).isSome
    if chain then
      let bc := u16 bs (off + 2)
      let iAt := off + 4 + 2 * bc
      let ic := u16 bs iAt
      let aAt := iAt + 2 + 2 * ic
      let ac := u16 bs aAt
      let rAt := aAt + 2 + 2 * ac
      if ic == 0 then return false
      let inputs := readArr bs (iAt + 2) ic
      if (cov l (off + inputs.getD 0 0) g).isNone then return false
      let r : Rule := { back := readArr bs (off + 4) bc, input := inputs.extract 1 inputs.size,
                        ahead := readArr bs (aAt + 2) ac, records := readRecords bs (rAt + 2) (u16 bs rAt) }
      applyRule r byCov byCov byCov recurse
    else
      let gc := u16 bs (off + 2)
      let rc := u16 bs (off + 4)
      if gc == 0 then return false
      let inputs := readArr bs (off + 6) gc
      if (cov l (off + inputs.getD 0 0) g).isNone then return false
      let r : Rule := { input := inputs.extract 1 inputs.size, records := readRecords bs (off + 6 + 2 * gc) rc }
      applyRule r byCov byCov byCov recurse
  else return false

/-- GSUB 1: single substitution. -/
def applySingle (off : Nat) : M Bool := do
  let s ← get
  let bs := s.lay.bs
  let g := s.cur.gid
  match cov s.lay (off + u16 bs (off + 2)) g with
  | none => return false
  | some ix =>
    let fmt := u16 bs off
    if fmt == 1 then
      replaceGlyph ((g + u16 bs (off + 4)) % 65536); return true
    else if fmt == 2 then
      if ix ≥ u16 bs (off + 4) then return false
      replaceGlyph (u16 bs (off + 6 + 2 * ix)); return true
    else return false

/-- GSUB 2: multiple substitution. -/
def applyMultiple (off : Nat) : M Bool := do
  let s ← get
  let bs := s.lay.bs
  match cov s.lay (off + u16 bs (off + 2)) s.cur.gid with
  | none => return false
  | some ix =>
    if u16 bs off != 1 || ix ≥ u16 bs (off + 4) then return false
    let seq := off + u16 bs (off + 6 + 2 * ix)
    let n := u16 bs seq
    if n == 0 then deleteGlyph; return true
    if n == 1 then replaceGlyph (u16 bs (seq + 2)); return true
    let klass := if s.cur.isLigature then 2 else 0
    let ligId := s.cur.ligId
    for i in [0:n] do
      if ligId == 0 then setCur ((← get).cur.setLigForMark 0 i)
      outputForComponent (u16 bs (seq + 2 + 2 * i)) klass
    skipGlyph
    return true

/-- GSUB 3: alternate substitution; every feature here has value 1, so the
first alternate. -/
def applyAlternate (off : Nat) : M Bool := do
  let s ← get
  let bs := s.lay.bs
  match cov s.lay (off + u16 bs (off + 2)) s.cur.gid with
  | none => return false
  | some ix =>
    if u16 bs off != 1 || ix ≥ u16 bs (off + 4) then return false
    let set := off + u16 bs (off + 6 + 2 * ix)
    if u16 bs set == 0 then return false
    replaceGlyph (u16 bs (set + 2)); return true

/-- GSUB 4: ligature substitution. -/
def applyLigature (off : Nat) : M Bool := do
  let s ← get
  let bs := s.lay.bs
  match cov s.lay (off + u16 bs (off + 2)) s.cur.gid with
  | none => return false
  | some ix =>
    if u16 bs off != 1 || ix ≥ u16 bs (off + 4) then return false
    let set := off + u16 bs (off + 6 + 2 * ix)
    for k in [0:u16 bs set] do
      let lig := set + u16 bs (set + 2 + 2 * k)
      let ligGlyph := u16 bs lig
      let cc := u16 bs (lig + 2)
      if cc ≤ 1 then
        replaceGlyph ligGlyph; return true
      let comps := readArr bs (lig + 4) (cc - 1)
      match ← matchInput comps.size (fun k g => g.gid == comps.getD k 0) with
      | none => pure ()
      | some (matchEnd, mp, total) =>
        modify fun st => { st with matchPos := mp }
        ligateInput cc matchEnd total ligGlyph
        return true
    return false

/-- GSUB 8: reverse chaining single substitution (in place; only at the top
level, as harfrust). -/
def applyReverseChain (off : Nat) (top : Bool) : M Bool := do
  if !top then return false
  let s ← get
  let bs := s.lay.bs
  let l := s.lay
  if u16 bs off != 1 then return false
  match cov l (off + u16 bs (off + 2)) s.cur.gid with
  | none => return false
  | some ix =>
    let bc := u16 bs (off + 4)
    let lAt := off + 6 + 2 * bc
    let lc := u16 bs lAt
    let sAt := lAt + 2 + 2 * lc
    let sc := u16 bs sAt
    if ix ≥ sc then return false
    let subst := u16 bs (sAt + 2 + 2 * ix)
    let fb := fun (k : Nat) (x : GInfo) => (cov l (off + u16 bs (off + 6 + 2 * k)) x.gid).isSome
    let fa := fun (k : Nat) (x : GInfo) => (cov l (off + u16 bs (lAt + 2 + 2 * k)) x.gid).isSome
    if ← matchBacktrack bc (fun k g => fb k g) then
      if ← matchLookahead lc (fun k g => fa k g) (s.idx + 1) then
        replaceGlyphInplace subst
        return true
    return false

/-! ## GPOS subtables -/

/-- Add a value record of format `fmt` at `off` to glyph `i`'s position. -/
def applyValue (i : Nat) (off fmt : Nat) : M Unit := modify fun s => Id.run do
  let bs := s.lay.bs
  let mut o := off
  let mut p := s.pos.getD i default
  if fmt &&& 1 != 0 then p := { p with xOff := p.xOff + i16 bs o }; o := o + 2
  if fmt &&& 2 != 0 then p := { p with yOff := p.yOff + i16 bs o }; o := o + 2
  if fmt &&& 4 != 0 then p := { p with xAdv := p.xAdv + i16 bs o }; o := o + 2
  return { s with pos := s.pos.setIfInBounds i p }

/-- GPOS 1: single adjustment. -/
def applySinglePos (off : Nat) : M Bool := do
  let s ← get
  let bs := s.lay.bs
  match cov s.lay (off + u16 bs (off + 2)) s.cur.gid with
  | none => return false
  | some ix =>
    let fmt := u16 bs off
    let vf := u16 bs (off + 4)
    if fmt == 1 then applyValue s.idx (off + 6) vf
    else if fmt == 2 then applyValue s.idx (off + 8 + Font.valueRecordSize vf * ix) vf
    else return false
    modify fun st => { st with idx := st.idx + 1 }
    return true

/-- GPOS 2: pair adjustment. -/
def applyPairPos (off : Nat) : M Bool := do
  let s ← get
  let l := s.lay
  let bs := l.bs
  let first := s.cur.gid
  match cov l (off + u16 bs (off + 2)) first with
  | none => return false
  | some ix =>
    match iterNext s false s.lookupProps s.cur.syl none 0 s.idx with
    | none => return false
    | some j =>
      let second := (s.info.getD j default).gid
      let fmt := u16 bs off
      let vf1 := u16 bs (off + 4)
      let vf2 := u16 bs (off + 6)
      let len1 := Font.valueRecordSize vf1
      let finish := fun (_ : Unit) => modify fun st => { st with idx := if vf2 != 0 then j + 1 else j }
      if fmt == 1 then
        if ix ≥ u16 bs (off + 8) then return false
        let set := off + u16 bs (off + 10 + 2 * ix)
        let recSize := 2 + len1 + Font.valueRecordSize vf2
        let n := u16 bs set
        -- binary search on the second glyph
        let mut lo := 0
        let mut hi := n
        for _ in [0:17] do
          if lo ≥ hi then break
          let mid := (lo + hi) / 2
          let ro := set + 2 + mid * recSize
          let gid := u16 bs ro
          if gid < second then lo := mid + 1
          else if gid > second then hi := mid
          else
            if vf1 != 0 then applyValue s.idx (ro + 2) vf1
            if vf2 != 0 then applyValue j (ro + 2 + len1) vf2
            finish ()
            return true
        return false
      else if fmt == 2 then
        let cd1 := off + u16 bs (off + 8)
        let cd2 := off + u16 bs (off + 10)
        let c2n := u16 bs (off + 14)
        let c1 := cls l cd1 first
        let c2 := cls l cd2 second
        let recSize := len1 + Font.valueRecordSize vf2
        let ro := off + 16 + (c1 * c2n + c2) * recSize
        if c1 < u16 bs (off + 12) && c2 < c2n then
          if vf1 != 0 then applyValue s.idx ro vf1
          if vf2 != 0 then applyValue j (ro + len1) vf2
        finish ()
        return true
      else return false

/-- An anchor's `(x, y)`. -/
def anchor (bs : ByteArray) (off : Nat) : Int × Int := (i16 bs (off + 2), i16 bs (off + 4))

/-- `reverse_cursive_minor_offset`, bounded by the buffer length. -/
def reverseCursiveMinor (pos : Array GPos) (i0 newParent : Nat) : Array GPos := Id.run do
  let mut pos := pos
  -- walk the chain from i0, remembering the nodes, then fix them bottom-up
  let mut nodes : Array (Nat × Nat × Int × Nat) := #[]   -- (i, j, chain, type)
  let mut i := i0
  for _ in [0:pos.size] do
    let p := pos.getD i default
    if p.chain == 0 || p.atype &&& 2 == 0 then break
    pos := pos.setIfInBounds i { p with chain := 0 }
    let j := ((i : Int) + p.chain).toNat
    if j == newParent then break
    nodes := nodes.push (i, j, p.chain, p.atype)
    i := j
  for k in [0:nodes.size] do
    let (c, j, chain, t) := nodes.getD (nodes.size - 1 - k) (0, 0, 0, 0)
    let pj := pos.getD j default
    pos := pos.setIfInBounds j { pj with yOff := -(pos.getD c default).yOff, chain := -chain, atype := t }
  return pos

/-- GPOS 3: cursive attachment (horizontal). -/
def applyCursive (off : Nat) : M Bool := do
  let s ← get
  let l := s.lay
  let bs := l.bs
  if u16 bs off != 1 then return false
  let covOff := off + u16 bs (off + 2)
  match cov l covOff s.cur.gid with
  | none => return false
  | some ixThis =>
    let entryThis := u16 bs (off + 6 + 4 * ixThis)
    if entryThis == 0 then return false
    match iterPrev s false s.lookupProps s.cur.syl none 0 s.idx with
    | none => return false
    | some i =>
      match cov l covOff (s.info.getD i default).gid with
      | none => return false
      | some ixPrev =>
        let exitPrev := u16 bs (off + 8 + 4 * ixPrev)
        if exitPrev == 0 then return false
        let (exitX, exitY) := anchor bs (off + exitPrev)
        let (entryX, entryY) := anchor bs (off + entryThis)
        let j := s.idx
        let mut pos := s.pos
        let pi := pos.getD i default
        let pj := pos.getD j default
        if !s.rtl then
          let d := entryX + pj.xOff
          pos := pos.setIfInBounds i { pi with xAdv := exitX + pi.xOff }
          pos := pos.setIfInBounds j { pj with xAdv := pj.xAdv - d, xOff := pj.xOff - d }
        else
          let d := exitX + pi.xOff
          pos := pos.setIfInBounds i { pi with xAdv := pi.xAdv - d, xOff := pi.xOff - d }
          pos := pos.setIfInBounds j { pj with xAdv := entryX + pj.xOff }
        let mut child := i
        let mut parent := j
        let mut yOffset := entryY - exitY
        if s.lookupProps &&& 1 == 0 then
          child := j; parent := i; yOffset := -yOffset
        pos := reverseCursiveMinor pos child parent
        let pc := pos.getD child default
        pos := pos.setIfInBounds child
          { pc with atype := 2, chain := (parent : Int) - (child : Int), yOff := yOffset }
        let pp := pos.getD parent default
        if pp.chain == -((pos.getD child default).chain) then
          pos := pos.setIfInBounds parent { pp with chain := 0, yOff := 0 }
        set { s with pos := pos, idx := s.idx + 1 }
        return true

/-- Attach the current mark to glyph `base` at the two anchors. -/
def markApply (baseAnchor markAnchor : Nat) (base : Nat) : M Bool := do
  modify fun s =>
    let (bx, byy) := anchor s.lay.bs baseAnchor
    let (mx, myy) := anchor s.lay.bs markAnchor
    let p := s.pos.getD s.idx default
    { s with pos := s.pos.setIfInBounds s.idx
               { p with xOff := bx - mx, yOff := byy - myy, atype := 1,
                        chain := (base : Int) - (s.idx : Int) },
             idx := s.idx + 1 }
  return true

/-- The mark record of `markIx` in the MarkArray at `ma`: `(class, anchor)`. -/
def markRecord (bs : ByteArray) (ma markIx : Nat) : Nat × Nat :=
  (u16 bs (ma + 2 + 4 * markIx), ma + u16 bs (ma + 4 + 4 * markIx))

/-- MarkBase's `accept`: attach only to the first of a MultipleSubst sequence. -/
def acceptBase (info : Array GInfo) (i : Nat) : Bool :=
  let g := info.getD i default
  !g.multiplied || g.ligComp == 0 ||
    (i == 0 || (info.getD (i - 1) default).isMark || !(info.getD (i - 1) default).multiplied ||
      g.ligId != (info.getD (i - 1) default).ligId || g.ligComp != (info.getD (i - 1) default).ligComp + 1)

/-- The nearest earlier glyph a mark may attach to (lookup props with only
IgnoreMarks), optionally filtered. -/
def findBase (s : St) (extra : Nat → Bool) : Option Nat := Id.run do
  let mut j := s.idx
  for _ in [0:s.idx] do
    if j == 0 then return none
    let g := s.info.getD (j - 1) default
    let m := matchAt s false 8 0 none g
    if m == .yes && extra (j - 1) then return some (j - 1)
    j := j - 1
  return none

/-- GPOS 4: mark-to-base. -/
def applyMarkBase (off : Nat) : M Bool := do
  let s ← get
  let l := s.lay
  let bs := l.bs
  if u16 bs off != 1 then return false
  match cov l (off + u16 bs (off + 2)) s.cur.gid with
  | none => return false
  | some markIx =>
    let baseCov := off + u16 bs (off + 4)
    match findBase s (fun i => acceptBase s.info i || (cov l baseCov (s.info.getD i default).gid).isSome) with
    | none => return false
    | some b =>
      match cov l baseCov (s.info.getD b default).gid with
      | none => return false
      | some baseIx =>
        let classCount := u16 bs (off + 6)
        let ma := off + u16 bs (off + 8)
        let ba := off + u16 bs (off + 10)
        let (mc, mAnchor) := markRecord bs ma markIx
        if mc ≥ classCount || baseIx ≥ u16 bs ba then return false
        let ao := u16 bs (ba + 2 + 2 * (baseIx * classCount + mc))
        if ao == 0 then return false
        markApply (ba + ao) mAnchor b

/-- GPOS 5: mark-to-ligature. -/
def applyMarkLig (off : Nat) : M Bool := do
  let s ← get
  let l := s.lay
  let bs := l.bs
  if u16 bs off != 1 then return false
  match cov l (off + u16 bs (off + 2)) s.cur.gid with
  | none => return false
  | some markIx =>
    match findBase s (fun _ => true) with
    | none => return false
    | some b =>
      match cov l (off + u16 bs (off + 4)) (s.info.getD b default).gid with
      | none => return false
      | some ligIx =>
        let classCount := u16 bs (off + 6)
        let ma := off + u16 bs (off + 8)
        let la := off + u16 bs (off + 10)
        if ligIx ≥ u16 bs la then return false
        let attach := la + u16 bs (la + 2 + 2 * ligIx)
        let compCount := u16 bs attach
        if compCount == 0 then return false
        let ligId := (s.info.getD b default).ligId
        let markId := s.cur.ligId
        let markComp := s.cur.ligComp
        let compIx := (if ligId != 0 && ligId == markId && markComp > 0 then Nat.min markComp compCount
          else compCount) - 1
        let (mc, mAnchor) := markRecord bs ma markIx
        if mc ≥ classCount then return false
        let ao := u16 bs (attach + 2 + 2 * (compIx * classCount + mc))
        if ao == 0 then return false
        markApply (attach + ao) mAnchor b

/-- GPOS 6: mark-to-mark. -/
def applyMarkMark (off : Nat) : M Bool := do
  let s ← get
  let l := s.lay
  let bs := l.bs
  if u16 bs off != 1 then return false
  match cov l (off + u16 bs (off + 2)) s.cur.gid with
  | none => return false
  | some m1Ix =>
    match iterPrev s false (s.lookupProps - (s.lookupProps &&& 0x0E)) s.cur.syl none 0 s.idx with
    | none => return false
    | some j =>
      let prev := s.info.getD j default
      if !prev.isMark then return false
      let id1 := s.cur.ligId
      let id2 := prev.ligId
      let c1 := s.cur.ligComp
      let c2 := prev.ligComp
      let ok := if id1 == id2 then id1 == 0 || c1 == c2 else (id1 > 0 && c1 == 0) || (id2 > 0 && c2 == 0)
      if !ok then return false
      match cov l (off + u16 bs (off + 4)) prev.gid with
      | none => return false
      | some m2Ix =>
        let classCount := u16 bs (off + 6)
        let ma := off + u16 bs (off + 8)
        let m2a := off + u16 bs (off + 10)
        let (mc, mAnchor) := markRecord bs ma m1Ix
        if mc ≥ classCount || m2Ix ≥ u16 bs m2a then return false
        let ao := u16 bs (m2a + 2 + 2 * (m2Ix * classCount + mc))
        if ao == 0 then return false
        markApply (m2a + ao) mAnchor j

/-! ## Applying lookups -/

/-- The lookup's flag word with its mark filtering set in the high half. -/
def lookupProps (l : Layout) (lo : Nat) : Nat :=
  let flag := u16 l.bs (lo + 2)
  if flag &&& 0x10 != 0 then flag ||| (u16 l.bs (lo + 6 + 2 * u16 l.bs (lo + 4)) <<< 16) else flag

/-- Apply lookup `li` once at the current glyph: its subtables in order until
one applies.  `fuel` bounds the nesting of context lookups; `top` is whether
this is a top-level application (reverse chaining only applies there). -/
def applyLookupOnce : Nat → Bool → Nat → M Bool
  | 0, _, _ => do modify fun s => { s with ok := false }; return false
  | fuel + 1, top, li => do
    let s ← get
    let l := s.lay
    let gpos := s.isGpos
    if li ≥ l.lookupCount gpos then return false
    let lo := l.lookupOff gpos li
    let typ := u16 l.bs lo
    let n := u16 l.bs (lo + 4)
    let recurse := fun (sub : Nat) => do
      let st ← get
      if st.ops == 0 then return false
      spend 1
      let savedProps := st.lookupProps
      let sl := st.lay.lookupOff st.isGpos sub
      modify fun st => { st with lookupProps := lookupProps st.lay sl }
      let r ← applyLookupOnce fuel false sub
      modify fun st => { st with lookupProps := savedProps }
      return r
    for k in [0:n] do
      let (t, so) := resolveExt l gpos typ (lo + u16 l.bs (lo + 6 + 2 * k))
      spend 1
      if !(← get).ok then return false
      let applied ← if !gpos then
          match t with
          | 1 => applySingle so
          | 2 => applyMultiple so
          | 3 => applyAlternate so
          | 4 => applyLigature so
          | 5 => applyContext false so recurse
          | 6 => applyContext true so recurse
          | 8 => applyReverseChain so top
          | _ => pure false
        else
          match t with
          | 1 => applySinglePos so
          | 2 => applyPairPos so
          | 3 => applyCursive so
          | 4 => applyMarkBase so
          | 5 => applyMarkLig so
          | 6 => applyMarkMark so
          | 7 => applyContext false so recurse
          | 8 => applyContext true so recurse
          | _ => pure false
      if applied then return true
    return false

/-- Whether lookup `li` is a reverse chaining one (GSUB 8, possibly behind an
extension). -/
def isReverse (l : Layout) (li : Nat) : Bool :=
  let lo := l.lookupOff false li
  let typ := u16 l.bs lo
  if typ == 8 then true
  else if typ == 7 && u16 l.bs (lo + 4) > 0 then
    let so := lo + u16 l.bs (lo + 6)
    u16 l.bs so == 1 && u16 l.bs (so + 2) == 8
  else false

/-- `apply_string`: one lookup over the whole buffer. -/
def applyString (m : LookupMap) : M Unit := do
  let s ← get
  if s.len == 0 || m.mask == 0 then return
  let l := s.lay
  let props := lookupProps l (l.lookupOff s.isGpos m.index)
  set { s with lookupMask := m.mask, lookupProps := props, autoZwj := m.autoZwj,
               autoZwnj := m.autoZwnj, perSyl := m.perSyl }
  if !s.isGpos && isReverse l m.index then
    modify fun st => { st with haveOutput := false, idx := st.len - 1 }
    for _ in [0:s.len] do
      let st ← get
      let c := st.cur
      if c.mask &&& m.mask != 0 && checkProp l c props then
        let _ ← applyLookupOnce maxNesting true m.index
      if st.idx == 0 then break
      modify fun st => { st with idx := st.idx - 1 }
    return
  if !s.isGpos then clearOutput else modify fun st => { st with idx := 0 }
  let bound := s.maxLen + s.ops + 1
  for _ in [0:bound] do
    let st ← get
    if !st.ok then break
    -- skip to the next glyph this lookup may apply to
    let mut j := st.idx
    for _ in [st.idx:st.len] do
      let g := st.info.getD j default
      if g.mask &&& m.mask != 0 && checkProp l g props then break
      j := j + 1
    if j > st.idx then nextGlyphs (j - st.idx)
    let st ← get
    if st.idx ≥ st.len then break
    if ← applyLookupOnce maxNesting true m.index then pure () else nextGlyph
  if !s.isGpos then sync

end Shape
end LeanSvg
