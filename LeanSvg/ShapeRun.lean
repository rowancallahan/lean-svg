import LeanSvg.Shape
import LeanSvg.Bidi

/-!
# Shaping one run (T93)

`shapeRun` is harfrust 0.12.0's `shape` for one bidi run of one font, as usvg
calls it (`UnicodeBuffer::push_str`, direction from the bidi level,
`guess_segment_properties` for the script, no language, no buffer flags, the
only user feature being `kern=0` under `font-kerning: none`):

1. Unicode properties, grapheme clusters, native direction
   (`ensure_native_direction`), the Indic vowel-constraint dotted circles;
2. mirroring in right-to-left runs, normalisation
   (`_hb_ot_shape_normalize`: decompose, reorder marks by modified combining
   class, recompose), the shaper's masks (Arabic joining, Indic categories);
3. GSUB stage by stage, with the shaper's pauses (Indic syllables, initial and
   final reordering);
4. advances, GPOS, zero-width marks, attachment offsets, and the final
   reversal of a right-to-left run; default ignorables become the space glyph.

The shapers: default (everything but the below), Arabic (`arab`/`syrc`
joining with the Unicode joining types, `isol`/`fina`/`fin2`/`fin3`/`medi`/
`med2`/`init` each in its own stage, `rlig`, `calt`, modifier combining mark
reordering), Hebrew (`hebr` GPOS only, its mark reordering), and Indic for
Devanagari (the `indic_syllable_machine` grammar, reph, pre-base matra and
base-consonant logic of harfrust's `ot_shaper_indic.rs`, with Devanagari's
configuration; other Indic scripts get the same code with Devanagari's
configuration, which matters little since no embedded font covers them).

Not implemented (documented in the task file): fallback mark positioning and
fallback kerning for fonts without GPOS, `stch`, the fraction features,
Mongolian variation selectors, emoji ZWJ sequences as one grapheme, vertical
text.
-/

namespace LeanSvg
namespace Shape

open LeanSvg.Font (u16)

/-! ## Scripts -/

/-- The run's script, as harfrust's `guess_segment_properties`: the first
character whose script is not Common, Inherited or Unknown (`""` if none). -/
def guessScript (cps : Array Nat) : String := Id.run do
  for cp in cps do
    let s := ShapeData.scriptOf cp
    if s != "Zyyy" && s != "Zinh" && s != "Zzzz" then return s
  return ""

/-- A script's native horizontal direction (harfrust `Direction::from_script`):
`some true` right to left, `some false` left to right, `none` for no script
and the four scripts written either way. -/
def scriptRtl (iso : String) : Option Bool :=
  if iso == "" || ["Hung", "Ital", "Runr", "Tfng"].contains iso then none
  else some (["Arab", "Hebr", "Syrc", "Thaa", "Cprt", "Khar", "Phnx", "Nkoo", "Lydi", "Avst", "Armi",
    "Phli", "Prti", "Sarb", "Orkh", "Samr", "Mand", "Merc", "Mero", "Mani", "Mend", "Nbat",
    "Narb", "Palm", "Phlp", "Hatr", "Adlm", "Rohg", "Sogo", "Sogd", "Elym", "Chrs",
    "Yezi", "Ougr", "Gara", "Sidt"].contains iso)

/-- The OpenType script tags harfrust tries for an ISO 15924 script
(`all_tags_from_script`): the new-style Indic tags first. -/
def otScriptTags (iso : String) : Array Nat :=
  if iso == "" then #[]
  else
    let newTag : Option String := match iso with
      | "Beng" => some "bng2" | "Deva" => some "dev2" | "Gujr" => some "gjr2"
      | "Guru" => some "gur2" | "Knda" => some "knd2" | "Mlym" => some "mlm2"
      | "Orya" => some "ory2" | "Taml" => some "tml2" | "Telu" => some "tel2"
      | "Mymr" => some "mym2" | _ => none
    let old : String := match iso with
      | "Zmth" => "math" | "Hira" => "kana" | "Laoo" => "lao " | "Yiii" => "yi  "
      | "Nkoo" => "nko " | "Vaii" => "vai "
      | _ => String.ofList (iso.toList.mapIdx (fun i c => if i == 0 then c.toLower else c))
    match newTag with
    | some t =>
      let t3 := String.ofList ((t.toList.take 3) ++ ['3'])
      if t == "mym2" then #[tag t, tag old] else #[tag t3, tag t, tag old]
    | none => #[tag old]

inductive Shaper where
  | default
  | arabic
  | hebrew
  | indic
deriving BEq, Inhabited, Repr

/-- `hb_ot_shape_complex_categorize`, for the scripts that matter here. -/
def pickShaper (iso : String) (gsubScript : Nat) : Shaper :=
  let dflt := gsubScript == tag "DFLT" || gsubScript == 0
  if iso == "Arab" || iso == "Syrc" then
    if iso == "Arab" || !dflt then .arabic else .default
  else if iso == "Hebr" then .hebrew
  else if #["Beng", "Deva", "Gujr", "Guru", "Knda", "Mlym", "Orya", "Taml", "Telu"].contains iso then
    if dflt || gsubScript == tag "latn" then .default
    else if gsubScript % 256 == 0x33 then .default   -- USE shaper: not implemented
    else .indic
  else .default

/-! ## Building the plan -/

def arabicFeatures : Array String := #["isol", "fina", "fin2", "fin3", "medi", "med2", "init"]

/-- Indic features in order, with their map flags. -/
def indicFeatures : Array (String × Nat) :=
  let gm := fGlobal ||| fManualJoiners ||| fPerSyllable
  let m := fManualJoiners ||| fPerSyllable
  #[("nukt", gm), ("akhn", gm), ("rphf", m), ("rkrf", gm), ("pref", m), ("blwf", m), ("abvf", m),
    ("half", m), ("pstf", m), ("vatu", gm), ("cjct", gm), ("init", m), ("pres", gm), ("abvs", gm),
    ("blws", gm), ("psts", gm), ("haln", gm)]

/-- Whether the font's default LangSys for the chosen script lists `t` in
either table (`has_feature`). -/
def hasFeature (l : Layout) (tags : Array Nat) (t : Nat) : Bool :=
  [false, true].any fun gpos =>
    match (l.selectScript gpos tags).bind (fun (s, _) => l.defaultLangSys s) with
    | some ls => (l.findFeature gpos ls t).isSome
    | none => false

/-- `collect_features` (common, horizontal, and the shaper's own). -/
def buildFeatures (l : Layout) (tags : Array Nat) (sh : Shaper) (iso : String) (rtl kerning : Bool)
    (smallCaps : Bool := false) : Builder := Id.run do
  let mut b : Builder := {}
  b := b.enable (tag "rvrn") 0
  b := b.pause .none
  if !rtl then
    b := b.enable (tag "ltra") 0
    b := b.enable (tag "ltrm") 0
  else
    b := b.enable (tag "rtla") 0
    b := b.add (tag "rtlm") 0
  b := b.add (tag "frac") 0
  b := b.add (tag "numr") 0
  b := b.add (tag "dnom") 0
  b := b.enable (tag "Harf") 0
  b := b.enable (tag "HARF") 0
  match sh with
  | .arabic =>
    b := b.enable (tag "stch") 0
    b := b.pause .none
    b := b.enable (tag "ccmp") fManualZwj
    b := b.enable (tag "locl") fManualZwj
    b := b.pause .none
    for f in arabicFeatures do
      let fb := if iso == "Arab" then fHasFallback else 0
      b := b.add (tag f) (fManualZwj ||| fb)
      b := b.pause .none
    b := b.pause .none
    b := b.enable (tag "rlig") (fManualZwj ||| fHasFallback)
    if iso == "Arab" then b := b.pause .none
    b := b.enable (tag "calt") fManualZwj
    if !hasFeature l tags (tag "rclt") then b := b.pause .none
    b := b.enable (tag "liga") fManualZwj
    b := b.enable (tag "clig") fManualZwj
    b := b.enable (tag "mset") fManualZwj
  | .indic =>
    b := b.pause .indicSetupSyllables
    b := b.enable (tag "locl") fPerSyllable
    b := b.enable (tag "ccmp") fPerSyllable
    b := b.pause .indicInitial
    for (f, fl) in indicFeatures.extract 0 11 do
      b := b.add (tag f) fl
      b := b.pause .none
    b := b.pause .indicFinal
    for (f, fl) in indicFeatures.extract 11 indicFeatures.size do
      b := b.add (tag f) fl
  | _ => pure ()
  b := b.enable (tag "Buzz") 0
  b := b.enable (tag "BUZZ") 0
  for f in ["abvm", "blwm", "ccmp", "locl"] do b := b.add (tag f) fGlobal
  for f in ["mark", "mkmk"] do b := b.add (tag f) (fGlobal ||| fManualJoiners)
  b := b.add (tag "rlig") fGlobal
  for f in ["calt", "clig", "curs", "dist"] do b := b.add (tag f) fGlobal
  b := b.add (tag "kern") (fGlobal ||| fHasFallback)
  for f in ["liga", "rclt"] do b := b.add (tag f) fGlobal
  -- usvg's user features: `smcp` for `font-variant: small-caps` (T97), then
  -- `kern` off for `font-kerning: none`
  if smallCaps then b := b.add (tag "smcp") fGlobal
  if !kerning then b := b.add (tag "kern") fGlobal 0
  if sh == .indic then
    b := b.disable (tag "liga")
    b := b.pause .clearSyllables
  return b

/-! ## Arabic joining -/

/-- harfrust's Arabic `STATE_TABLE`: `(action for prev, action for this,
next state)` per state and joining type. Actions: 0 isol, 1 fina, 2 fin2,
3 fin3, 4 medi, 5 med2, 6 init, 7 none. -/
def arabicStates : Array (Array (Nat × Nat × Nat)) := #[
  #[(7, 7, 0), (7, 0, 2), (7, 0, 1), (7, 0, 2), (7, 0, 1), (7, 0, 6)],
  #[(7, 7, 0), (7, 0, 2), (7, 0, 1), (7, 0, 2), (7, 2, 5), (7, 0, 6)],
  #[(7, 7, 0), (7, 0, 2), (6, 1, 1), (6, 1, 3), (6, 1, 4), (6, 1, 6)],
  #[(7, 7, 0), (7, 0, 2), (4, 1, 1), (4, 1, 3), (4, 1, 4), (4, 1, 6)],
  #[(7, 7, 0), (7, 0, 2), (5, 0, 1), (5, 0, 2), (5, 2, 5), (5, 0, 6)],
  #[(7, 7, 0), (7, 0, 2), (0, 0, 1), (0, 0, 2), (0, 2, 5), (0, 0, 6)],
  #[(7, 7, 0), (7, 0, 2), (7, 0, 1), (7, 0, 2), (7, 3, 5), (7, 0, 6)]]

/-- Joining type with `X` resolved by general category (`get_joining_type`). -/
def joiningTypeOf (cp gc : Nat) : Nat :=
  let t := ShapeData.joiningType cp
  if t != 7 then t else if gc == 12 || gc == 11 || gc == 1 then 6 else 0

/-- `arabic_joining` + `setup_masks_inner`: each glyph's `cat` becomes its
shaping action and its mask gains that feature's bit. -/
def arabicMasks (plan : Plan) (info : Array GInfo) : Array GInfo := Id.run do
  let masks := arabicFeatures.map (fun f => plan.mask1 (tag f))
  let mut info := info
  let mut prev : Option Nat := none
  let mut state := 0
  for i in [0:info.size] do
    let g := info.getD i default
    let t := joiningTypeOf g.cp g.gc
    if t == 6 then
      info := info.setIfInBounds i { g with cat := 7 }
      continue
    let (pa, ta, ns) := (arabicStates.getD state #[]).getD t (7, 7, 0)
    if pa != 7 then
      match prev with
      | some p => info := info.setIfInBounds p { info.getD p default with cat := pa }
      | none => pure ()
    info := info.setIfInBounds i { info.getD i default with cat := ta }
    prev := some i
    state := ns
  return info.map fun g => { g with mask := g.mask ||| masks.getD g.cat 0 }

/-- harfrust's `MODIFIER_COMBINING_MARKS`. -/
def modifierCombiningMarks : Array Nat :=
  #[0x0654, 0x0655, 0x0658, 0x06DC, 0x06E3, 0x06E7, 0x06E8, 0x08CA, 0x08CB, 0x08CD, 0x08CE, 0x08CF,
    0x08D3, 0x08F3]

/-! ## Normalisation -/

/-- The font's glyph for `cp`, if it has one. -/
def nominal (f : Font) (cp : Nat) : Option Nat :=
  let g := Font.glyphId f cp
  if g == 0 then none else some g

/-- A fresh glyph record for character `cp` that copies `from`'s cluster and
mask. -/
def charInfo (cp : Nat) (src : GInfo) (glyph : Nat) : GInfo :=
  let (gc, ccc, fl) := unicodeProps cp
  { src with cp := cp, gc := gc, ccc := ccc, uflags := fl, ngid := glyph }

/-- The shaper-specific decomposition (`decompose` callbacks). -/
def shaperDecompose (sh : Shaper) (cp : Nat) : Option (Nat × Nat) :=
  if sh == .indic && (cp == 0x0931 || cp == 0x09DC || cp == 0x09DD || cp == 0x0B94) then none
  else ShapeData.decompose cp

/-- The shaper-specific composition (`compose` callbacks). -/
def shaperCompose (sh : Shaper) (hasGposMark : Bool) (a b : Nat) : Option Nat :=
  if sh == .indic then
    let gc := ShapeData.genCat a
    if gc == 10 || gc == 11 || gc == 12 then none
    else if a == 0x09AF && b == 0x09BC then some 0x09DF
    else ShapeData.compose a b
  else if sh == .hebrew then
    match ShapeData.compose a b with
    | some c => some c
    | none =>
      if hasGposMark then none
      else
        -- presentation forms old fonts want (harfrust `compose` in the Hebrew shaper)
        let dagesh : Array Nat := #[0xFB30, 0xFB31, 0xFB32, 0xFB33, 0xFB34, 0xFB35, 0xFB36, 0, 0xFB38,
          0xFB39, 0xFB3A, 0xFB3B, 0xFB3C, 0, 0xFB3E, 0, 0xFB40, 0xFB41, 0, 0xFB43, 0xFB44, 0, 0xFB46,
          0xFB47, 0xFB48, 0xFB49, 0xFB4A]
        let r : Nat := match b with
          | 0x05B4 => if a == 0x05D9 then 0xFB1D else 0
          | 0x05B7 => if a == 0x05D9 then 0xFB1F else if a == 0x05D0 then 0xFB2E else 0
          | 0x05B8 => if a == 0x05D0 then 0xFB2F else 0
          | 0x05B9 => if a == 0x05D5 then 0xFB4B else 0
          | 0x05BC => if 0x05D0 ≤ a && a ≤ 0x05EA then dagesh.getD (a - 0x05D0) 0
                      else if a == 0xFB2A then 0xFB2C else if a == 0xFB2B then 0xFB2D else 0
          | 0x05BF => if a == 0x05D1 then 0xFB4C else if a == 0x05DB then 0xFB4D
                      else if a == 0x05E4 then 0xFB4E else 0
          | 0x05C1 => if a == 0x05E9 then 0xFB2A else if a == 0xFB49 then 0xFB2C else 0
          | 0x05C2 => if a == 0x05E9 then 0xFB2B else if a == 0xFB49 then 0xFB2D else 0
          | _ => 0
        if r == 0 then none else some r
  else ShapeData.compose a b

/-- `decompose`: output the full decomposition of `ab` (recursively on its
first part) if the font can draw it; the number of characters output. -/
def decomposeChar (f : Font) (sh : Shaper) (shortest : Bool) : Nat → Nat → M Nat
  | 0, _ => pure 0
  | fuel + 1, ab => do
    match shaperDecompose sh ab with
    | none => return 0
    | some (a, b) =>
      let aG := nominal f a
      let bG := if b != 0 then nominal f b else none
      if b != 0 && bG.isNone then return 0
      let out := fun (c g : Nat) => modify fun s =>
        if s.out.size ≥ s.maxLen then { s with ok := false }
        else { s with out := s.out.push (charInfo c s.cur g) }
      match aG with
      | some ag =>
        if shortest then
          out a ag
          match bG with
          | some bg => out b bg; return 2
          | none => return 1
      | none => pure ()
      let ret ← decomposeChar f sh shortest fuel a
      if ret != 0 then
        match bG with
        | some bg => out b bg; return ret + 1
        | none => return ret
      match aG with
      | some ag =>
        out a ag
        match bG with
        | some bg => out b bg; return 2
        | none => return 1
      | none => return 0

/-- `decompose_current_character`. -/
def decomposeCurrent (f : Font) (sh : Shaper) (shortest : Bool) : M Unit := do
  let s ← get
  let u := s.cur.cp
  let g := nominal f u
  let setNext := fun (gl : Nat) => do
    setCur { (← get).cur with ngid := gl }
    nextGlyph
  match g with
  | some gl => if shortest then setNext gl; return
  | none => pure ()
  if (← decomposeChar f sh shortest 8 u) > 0 then skipGlyph; return
  match g with
  | some gl => setNext gl; return
  | none => pure ()
  -- space fallback: any Zs character becomes the space glyph
  if s.cur.gc == 29 then
    match nominal f 0x20 with
    | some sp => setNext sp; return
    | none => pure ()
  if u == 0x2011 then
    match nominal f 0x2010 with
    | some h => setNext h; return
    | none => pure ()
  setNext 0

/-- `_hb_ot_shape_normalize`. -/
def normalize (f : Font) (sh : Shaper) (hasGposMark : Bool) : M Unit := do
  if (← get).len == 0 then return
  let noShort := sh == .indic
  let mightShort := !noShort
  clearOutput
  let count := (← get).len
  let mut allSimple := true
  for _ in [0:count + 1] do
    let s ← get
    if s.idx ≥ count || !s.ok then break
    let mut stop := s.idx + 1
    for _ in [0:count] do
      if stop < count && !(s.info.getD stop default).isUnicodeMark then stop := stop + 1 else break
    if stop < count then stop := stop - 1
    if mightShort then
      let mut done := 0
      for k in [0:stop - s.idx] do
        match nominal f (s.cur k).cp with
        | some g =>
          modify fun st => { st with info := st.info.setIfInBounds (st.idx + k) { st.cur k with ngid := g } }
          done := done + 1
        | none => break
      nextGlyphs done
    for _ in [0:count] do
      let st ← get
      if st.idx < stop && st.ok then decomposeCurrent f sh mightShort else break
    let st ← get
    if st.idx ≥ count || !st.ok then break
    allSimple := false
    let mut e := st.idx + 1
    for _ in [0:count] do
      if e < count && (st.info.getD e default).isUnicodeMark then e := e + 1 else break
    -- `decompose_multi_char_cluster` (variation selectors are not special-cased)
    for _ in [0:count] do
      let st ← get
      if st.idx < e && st.ok then decomposeCurrent f sh false else break
  sync
  if !allSimple then
    -- reorder marks by modified combining class
    let count := (← get).len
    let mut i := 0
    for _ in [0:count] do
      if i ≥ count then break
      let s ← get
      if (s.info.getD i default).ccc == 0 then i := i + 1; continue
      let mut e := i + 1
      for _ in [0:count] do
        if e < count && (s.info.getD e default).ccc != 0 then e := e + 1 else break
      if e - i ≤ 32 then
        sortByCcc i e
        if sh == .arabic then reorderMarksArabic i e
        if sh == .hebrew then reorderMarksHebrew i e
      i := e + 1
    -- recompose
    if (← get).ok then
      clearOutput
      let count := (← get).len
      let mut starter := 0
      nextGlyph
      for _ in [0:count] do
        let s ← get
        if s.idx ≥ count || !s.ok then break
        let c := s.cur
        let prevCcc := (s.out.getD (s.out.size - 1) default).ccc
        if c.isUnicodeMark && (starter + 1 == s.out.size || prevCcc < c.ccc) then
          let a := (s.out.getD starter default).cp
          match shaperCompose sh hasGposMark a c.cp with
          | some comp =>
            match nominal f comp with
            | some g =>
              nextGlyph
              mergeOutClusters starter (← get).out.size
              modify fun st =>
                let st := { st with out := st.out.pop }
                let o := st.out.getD starter default
                { st with out := st.out.setIfInBounds starter (charInfo comp o g) }
              continue
            | none => pure ()
          | none => pure ()
        nextGlyph
        let s2 ← get
        if (s2.out.getD (s2.out.size - 1) default).ccc == 0 then starter := s2.out.size - 1
      sync
where
  /-- `buffer.sort` by combining class (insertion sort merging clusters). -/
  sortByCcc (start stop : Nat) : M Unit := do
    for i in [start + 1:stop] do
      let s ← get
      let x := s.info.getD i default
      let mut j := i
      for _ in [start:i] do
        if j > start && (s.info.getD (j - 1) default).ccc > x.ccc then j := j - 1 else break
      if i == j then continue
      mergeClusters j (i + 1)
      modify fun st => Id.run do
        let x := st.info.getD i default
        let mut info := st.info
        for k in [0:i - j] do
          info := info.setIfInBounds (i - k) (info.getD (i - k - 1) default)
        info := info.setIfInBounds j x
        return { st with info := info }
  /-- `reorder_marks_arabic`. -/
  reorderMarksArabic (start0 stop : Nat) : M Unit := do
    let mut start := start0
    let mut i := start
    for cc in [220, 230] do
      let s ← get
      for _ in [i:stop] do
        if i < stop && (s.info.getD i default).ccc < cc then i := i + 1 else break
      if i == stop then break
      if (s.info.getD i default).ccc > cc then continue
      let mut j := i
      for _ in [i:stop] do
        let g := s.info.getD j default
        if j < stop && g.ccc == cc && modifierCombiningMarks.contains g.cp then j := j + 1 else break
      if i == j then continue
      mergeClusters start j
      let st ← get
      let moved := st.info.extract i j
      let before := st.info.extract start i
      let mut info := st.info
      for k in [0:moved.size] do info := info.setIfInBounds (start + k) (moved.getD k default)
      for k in [0:before.size] do info := info.setIfInBounds (start + moved.size + k) (before.getD k default)
      let newStart := start + (j - i)
      let newCc := if cc == 220 then 25 else 26   -- modified CCC22 / CCC26
      for k in [start:newStart] do info := info.setIfInBounds k { info.getD k default with ccc := newCc }
      set { st with info := info }
      start := newStart
      i := j
  /-- `reorder_marks_hebrew`. -/
  reorderMarksHebrew (start stop : Nat) : M Unit := do
    for i in [start + 2:stop] do
      let s ← get
      let c0 := (s.info.getD (i - 2) default).ccc
      let c1 := (s.info.getD (i - 1) default).ccc
      let c2 := (s.info.getD i default).ccc
      -- modified classes: patah 20, qamats 21, sheva 22, hiriq 23, meteg 25
      if (c0 == 20 || c0 == 21) && (c1 == 22 || c1 == 23) && (c2 == 25 || c2 == 220) then
        mergeClusters (i - 1) (i + 1)
        modify fun st =>
          let a := st.info.getD (i - 1) default
          let b := st.info.getD i default
          { st with info := (st.info.setIfInBounds (i - 1) b).setIfInBounds i a }
        break

/-! ## Indic (Devanagari configuration) -/

namespace Indic

-- categories (`ot_category_t`)
def cX := 0
def cC := 1
def cV := 2
def cN := 3
def cH := 4
def cZWNJ := 5
def cZWJ := 6
def cM := 7
def cSM := 8
def cA := 9
def cPlaceholder := 10
def cDottedCircle := 11
def cRS := 12
def cMPst := 13
def cRepha := 14
def cRa := 15
def cCM := 16
def cSymbol := 17
def cCS := 18
def cSMPst := 57

-- positions (`ot_position_t`)
def pStart := 0
def pRaToBecomeReph := 1
def pPreM := 2
def pPreC := 3
def pBaseC := 4
def pAfterMain := 5
def pAboveC := 6
def pBeforeSub := 7
def pBelowC := 8
def pAfterSub := 9
def pBeforePost := 10
def pPostC := 11
def pAfterPost := 12
def pSMVD := 13
def pEnd := 14

def isOneOf (g : GInfo) (cats : List Nat) : Bool := !g.ligated && cats.contains g.cat
def isJoiner (g : GInfo) : Bool := isOneOf g [cZWJ, cZWNJ]
def isConsonant (g : GInfo) : Bool :=
  isOneOf g [cC, cCS, cRa, cCM, cV, cPlaceholder, cDottedCircle]
def isHalant (g : GInfo) : Bool := isOneOf g [cH]

/-- A regular expression over categories, for the syllable grammar. -/
inductive Re where
  | sym (cats : List Nat)
  | seq (a b : Re)
  | alt (a b : Re)
  | star (a : Re)
  | opt (a : Re)

/-- Sorted, duplicate-free union. -/
def union (a b : Array Nat) : Array Nat := Id.run do
  let mut out := a
  for x in b do if !out.contains x then out := out.push x
  return out.qsort (· < ·)

/-- The positions reachable by matching `r` from any position in `from`
over the category string `cs`. -/
def step (cs : Array Nat) : Re → Array Nat → Array Nat
  | .sym cats, fr => fr.filterMap (fun i => if i < cs.size && cats.contains (cs.getD i 0) then some (i + 1) else none)
  | .seq a b, fr => step cs b (step cs a fr)
  | .alt a b, fr => union (step cs a fr) (step cs b fr)
  | .opt a, fr => union fr (step cs a fr)
  | .star a, fr => Id.run do
    let mut r := fr
    for _ in [0:cs.size + 1] do
      let r2 := union r (step cs a r)
      if r2.size == r.size then break
      r := r2
    return r

open Re in
/-- harfrust's `indic_syllable_machine`, as regular expressions. -/
def grammar : Array (Re × Nat) :=
  let s := fun (l : List Nat) => sym l
  let c := s [cC, cRa]
  let n := seq (opt (seq (opt (s [cZWNJ])) (s [cRS]))) (opt (seq (s [cN]) (opt (s [cN]))))
  let z := s [cZWJ, cZWNJ]
  let reph := alt (seq (s [cRa]) (s [cH])) (s [cRepha])
  let sm := s [cSM, cSMPst]
  let cn := seq c (seq (opt (s [cZWJ])) (opt n))
  let symbol := seq (s [cSymbol]) (opt (s [cN]))
  let matraGroup := seq (star z) (seq (alt (s [cM]) (seq (opt sm) (s [cMPst])))
    (seq (opt (s [cN])) (opt (s [cH]))))
  let syllableTail := seq (opt (seq (opt z) (seq sm (seq (opt sm) (opt (s [cZWNJ]))))))
    (star (s [cA]))
  let halantGroup := seq (opt z) (seq (s [cH]) (opt (seq (s [cZWJ]) (opt (s [cN])))))
  let finalHalantGroup := alt halantGroup (seq (s [cH]) (s [cZWNJ]))
  let medialGroup := opt (s [cCM])
  let halantOrMatraGroup := alt finalHalantGroup (star matraGroup)
  let complexTail := seq (star (seq halantGroup cn))
    (seq medialGroup (seq halantOrMatraGroup syllableTail))
  let consonantSyllable := seq (opt (s [cRepha, cCS])) (seq cn complexTail)
  let vowelSyllable := seq (opt reph) (seq (s [cV]) (seq (opt n) (alt (s [cZWJ]) complexTail)))
  let standalone := seq (alt (seq (opt (s [cRepha, cCS])) (s [cPlaceholder]))
    (seq (opt reph) (s [cDottedCircle]))) (seq (opt n) complexTail)
  let symbolCluster := seq symbol syllableTail
  let broken := seq (opt reph) (seq (opt n) complexTail)
  #[(consonantSyllable, 0), (vowelSyllable, 1), (standalone, 2), (symbolCluster, 3),
    (s [cSMPst], 5), (broken, 4)]

/-- `find_syllables_indic`: each glyph's `syl` becomes
`serial << 4 | syllable type` (0 consonant, 1 vowel, 2 standalone,
3 symbol, 4 broken, 5 non-Indic); whether a broken cluster was seen. -/
def findSyllables (info : Array GInfo) : Array GInfo × Bool := Id.run do
  let cs := info.map (·.cat)
  let mut out := info
  let mut p := 0
  let mut serial := 1
  let mut broken := false
  for _ in [0:info.size] do
    if p ≥ info.size then break
    -- Ragel's longest match; on a tie the rule listed first wins, and
    -- `other` (any single glyph, a non-Indic cluster) comes last
    let mut best := 0
    let mut kind := 5
    for (r, k) in grammar do
      let e := (step cs r #[p]).foldl Nat.max p
      if e - p > best then best := e - p; kind := k
    if best == 0 then best := 1; kind := 5
    for i in [p:p + best] do out := out.setIfInBounds i { out.getD i default with syl := serial * 16 + kind }
    if kind == 4 then broken := true
    serial := if serial == 15 then 1 else serial + 1
    p := p + best
  return (out, broken)

end Indic

/-! ## `would_apply` (Indic's `would_substitute`) -/

/-- Whether GSUB lookup `li` would apply to exactly `glyphs` (harfrust's
`WouldApply`, `zero_context` false). -/
def wouldApply (l : Layout) (li : Nat) (glyphs : Array Nat) : Bool := Id.run do
  let bs := l.bs
  let lo := l.lookupOff false li
  let typ := u16 bs lo
  let g0 := glyphs.getD 0 0
  let n := glyphs.size
  for k in [0:u16 bs (lo + 4)] do
    let (t, off) := resolveExt l false typ (lo + u16 bs (lo + 6 + 2 * k))
    let covered := fun (c gid : Nat) => (cov l (off + c) gid).isSome
    let r : Bool :=
      if t == 1 || t == 2 || t == 3 || t == 8 then n == 1 && covered (u16 bs (off + 2)) g0
      else if t == 4 then
        match cov l (off + u16 bs (off + 2)) g0 with
        | none => false
        | some ix => Id.run do
          let set := off + u16 bs (off + 6 + 2 * ix)
          for m in [0:u16 bs set] do
            let lig := set + u16 bs (set + 2 + 2 * m)
            let cc := u16 bs (lig + 2)
            if n == cc && (List.range (cc - 1)).all (fun i => u16 bs (lig + 4 + 2 * i) == glyphs.getD (i + 1) 0) then
              return true
          return false
      else if t == 5 || t == 6 then
        let chain := t == 6
        let fmt := u16 bs off
        let rd := if chain then readChainRule bs else readRule bs
        let ruleMatches := fun (rule : Rule) (f : Nat → Nat → Bool) =>
          n == rule.input.size + 1 && (List.range rule.input.size).all (fun i => f (rule.input.getD i 0) (glyphs.getD (i + 1) 0))
        if fmt == 1 then
          match cov l (off + u16 bs (off + 2)) g0 with
          | none => false
          | some ix => Id.run do
            if ix ≥ u16 bs (off + 4) then return false
            let set := off + u16 bs (off + 6 + 2 * ix)
            for m in [0:u16 bs set] do
              if ruleMatches (rd (set + u16 bs (set + 2 + 2 * m))) (fun v gid => gid == v) then return true
            return false
        else if fmt == 2 then Id.run do
          if (cov l (off + u16 bs (off + 2)) g0).isNone then return false
          let cdOff := if chain then u16 bs (off + 6) else u16 bs (off + 4)
          let cd := if cdOff == 0 then 0 else off + cdOff
          let nsets := if chain then u16 bs (off + 10) else u16 bs (off + 6)
          let setsAt := if chain then off + 12 else off + 8
          let c := cls l cd g0
          if c ≥ nsets then return false
          let so := u16 bs (setsAt + 2 * c)
          if so == 0 then return false
          let set := off + so
          for m in [0:u16 bs set] do
            if ruleMatches (rd (set + u16 bs (set + 2 + 2 * m))) (fun v gid => cls l cd gid == v) then return true
          return false
        else if fmt == 3 then
          if chain then
            let bc := u16 bs (off + 2)
            let iAt := off + 4 + 2 * bc
            let ic := u16 bs iAt
            covered (u16 bs (iAt + 2)) g0 && n == ic &&
              (List.range (ic - 1)).all (fun i => covered (u16 bs (iAt + 4 + 2 * i)) (glyphs.getD (i + 1) 0))
          else
            let gc := u16 bs (off + 2)
            covered (u16 bs (off + 6)) g0 && n == gc + 1 &&
              (List.range gc).all (fun i => covered (u16 bs (off + 6 + 2 * i)) (glyphs.getD (i + 1) 0))
        else false
      else false
    if r then return true
  return false

/-- Whether any lookup of GSUB stage `stage` would apply to `glyphs`. -/
def wouldSubstitute (plan : Plan) (l : Layout) (stage : Option Nat) (glyphs : Array Nat) : Bool :=
  match stage with
  | none => false
  | some st => ((plan.gsub.getD st (#[], .none)).1).any (fun m => wouldApply l m.index glyphs)

/-- The GSUB stage feature `t` was declared in, if the map kept it. -/
def featureStage (plan : Plan) (t : Nat) : Option Nat :=
  (plan.masks.find? (·.1 == t)).map (·.2.2)

/-! ## Indic reordering -/

namespace Indic

/-- What the Indic pauses need from the plan (`IndicShapePlan`). -/
structure Cfg where
  plan : Plan
  lay : Layout
  font : Font
  oldSpec : Bool
  rphf : Nat
  half : Nat
  blwf : Nat
  abvf : Nat
  pstf : Nat
  pref : Nat
  init : Nat
  virama : Option Nat

def Cfg.would (c : Cfg) (feat : String) (glyphs : Array Nat) : Bool :=
  wouldSubstitute c.plan c.lay (featureStage c.plan (tag feat)) glyphs

/-- `consonant_position_from_face`. -/
def consonantPosition (c : Cfg) (cons virama : Nat) : Nat :=
  if c.would "blwf" #[virama, cons] || c.would "blwf" #[cons, virama] ||
     c.would "vatu" #[virama, cons] || c.would "vatu" #[cons, virama] then pBelowC
  else if c.would "pstf" #[virama, cons] || c.would "pstf" #[cons, virama] then pPostC
  else if c.would "pref" #[virama, cons] || c.would "pref" #[cons, virama] then pPostC
  else pBaseC

/-- The end of the syllable starting at `start`. -/
def nextSyllable (info : Array GInfo) (start : Nat) : Nat := Id.run do
  if start ≥ info.size then return start
  let syl := (info.getD start default).syl
  let mut e := start + 1
  for _ in [start + 1:info.size] do
    if e < info.size && (info.getD e default).syl == syl then e := e + 1 else break
  return e

def getI (i : Nat) : M GInfo := do return (← get).info.getD i default
def setI (i : Nat) (g : GInfo) : M Unit := modify fun s => { s with info := s.info.setIfInBounds i g }
def modI (i : Nat) (f : GInfo → GInfo) : M Unit := do setI i (f (← getI i))

/-- Reverse `info[a, b)`. -/
def reverseRange (a b : Nat) : M Unit := modify fun s => Id.run do
  let mut info := s.info
  if b < a + 2 then return s
  for k in [0:(b - a) / 2] do
    let x := info.getD (a + k) default
    let y := info.getD (b - 1 - k) default
    info := (info.setIfInBounds (a + k) y).setIfInBounds (b - 1 - k) x
  return { s with info := info }

/-- Move `info[src]` to `dst` shifting what lies between. -/
def moveGlyph (src dst : Nat) : M Unit := modify fun s => Id.run do
  let x := s.info.getD src default
  let mut info := s.info
  if src < dst then
    for k in [src:dst] do info := info.setIfInBounds k (info.getD (k + 1) default)
  else if dst < src then
    for k in [0:src - dst] do info := info.setIfInBounds (src - k) (info.getD (src - k - 1) default)
  info := info.setIfInBounds dst x
  return { s with info := info }

/-- `initial_reordering_consonant_syllable` (new-spec Devanagari: implicit reph
before post-base, below-base forms before and after the base). -/
def initialReorderingSyllable (c : Cfg) (start stop : Nat) : M Unit := do
  let ty := (← getI start).syl % 16
  if ty == 3 || ty == 5 || stop ≤ start then return
  let mut base := stop
  let mut hasReph := false
  let mut limit := start
  if c.rphf != 0 && start + 3 ≤ stop && !isJoiner (← getI (start + 2)) then
    if c.would "rphf" #[(← getI start).gid, (← getI (start + 1)).gid] then
      limit := limit + 2
      for _ in [limit:stop] do
        if limit < stop && isJoiner (← getI limit) then limit := limit + 1 else break
      base := start
      hasReph := true
  -- find the base consonant
  let mut i := stop
  let mut seenBelow := false
  for _ in [start:stop] do
    i := i - 1
    let g ← getI i
    if isConsonant g then
      if g.ipos != pBelowC && (g.ipos != pPostC || seenBelow) then
        base := i; break
      if g.ipos == pBelowC then seenBelow := true
      base := i
    else if start < i && g.cat == cZWJ && (← getI (i - 1)).cat == cH then break
    if i ≤ limit then break
  if hasReph && base == start && limit - base ≤ 2 then hasReph := false
  for k in [start:base] do modI k fun g => { g with ipos := Nat.min pPreC g.ipos }
  if base < stop then modI base fun g => { g with ipos := pBaseC }
  if hasReph then modI start fun g => { g with ipos := pRaToBecomeReph }
  -- attach misc marks to the previous character
  let mut lastPos := pStart
  for k in [start:stop] do
    let g ← getI k
    if [cZWJ, cZWNJ, cN, cRS, cCM, cH].contains g.cat then
      setI k { g with ipos := lastPos }
      if g.cat == cH && lastPos == pPreM then
        for m in [0:k - start] do
          let j := k - m
          let pj := (← getI (j - 1)).ipos
          if pj != pPreM then modI k fun g => { g with ipos := pj }; break
    else if g.ipos != pSMVD then
      if g.cat == cMPst && k > start && (← getI (k - 1)).cat == cSM then
        modI (k - 1) fun h => { h with ipos := g.ipos }
      lastPos := g.ipos
  -- post-base consonants own what precedes them since the last consonant or matra
  let mut last := base
  for k in [base + 1:stop] do
    let g ← getI k
    if isConsonant g then
      for j in [last + 1:k] do
        if (← getI j).ipos < pSMVD then modI j fun h => { h with ipos := g.ipos }
      last := k
    else if g.cat == cM || g.cat == cMPst then last := k
  -- sort by position (stable), remembering each glyph's old index in `syl`
  let syl := (← getI start).syl
  for k in [start:stop] do modI k fun g => { g with syl := k - start }
  modify fun s => Id.run do
    let mut info := s.info
    for k in [start + 1:stop] do
      let x := info.getD k default
      let mut j := k
      for _ in [start:k] do
        if j > start && (info.getD (j - 1) default).ipos > x.ipos then
          info := info.setIfInBounds j (info.getD (j - 1) default)
          j := j - 1
        else break
      info := info.setIfInBounds j x
    return { s with info := info }
  let mut firstLeft := stop
  let mut lastLeft := stop
  base := stop
  for k in [start:stop] do
    let g ← getI k
    if g.ipos == pBaseC then base := k; break
    else if g.ipos == pPreM then
      if firstLeft == stop then firstLeft := k
      lastLeft := k
  if firstLeft < lastLeft then
    reverseRange firstLeft (lastLeft + 1)
    let mut a := firstLeft
    for j in [firstLeft:lastLeft + 1] do
      let g ← getI j
      if g.cat == cM || g.cat == cMPst then
        reverseRange a (j + 1)
        a := j + 1
  if c.oldSpec || stop - start > 127 then mergeClusters base stop
  else
    for k in [base:stop] do
      if (← getI k).syl != 255 then
        let mut mn := k
        let mut mx := k
        let mut j := start + (← getI k).syl
        for _ in [start:stop + 1] do
          if j == k then break
          mn := Nat.min mn j
          mx := Nat.max mx j
          let nxt := start + (← getI j).syl
          modI j fun g => { g with syl := 255 }
          j := nxt
        mergeClusters (Nat.max base mn) (mx + 1)
  for k in [start:stop] do modI k fun g => { g with syl := syl }
  -- masks
  for k in [start:stop] do
    if (← getI k).ipos != pRaToBecomeReph then break
    modI k fun g => { g with mask := g.mask ||| c.rphf }
  let pre := c.half ||| (if !c.oldSpec then c.blwf else 0)
  for k in [start:base] do modI k fun g => { g with mask := g.mask ||| pre }
  let post := c.blwf ||| c.abvf ||| c.pstf
  for k in [base + 1:stop] do modI k fun g => { g with mask := g.mask ||| post }
  if c.pref != 0 && base + 2 < stop then
    for k in [base + 1:stop - 1] do
      if c.would "pref" #[(← getI k).gid, (← getI (k + 1)).gid] then
        modI k fun g => { g with mask := g.mask ||| c.pref }
        modI (k + 1) fun g => { g with mask := g.mask ||| c.pref }
        break
  -- ZWNJ stops half forms of the preceding consonant cluster
  for k in [start + 1:stop] do
    let g ← getI k
    if isJoiner g then
      let nonJoiner := g.cat == cZWNJ
      let mut j := k
      for _ in [start:k] do
        j := j - 1
        if nonJoiner then modI j fun h => { h with mask := h.mask - (h.mask &&& c.half) }
        if j ≤ start || isConsonant (← getI j) then break

/-- `final_reordering_impl` (Devanagari: reph before post-base forms). -/
def finalReorderingSyllable (c : Cfg) (start stop : Nat) : M Unit := do
  if stop ≤ start then return
  match c.virama with
  | some v =>
    for k in [start:stop] do
      let g ← getI k
      if g.gid == v && g.ligated && g.multiplied then
        setI k { g with cat := cH, gprops := g.gprops - (g.gprops &&& 0x60) }
  | none => pure ()
  let mut base := start
  for _ in [start:stop] do
    if base ≥ stop then break
    if (← getI base).ipos ≥ pBaseC then
      if start < base && (← getI base).ipos > pBaseC then base := base - 1
      break
    base := base + 1
  if base == stop && start < base && isOneOf (← getI (base - 1)) [cZWJ] then base := base - 1
  if base < stop then
    for _ in [start:base] do
      if start < base && isOneOf (← getI base) [cN, cH] then base := base - 1 else break
  -- pre-base matras move after the last remaining halant before the base
  if start + 1 < stop && start < base then
    let mut newPos := if base == stop then base - 2 else base - 1
    for _ in [start:stop] do
      for _ in [start:stop] do
        if newPos > start && !isOneOf (← getI newPos) [cM, cMPst, cH] then newPos := newPos - 1 else break
      let g ← getI newPos
      if isHalant g && g.ipos != pPreM then
        if newPos + 1 < stop && (← getI (newPos + 1)).cat == cZWJ && newPos > start then
          newPos := newPos - 1; continue
      else newPos := start
      break
    if start < newPos && (← getI newPos).ipos != pPreM then
      let top := newPos
      for m in [0:top - start] do
        let i := top - m
        if (← getI (i - 1)).ipos == pPreM then
          let oldPos := i - 1
          if oldPos < base && base ≤ newPos then base := base - 1
          moveGlyph oldPos newPos
          mergeClusters newPos (Nat.min stop (base + 1))
          newPos := newPos - 1
    else
      for k in [start:base] do
        if (← getI k).ipos == pPreM then
          mergeClusters k (Nat.min stop (base + 1)); break
  -- reph
  let g0 ← getI start
  if start + 1 < stop && g0.ipos == pRaToBecomeReph && ((g0.cat == cRepha) != g0.ligatedAndDidntMultiply) then
    let mut newReph := start + 1
    let mut found := false
    for _ in [start:base] do
      if newReph < base && !isHalant (← getI newReph) then newReph := newReph + 1 else break
    if newReph < base && isHalant (← getI newReph) then
      if newReph + 1 < base && isJoiner (← getI (newReph + 1)) then newReph := newReph + 1
      found := true
    if !found then
      newReph := stop - 1
      for _ in [start:stop] do
        if newReph > start && (← getI newReph).ipos == pSMVD then newReph := newReph - 1 else break
      if isHalant (← getI newReph) then
        let mut n := newReph
        for k in [base + 1:newReph] do
          let g ← getI k
          if g.cat == cM || g.cat == cMPst then n := n - 1
        newReph := n
    mergeClusters start (newReph + 1)
    moveGlyph start newReph
    if start < base && base ≤ newReph then base := base - 1
  if c.init != 0 && (← getI start).ipos == pPreM then
    let prevGc := (← getI (start - 1)).gc
    if start == 0 || !(1 ≤ prevGc && prevGc ≤ 12) then modI start fun g => { g with mask := g.mask ||| c.init }

/-- `insert_dotted_circles` for broken clusters. -/
def insertDottedCircles (c : Cfg) : M Unit := do
  let s ← get
  if !s.info.any (fun g => g.syl % 16 == 4) then return
  match nominal c.font 0x25CC with
  | none => return
  | some dc =>
    clearOutput
    let mut lastSyl := 0
    -- each step either copies a glyph or inserts one circle before a syllable
    for _ in [0:2 * s.len + 1] do
      let st ← get
      if st.idx ≥ st.len then break
      let syl := st.cur.syl
      if lastSyl != syl && syl % 16 == 4 then
        lastSyl := syl
        let cur := st.cur
        let ginfo : GInfo := { gid := dc, cp := 0x25CC, cat := cDottedCircle, ipos := pEnd,
                                cluster := cur.cluster, mask := cur.mask, syl := syl }
        for _ in [0:st.len] do
          let st ← get
          if st.idx < st.len && lastSyl == st.cur.syl && st.cur.cat == cRepha then nextGlyph else break
        modify fun st => { st with out := st.out.push ginfo }
      else nextGlyph
    sync

/-- The Indic pauses. -/
def runPause (c : Cfg) : Pause → M Unit
  | .indicSetupSyllables => modify fun s => { s with info := (findSyllables s.info).1 }
  | .indicInitial => do
    match c.virama with
    | some v =>
      modify fun s => { s with info := s.info.map fun g =>
        if g.ipos == pBaseC then { g with ipos := consonantPosition c g.gid v } else g }
    | none => pure ()
    insertDottedCircles c
    let n := (← get).len
    let mut start := 0
    for _ in [0:n + 1] do
      let info := (← get).info
      if start ≥ info.size then break
      let e := nextSyllable info start
      initialReorderingSyllable c start e
      start := e
  | .indicFinal => do
    let n := (← get).len
    let mut start := 0
    for _ in [0:n + 1] do
      let info := (← get).info
      if start ≥ info.size then break
      let e := nextSyllable info start
      finalReorderingSyllable c start e
      start := e
  | .clearSyllables => modify fun s => { s with info := s.info.map fun g => { g with syl := 0 } }
  | .none => pure ()

/-- `preprocess_text_vowel_constraints` for Devanagari: a dotted circle
between an independent vowel and a sign that would make it look like another
vowel. -/
def vowelConstraints (info : Array GInfo) : Array GInfo := Id.run do
  let mut out : Array GInfo := #[]
  let mut i := 0
  let dotted := fun (g : GInfo) => { g with cp := 0x25CC, uflags := g.uflags - (g.uflags &&& 0x80) }
  for _ in [0:info.size + 1] do
    if i + 1 ≥ info.size then break
    let a := (info.getD i default).cp
    let b := (info.getD (i + 1) default).cp
    let matched :=
      (a == 0x0905 && [0x093A, 0x093B, 0x093E, 0x0945, 0x0946, 0x0949, 0x094A, 0x094B, 0x094C, 0x094F,
        0x0956, 0x0957].contains b) ||
      (a == 0x0906 && [0x093A, 0x0945, 0x0946, 0x0947, 0x0948].contains b) ||
      (a == 0x0909 && b == 0x0941) || (a == 0x090F && [0x0945, 0x0946, 0x0947].contains b)
    if a == 0x0930 && b == 0x094D && i + 2 < info.size && (info.getD (i + 2) default).cp == 0x0907 then
      out := out.push (info.getD i default)
      out := out.push (info.getD (i + 1) default)
      out := out.push (dotted (info.getD (i + 2) default))
      i := i + 2
    out := out.push (info.getD i default)
    i := i + 1
    if matched then
      out := out.push (dotted (info.getD i default))
      out := out.push (info.getD i default)
      i := i + 1
  return out ++ info.extract i info.size

end Indic

/-! ## Shaping a run -/

/-- One shaped glyph: its id, the character index (in the run) of its
cluster, and its advance and offsets in font units. -/
structure Glyph where
  gid : Nat
  cluster : Nat
  xAdv : Int
  xOff : Int
  yOff : Int
deriving Inhabited, Repr, BEq

/-- `propagate_attachment_offsets` for glyph `i` (fuel-bounded chain). -/
def propagate (rtl : Bool) : Nat → Array GPos → Nat → Array GPos
  | 0, pos, _ => pos
  | fuel + 1, pos, i =>
    let p := pos.getD i default
    let chain := p.chain
    let kind := p.atype
    let pos := pos.setIfInBounds i { p with chain := 0 }
    let jI : Int := (i : Int) + chain
    if jI < 0 || jI.toNat ≥ pos.size then pos
    else
      let j := jI.toNat
      let pos := if (pos.getD j default).chain != 0 then propagate rtl fuel pos j else pos
      let pj := pos.getD j default
      let p := pos.getD i default
      if kind == 1 then Id.run do
        let mut p := { p with xOff := p.xOff + pj.xOff, yOff := p.yOff + pj.yOff }
        if j < i then
          if !rtl then
            for k in [j:i] do p := { p with xOff := p.xOff - (pos.getD k default).xAdv }
          else
            for k in [j + 1:i + 1] do p := { p with xOff := p.xOff + (pos.getD k default).xAdv }
        else
          if !rtl then
            for k in [i:j] do p := { p with xOff := p.xOff + (pos.getD k default).xAdv }
          else
            for k in [i + 1:j + 1] do p := { p with xOff := p.xOff - (pos.getD k default).xAdv }
        return pos.setIfInBounds i p
      else if kind == 2 then pos.setIfInBounds i { p with yOff := p.yOff + pj.yOff }
      else pos

/-- Shape one bidi run of `cps` with font `f` (whose layout tables are `l`)
in direction `rtl`, as harfrust does for usvg.  `kerning = false` is
`font-kerning: none`, `smallCaps` is `font-variant: small-caps` (the font's
`smcp` feature, T97). Glyphs come out in visual (left-to-right) order. -/
def shapeRun (f : Font) (l : Layout) (cps : Array Nat) (rtl kerning : Bool) (smallCaps : Bool := false) :
    Array Glyph := Id.run do
  let n := cps.size
  if n == 0 then return #[]
  let iso := guessScript cps
  let tags := otScriptTags iso
  let gsubScript := ((l.selectScript false tags).map (·.2)).getD 0
  let sh := pickShaper iso gsubScript
  let plan := compilePlan l tags (buildFeatures l tags sh iso rtl kerning smallCaps)
  -- the buffer
  let mut info : Array GInfo := Array.emptyWithCapacity n
  for i in [0:n] do
    let cp := cps.getD i 0
    let (gc, ccc, fl) := unicodeProps cp
    info := info.push { cp := cp, cluster := i, mask := plan.globalMask, gc := gc, ccc := ccc, uflags := fl }
  -- `set_unicode_props`' extra grapheme continuations
  for i in [0:n] do
    let g := info.getD i default
    let cp := g.cp
    let cont := (g.gc == 24 && 0x1F3FB ≤ cp && cp ≤ 0x1F3FF) || cp == 0x200D ||
      (0xFF9E ≤ cp && cp ≤ 0xFF9F) || (0xE0020 ≤ cp && cp ≤ 0xE007F) ||
      (i != 0 && 0x1F1E6 ≤ cp && cp ≤ 0x1F1FF && 0x1F1E6 ≤ (info.getD (i - 1) default).cp &&
        (info.getD (i - 1) default).cp ≤ 0x1F1FF && !(info.getD (i - 1) default).isContinuation)
    if cp ≥ 0x80 && cont then info := info.setIfInBounds i { g with uflags := g.uflags ||| 0x80 }
  let mut st : St := { lay := l, info := info, maxLen := maxLenFor n, ops := opsFor n }
  -- `form_clusters`: graphemes share their first character's cluster
  st := (do
    let len := (← get).len
    let mut start := 0
    for _ in [0:len + 1] do
      if start ≥ len then break
      let inf := (← get).info
      let mut e := start + 1
      for _ in [0:len] do
        if e < len && (inf.getD e default).isContinuation then e := e + 1 else break
      mergeClusters start e
      start := e
    : M Unit).run st |>.2
  -- `ensure_native_direction`
  let mut dirRtl := rtl
  let mut hor := scriptRtl iso
  if hor == some true && !rtl then
    let mut foundNumber := false
    let mut foundLetter := false
    for g in st.info do
      if g.gc == 13 then foundNumber := true
      else if [5, 6, 7, 8, 9].contains g.gc then foundLetter := true; break
      else if 0x1F1E6 ≤ g.cp && g.cp ≤ 0x1F1FF then foundNumber := true
    if foundNumber && !foundLetter then hor := some false
  match hor with
  | some h =>
    if h != dirRtl then
      -- reverse graphemes (clusters stay; each grapheme's order is kept)
      let mut groups : Array (Array GInfo) := #[]
      for g in st.info do
        if g.isContinuation && groups.size > 0 then
          groups := groups.setIfInBounds (groups.size - 1) ((groups.getD (groups.size - 1) #[]).push g)
        else groups := groups.push #[g]
      st := { st with info := groups.reverse.foldl (· ++ ·) #[] }
      dirRtl := !dirRtl
  | none => pure ()
  st := { st with rtl := dirRtl }
  -- `preprocess_text`
  if sh == .indic && iso == "Deva" then st := { st with info := Indic.vowelConstraints st.info }
  -- `rotate_chars`: mirroring
  if rtl then
    let rtlm := plan.mask1 (tag "rtlm")
    st := { st with info := st.info.map fun g =>
      match Bidi.mirror g.cp with
      | some m => if (nominal f m).isSome then { g with cp := m } else { g with mask := g.mask ||| rtlm }
      | none => { g with mask := g.mask ||| rtlm } }
  let hasGposMark := plan.mask1 (tag "mark") != 0
  st := ((normalize f sh hasGposMark : M Unit).run st).2
  -- `setup_masks`
  if sh == .arabic then st := { st with info := arabicMasks plan st.info }
  if sh == .indic then
    st := { st with info := st.info.map fun g =>
      let (c, p) := ShapeData.indicCatPos g.cp
      { g with cat := c, ipos := p } }
  -- map glyphs, then GDEF classes (`hb_ot_layout_substitute_start`)
  st := { st with info := st.info.map fun g =>
    let gid := g.ngid
    let props := if l.hasClasses then l.glyphProps gid
      else if g.gc != 12 || g.isIgnorable then 2 else 8
    { g with gid := gid, gprops := props, lig := 0 } }
  -- GSUB
  let cfg : Indic.Cfg := {
    plan := plan, lay := l, font := f, oldSpec := gsubScript % 256 != 0x32,
    rphf := plan.mask1 (tag "rphf"), half := plan.mask1 (tag "half"), blwf := plan.mask1 (tag "blwf"),
    abvf := plan.mask1 (tag "abvf"), pstf := plan.mask1 (tag "pstf"), pref := plan.mask1 (tag "pref"),
    init := if sh == .indic then plan.mask1 (tag "init") else 0,
    virama := nominal f 0x094D }
  if l.gsub != 0 then
    st := { st with isGpos := false }
    for (lookups, p) in plan.gsub do
      st := ((do for m in lookups do applyString m) : M Unit).run st |>.2
      st := (Indic.runPause cfg p).run st |>.2
  else
    for (_, p) in plan.gsub do st := (Indic.runPause cfg p).run st |>.2
  -- positions
  let applyGpos := l.gpos != 0 && (sh != .hebrew || plan.gposScript == tag "hebr")
  st := { st with isGpos := true, haveOutput := false, out := #[], idx := 0,
                  pos := st.info.map fun g => { xAdv := (Font.advance f g.gid : Int) } }
  if applyGpos then
    for m in plan.gpos do st := (applyString m).run st |>.2
  else if kerning then
    -- the legacy `kern` table between adjacent glyphs
    let mut pos := st.pos
    for i in [0:st.len - 1] do
      let k := Font.kern f (st.info.getD i default).gid (st.info.getD (i + 1) default).gid
      if k != 0 then pos := pos.setIfInBounds i { pos.getD i default with xAdv := (pos.getD i default).xAdv + k }
    st := { st with pos := pos }
  -- zero-width marks (all shapers here but Indic), default ignorables
  let adjust := !applyGpos && !dirRtl
  let mut pos := st.pos
  for i in [0:st.len] do
    let g := st.info.getD i default
    let p := pos.getD i default
    if sh != .indic && g.isMark then
      pos := pos.setIfInBounds i { p with xAdv := 0, xOff := if adjust then p.xOff - p.xAdv else p.xOff }
    if g.isIgnorable then pos := pos.setIfInBounds i { (pos.getD i default) with xAdv := 0, xOff := 0 }
  -- attachment offsets
  let len := st.len
  for k in [0:len] do
    let i := if dirRtl then len - 1 - k else k
    if (pos.getD i default).chain != 0 then pos := propagate dirRtl maxNesting pos i
  let mut gs := st.info
  if dirRtl then
    gs := gs.reverse
    pos := pos.reverse
  -- default ignorables become the space glyph (or are dropped)
  match nominal f 0x20 with
  | some sp => gs := gs.map fun g => if g.isIgnorable then { g with gid := sp } else g
  | none =>
    let keep := (List.range gs.size).filter (fun i => !(gs.getD i default).isIgnorable)
    gs := keep.toArray.map (gs.getD · default)
    pos := keep.toArray.map (pos.getD · default)
  return (List.range gs.size).toArray.map fun i =>
    let g := gs.getD i default
    let p := pos.getD i default
    { gid := g.gid, cluster := g.cluster, xAdv := p.xAdv, xOff := p.xOff, yOff := p.yOff }

end Shape
end LeanSvg
