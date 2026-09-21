import LeanSvg.Bytes

/-!
# Micro XML parser

A deliberately small XML reader that produces a flat list of open/close events.
It is *not* a conforming XML parser, and that is the point:

* No DTD internal subset.  `<!DOCTYPE ...>` is skipped only when it has no `[`.
  This removes entity expansion attacks (billion laughs) and external entities
  (XXE) by construction; there is no code path that could expand an entity.
* Only the five predefined entities and numeric character references are decoded.
* Text content, comments, processing instructions and CDATA are skipped, never
  interpreted.
* Nesting depth is capped at `maxDepth` and element count at `maxElements`
  (the same cap librsvg uses).
* Every loop is bounded by the input size.
-/

namespace LeanSvg
namespace Xml

open Bytes

structure Attr where
  name : String
  value : ByteArray
deriving Inhabited

inductive Event where
  | open_ (name : String) (attrs : Array Attr)
  | close
  /-- Character data between tags, or the contents of a `<![CDATA[ ... ]]>`
  section.  Added for `<style>` (T29): its CSS text has to reach `interpret`
  somehow, and neither plain text nor CDATA was delivered as an event before.
  Every other consumer of `Event` simply ignores this constructor, so nothing
  about existing element/attribute handling changes. -/
  | text (bytes : ByteArray)
deriving Inhabited

def maxDepth : Nat := 64
def maxElements : Nat := 1000000

/-- Local part of a possibly prefixed name (`svg:rect` → `rect`). -/
def localName (bs : ByteArray) : String :=
  let i := findByte bs 0 58
  let part := if i < bs.size then bs.extract (i + 1) bs.size else bs
  toStr part

/-- Parse `#NNN;` / `#xHHH;` (without the `&` and `;`). -/
def parseCharRef (name : ByteArray) : Except String Nat := do
  let hex := at' name 1 == 120 || at' name 1 == 88
  let start := if hex then 2 else 1
  if start ≥ name.size then throw "empty character reference"
  let mut v : Nat := 0
  for k in [start:name.size] do
    let c := at' name k
    let d ←
      if isDigit c then pure (c.toNat - 48)
      else if hex && 97 ≤ c && c ≤ 102 then pure (c.toNat - 87)
      else if hex && 65 ≤ c && c ≤ 70 then pure (c.toNat - 55)
      else throw "malformed character reference"
    v := v * (if hex then 16 else 10) + d
    if v > 0x10FFFF then throw "character reference out of range"
  return v

/-- Decode an attribute value.  Unknown entities are an error, never expanded. -/
def decodeValue (bs : ByteArray) (b e : Nat) : Except String ByteArray := do
  let mut out := ByteArray.emptyWithCapacity (e - b)
  let mut i := b
  for _ in [b:e] do
    if i ≥ e then break
    let c := at' bs i
    if c == 38 then
      let semi := findByte bs (i + 1) 59
      if semi ≥ e then throw "unterminated entity reference"
      let name := bs.extract (i + 1) semi
      if eqAscii name "lt" then out := out.push 60
      else if eqAscii name "gt" then out := out.push 62
      else if eqAscii name "amp" then out := out.push 38
      else if eqAscii name "quot" then out := out.push 34
      else if eqAscii name "apos" then out := out.push 39
      else if at' name 0 == 35 then
        let cp ← parseCharRef name
        out := out ++ (Char.ofNat cp).toString.toUTF8
      else throw s!"unsupported entity reference &{toStr name};"
      i := semi + 1
    else
      out := out.push c
      i := i + 1
  return out

/-- Decode text content leniently: the five predefined entities and numeric
character references are expanded, exactly like `decodeValue`, but anything
that does not fit that grammar (an unknown entity, or a malformed or
unterminated one) is copied through verbatim instead of failing the parse.

Element text was never inspected at all before T29 (see the module doc), so
making it strict here — reusing `decodeValue` — would turn documents that
used to parse (any stray `&` in a `<title>`/`<desc>`/etc. text run, never
checked before) into parse failures.  Being lenient keeps `<style>` CSS text
decoding real entities while leaving every other element's rendering
byte-for-byte unaffected. -/
def decodeText (bs : ByteArray) (b e : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (e - b)
  let mut i := b
  for _ in [b:e] do
    if i ≥ e then break
    let c := at' bs i
    if c == 38 then
      let semi := findByte bs (i + 1) 59
      if semi ≥ e then
        out := out ++ bs.extract i e
        i := e
      else
        let name := bs.extract (i + 1) semi
        if eqAscii name "lt" then out := out.push 60; i := semi + 1
        else if eqAscii name "gt" then out := out.push 62; i := semi + 1
        else if eqAscii name "amp" then out := out.push 38; i := semi + 1
        else if eqAscii name "quot" then out := out.push 34; i := semi + 1
        else if eqAscii name "apos" then out := out.push 39; i := semi + 1
        else if at' name 0 == 35 then
          match parseCharRef name with
          | .ok cp =>
            out := out ++ (Char.ofNat cp).toString.toUTF8
            i := semi + 1
          | .error _ =>
            out := out.push c
            i := i + 1
        else
          out := out.push c
          i := i + 1
    else
      out := out.push c
      i := i + 1
  return out

/-- Parse a document into events.  Fails on anything outside the accepted subset. -/
def parse (bs : ByteArray) : Except String (Array Event) := do
  let mut events : Array Event := #[]
  let mut stack : Array String := #[]
  let mut i := if at' bs 0 == 0xEF && at' bs 1 == 0xBB && at' bs 2 == 0xBF then 3 else 0
  let mut count := 0
  for _ in [0:bs.size + 1] do
    let textStart := i
    i := findByte bs i 60
    if textStart < i then
      let txt := decodeText bs textStart i
      if txt.size > 0 then events := events.push (.text txt)
    if i ≥ bs.size then break
    if startsWith bs i "<?" then
      let e := findSeq bs (i + 2) "?>"
      if e ≥ bs.size then throw "unterminated processing instruction"
      i := e + 2
    else if startsWith bs i "<!--" then
      let e := findSeq bs (i + 4) "-->"
      if e ≥ bs.size then throw "unterminated comment"
      i := e + 3
    else if startsWith bs i "<![CDATA[" then
      let e := findSeq bs (i + 9) "]]>"
      if e ≥ bs.size then throw "unterminated CDATA section"
      events := events.push (.text (bs.extract (i + 9) e))
      i := e + 3
    else if startsWith bs i "<!DOCTYPE" || startsWith bs i "<!doctype" then
      let mut j := i + 9
      let mut done := false
      for _ in [j:bs.size] do
        let c := at' bs j
        if c == 91 then throw "DTD internal subset is not allowed"
        if c == 62 then
          done := true
          break
        j := j + 1
      if !done then throw "unterminated DOCTYPE"
      i := j + 1
    else if startsWith bs i "<!" then
      throw "unsupported markup declaration"
    else if startsWith bs i "</" then
      let ns := i + 2
      let ne := skipWhile bs ns isNameChar
      if ne == ns then throw "malformed end tag"
      let name := localName (bs.extract ns ne)
      let j := skipWs bs ne
      if at' bs j != 62 then throw "malformed end tag"
      match stack.back? with
      | none => throw "unexpected end tag"
      | some top =>
        if top != name then throw s!"mismatched end tag </{name}>, expected </{top}>"
      stack := stack.pop
      events := events.push .close
      i := j + 1
    else
      let ns := i + 1
      let ne := skipWhile bs ns isNameChar
      if ne == ns then throw "malformed start tag"
      let name := localName (bs.extract ns ne)
      let mut attrs : Array Attr := #[]
      let mut j := ne
      let mut selfClose := false
      let mut closed := false
      for _ in [ne:bs.size] do
        j := skipWs bs j
        let c := at' bs j
        if c == 47 then
          if at' bs (j + 1) != 62 then throw "malformed self-closing tag"
          selfClose := true
          closed := true
          j := j + 2
          break
        else if c == 62 then
          closed := true
          j := j + 1
          break
        else if isNameChar c then
          let ae := skipWhile bs j isNameChar
          let aname := toStr (bs.extract j ae)
          let k := skipWs bs ae
          if at' bs k != 61 then throw s!"attribute {aname} has no value"
          let k := skipWs bs (k + 1)
          let q := at' bs k
          if q != 34 && q != 39 then throw s!"attribute {aname} value must be quoted"
          let ve := findByte bs (k + 1) q
          if ve ≥ bs.size then throw s!"unterminated value for attribute {aname}"
          let v ← decodeValue bs (k + 1) ve
          attrs := attrs.push ⟨aname, v⟩
          j := ve + 1
        else
          throw s!"malformed start tag <{name}>"
      if !closed then throw s!"unterminated start tag <{name}>"
      count := count + 1
      if count > maxElements then throw "too many elements"
      if stack.size ≥ maxDepth then throw "elements nested too deeply"
      events := events.push (.open_ name attrs)
      if selfClose then events := events.push .close
      else stack := stack.push name
      i := j
  if stack.size != 0 then throw s!"unclosed element <{stack.back?.getD ""}>"
  -- `count` (not `events.isEmpty`): a tagless document now produces a single
  -- `.text` event (T29 delivers text so `<style>` content is reachable), so
  -- emptiness has to mean "no elements", exactly as before that event
  -- existed, not "no events at all".
  if count == 0 then throw "no elements found"
  return events

end Xml
end LeanSvg
