import LeanSvg.ShapeRun
import LeanSvg.Bidi
import LeanSvg.FontSet

/-!
# Shaping a text chunk (T93)

usvg's `process_chunk` / `shape_text` / `shape_text_with_font`
(`crates/usvg/src/text/layout.rs`) for one text chunk, on top of
`Shape.shapeRun`:

* **Bidi.** The chunk's text is one paragraph (`BidiInfo::new(text,
  Some(level))`); its visual runs are shaped one by one, left-to-right runs
  left to right and right-to-left runs right to left, and their glyphs
  concatenated in visual order.  usvg always passes level 0; `Text.lean` passes
  1 for `direction="rtl"` and a single run for `unicode-bidi="bidi-override"`
  (Chromium's behaviour, where resvg is known wrong).
* **Fallback** (`shape_text`): shape with the span's font; while some glyph
  is `.notdef`, shape the whole text again with the first embedded font (in
  `FontSet` order, not yet tried) that maps that glyph's character: it
  replaces everything if it has no `.notdef` itself, else fills the
  `.notdef`s glyph by glyph when it produced as many glyphs, else stops.
* **Spans** (`process_chunk`): the first span's font shapes the whole chunk;
  every later span's shaping overwrites the glyphs of its own characters,
  cluster by cluster, with usvg's byte-length bookkeeping (a ligature in the
  new font removes the following glyphs, a decomposition inserts).
* **Clusters**: consecutive glyphs with the same byte index.

Glyph records carry usvg's UTF-8 byte indices so that the cluster
bookkeeping is byte-for-byte usvg's; `charOf` maps them back to character
indices.
-/

namespace LeanSvg
namespace ShapeText

/-- One glyph (usvg's `Glyph`): font (`FontSet` index), glyph id, byte index
of its cluster in the chunk text, the cluster's byte length (usvg's
`cluster_len`), offsets and advance in font units. -/
structure SGlyph where
  font : Nat
  gid : Nat
  byteIdx : Nat
  clusterLen : Nat
  dx : Int
  dy : Int
  width : Int
deriving Inhabited, Repr

/-- Fonts parsed on first use, by `FontSet` index. -/
structure Cache where
  fonts : Array (Option Font)
  loaded : Array Bool

def Cache.load (c : Cache) (k : Nat) : Cache :=
  if c.loaded.getD k true then c
  else { fonts := c.fonts.setIfInBounds k ((FontSet.entries[k]?).bind (fun e => e.font ())),
         loaded := c.loaded.setIfInBounds k true }

def Cache.get (c : Cache) (k : Nat) : Option Font := c.fonts.getD k none

/-- UTF-8 length of a codepoint. -/
def utf8Len (cp : Nat) : Nat := if cp < 0x80 then 1 else if cp < 0x800 then 2 else if cp < 0x10000 then 3 else 4

/-- Byte offset of every character, and of the end (`n + 1` entries). -/
def byteOffsets (cps : Array Nat) : Array Nat := Id.run do
  let mut out := Array.emptyWithCapacity (cps.size + 1)
  let mut b := 0
  for cp in cps do
    out := out.push b
    b := b + utf8Len cp
  return out.push b

/-- The character index starting at byte `b` (the last one at or before it). -/
def charOf (offs : Array Nat) (b : Nat) : Nat := Id.run do
  let mut lo := 0
  let mut hi := offs.size
  for _ in [0:40] do
    if hi - lo ≤ 1 then break
    let mid := (lo + hi) / 2
    if offs.getD mid 0 ≤ b then lo := mid else hi := mid
  return lo

/-- `shape_text_with_font`: every visual run shaped in its own direction. -/
def shapeWithFont (f : Font) (fi : Nat) (cps offs : Array Nat) (runs : Array (Nat × Nat × Nat))
    (kerning : Bool) (smallCaps : Bool := false) : Array SGlyph := Id.run do
  let lay := Shape.Layout.ofBytes f.data
  let mut out : Array SGlyph := #[]
  for (s, e, lvl) in runs do
    if e ≤ s then continue
    let ltr := lvl % 2 == 0
    let gs := Shape.shapeRun f lay (cps.extract s e) (!ltr) kerning smallCaps
    let runStart := offs.getD s 0
    let subLen := offs.getD e 0 - runStart
    for i in [0:gs.size] do
      let g := gs.getD i default
      let start := offs.getD (s + g.cluster) 0 - runStart
      let j? : Option Nat := if ltr then (if i + 1 < gs.size then some (i + 1) else none)
        else (if i > 0 then some (i - 1) else none)
      let stop := match j? with
        | some j => offs.getD (s + (gs.getD j default).cluster) 0 - runStart
        | none => subLen
      out := out.push { font := fi, gid := g.gid, byteIdx := runStart + start,
                        clusterLen := if stop ≥ start then stop - start else 0,
                        dx := g.xOff, dy := g.yOff, width := g.xAdv }
  return out

/-- `shape_text`: shaping with font fallback. -/
def shapeText (cache : Cache) (covs : Array (Array (Nat × Nat))) (cps offs : Array Nat)
    (runs : Array (Nat × Nat × Nat)) (base : Nat) (kerning : Bool) (smallCaps : Bool := false) :
    Array SGlyph × Cache := Id.run do
  let mut cache := cache.load base
  let mut glyphs := match cache.get base with
    | some f => shapeWithFont f base cps offs runs kerning smallCaps
    | none => #[]
  let mut used : Array Nat := #[base]
  for _ in [0:covs.size] do
    match glyphs.find? (·.gid == 0) with
    | none => break
    | some g =>
      let c := cps.getD (charOf offs g.byteIdx) 0
      match (List.range covs.size).find? (fun k => !used.contains k && Font.inRanges (covs.getD k #[]) c) with
      | none => break
      | some k =>
        cache := cache.load k
        match cache.get k with
        | none => break
        | some fk =>
          let fb := shapeWithFont fk k cps offs runs kerning smallCaps
          if fb.all (·.gid != 0) then
            glyphs := fb
            break
          if fb.size != glyphs.size then break
          glyphs := (List.range glyphs.size).toArray.map fun i =>
            let old := glyphs.getD i default
            let new := fb.getD i default
            if old.gid == 0 && new.gid != 0 then new else old
          used := used.push k
  return (glyphs, cache)

/-- The runs of an overridden chunk (`unicode-bidi: bidi-override`): every
character at `level`, split where the script changes (Common and Inherited
characters join the run before them), as Chromium itemises before shaping; in
visual order, so reversed for an odd level. -/
def scriptRuns (cps : Array Nat) (level : Nat) : Array (Nat × Nat × Nat) := Id.run do
  let mut runs : Array (Nat × Nat × Nat) := #[]
  let mut cur := ""
  for i in [0:cps.size] do
    let sc := ShapeData.scriptOf (cps.getD i 0)
    let weak := sc == "Zyyy" || sc == "Zinh" || sc == "Zzzz"
    match runs.back? with
    | some (s0, _, l) =>
      if weak || sc == cur || cur == "" then
        runs := runs.setIfInBounds (runs.size - 1) (s0, i + 1, l)
        if !weak then cur := sc
      else
        runs := runs.push (i, i + 1, l)
        cur := sc
    | none =>
      runs := runs.push (i, i + 1, level)
      if !weak then cur := sc
  return if level % 2 == 1 then runs.reverse else runs

/-- `process_chunk`'s span loop.  `spans` are `(first char, end char, base
font, kerning, small caps)` in document order; `paraLevel` and `override` choose the
bidi runs (see the module doc).  Returns the glyphs grouped into clusters, in
visual order, as `(character index of the cluster, glyphs)`. -/
def processChunk (cache : Cache) (covs : Array (Array (Nat × Nat))) (cps : Array Nat)
    (spans : Array (Nat × Nat × Nat × Bool × Bool)) (paraLevel : Nat) (override : Bool) :
    Array (Nat × Array SGlyph) × Cache := Id.run do
  let offs := byteOffsets cps
  let runs := if override then scriptRuns cps paraLevel else Bidi.visualRuns cps paraLevel
  let mut cache := cache
  let mut glyphs : Array SGlyph := #[]
  for (s, e, base, kerning, smallCaps) in spans do
    cache := cache.load base
    if (cache.get base).isNone then continue
    let (tmp, c2) := shapeText cache covs cps offs runs base kerning smallCaps
    cache := c2
    if glyphs.isEmpty then
      glyphs := tmp
      continue
    let bs := offs.getD s 0
    let be := offs.getD e 0
    let mut positions : Array Nat := #[]
    let mut t := 0
    for _ in [0:tmp.size] do
      if t ≥ tmp.size then break
      let ng := tmp.getD t default
      t := t + 1
      if !(bs ≤ ng.byteIdx && ng.byteIdx < be) then continue
      match (List.range glyphs.size).find? (fun i => (glyphs.getD i default).byteIdx == ng.byteIdx) with
      | none => continue
      | some idx =>
        if positions.contains idx then continue
        positions := positions.push idx
        let prev := (glyphs.getD idx default).clusterLen
        if prev < ng.clusterLen then
          for _ in [1:ng.clusterLen] do
            if idx + 1 < glyphs.size then glyphs := glyphs.eraseIdxIfInBounds (idx + 1)
        else if prev > ng.clusterLen then
          for j in [1:prev] do
            if t < tmp.size then
              glyphs := glyphs.insertIdxIfInBounds (idx + j) (tmp.getD t default)
              t := t + 1
        glyphs := glyphs.setIfInBounds idx ng
  -- `GlyphClusters`
  let mut out : Array (Nat × Array SGlyph) := #[]
  let mut i := 0
  for _ in [0:glyphs.size] do
    if i ≥ glyphs.size then break
    let b := (glyphs.getD i default).byteIdx
    let mut j := i + 1
    for _ in [i + 1:glyphs.size] do
      if j < glyphs.size && (glyphs.getD j default).byteIdx == b then j := j + 1 else break
    out := out.push (charOf offs b, glyphs.extract i j)
    i := j
  return (out, cache)

/-- Scripts that take no `letter-spacing` (usvg's
`script_supports_letter_spacing`: CSS Text's cursive scripts). -/
def noLetterSpacing (cp : Nat) : Bool :=
  ["Arab", "Syrc", "Nkoo", "Mani", "Phlp", "Mand", "Mong", "Phag", "Deva", "Beng", "Guru", "Modi",
   "Shrd", "Sylo", "Tirh", "Ogam"].contains (ShapeData.scriptOf cp)

/-- The embedded fonts that keep their GSUB/GPOS for shaping (T93). -/
def isShapedFont (k : Nat) : Bool :=
  match FontSet.entries[k]? with
  | some e => ["Amiri", "Noto Sans Hebrew", "Noto Sans Devanagari"].contains e.family
  | none => false

/-- The Noto Sans faces (T97), which keep `ccmp`, `locl`, `smcp` and
`mark`/`mkmk` besides `kern`. -/
def isNotoSans (k : Nat) : Bool :=
  match FontSet.entries[k]? with
  | some e => e.family == "Noto Sans"
  | none => false

/-- A combining mark (general category Mn, Mc or Me).  Everything below
U+0300 is ruled out before the table lookup, so Latin text pays one
comparison per character. -/
def isMarkChar (cp : Nat) : Bool :=
  cp ≥ 0x300 && (let gc := ShapeData.genCat cp; gc == 10 || gc == 11 || gc == 12)

/-- Whether a chunk needs the shaping path: some character is strongly
right-to-left (or an explicit bidi control), or it is drawn with one of the
fonts that carry GSUB/GPOS shaping, or (T97) a Noto Sans face draws it and it
has a combining mark (GPOS mark attachment) or a `small-caps` span (`smcp`).
Every other chunk keeps the one glyph per character layout, so plain Latin
text is laid out exactly as before T93. -/
def needsShaping (cps : Array Nat) (fontsUsed : Array Nat) (smallCaps : Bool := false) : Bool :=
  fontsUsed.any isShapedFont ||
  (fontsUsed.any isNotoSans && (smallCaps || cps.any isMarkChar)) || cps.any fun cp =>
    match Bidi.bidiClass cp with
    | .R | .AL | .AN | .LRE | .LRO | .RLE | .RLO | .PDF | .LRI | .RLI | .FSI | .PDI => true
    | _ => false

end ShapeText
end LeanSvg
