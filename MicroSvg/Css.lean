import MicroSvg.Bytes

/-!
# A `simplecss`-subset CSS parser and selector matcher

Mirrors the CSS 2.1 subset supported by the `simplecss` crate
(<https://github.com/linebender/simplecss>, `src/lib.rs` and `src/selector.rs`),
which is what usvg/resvg use for `<style>` elements:

* Comments `/* ... */` are stripped first; an unterminated comment drops the
  rest of the sheet (never fatal).
* `@`-rules are skipped wholesale: to the next `;`, or by matching braces if
  they have a block (nesting depth capped at 32 — a safety margin, since the
  scan itself is a flat counter and always terminates on the input size
  regardless of how deep the counter reports).
* A rule is a comma-separated selector list plus a declaration block.  Each
  comma item becomes its own `Rule` sharing the same declarations, exactly as
  `simplecss` expands them before sorting by specificity — this is what makes
  "apply `resolve`'s output in order, last write wins" reproduce the cascade.
* Selectors support type/`*`, `#id`, `.class`, `[attr]`, `[attr=v]`,
  `[attr~=v]`, `[attr|=v]` (the four operators `simplecss::AttributeOperator`
  has — `^=`/`$=`/`*=` are not in its grammar, so a selector using one is
  parsed structurally but never matches), `:first-child` (any other
  pseudo-class never matches), and the descendant/child/adjacent-sibling
  combinators.  Our match chain is ancestors-only (no sibling links), so an
  adjacent-sibling selector can never be evaluated and never matches either —
  the same "unsupported feature ⇒ never matches, still total" fallback.

Every scan below is a `for` loop over a range fixed before the loop starts
(the input length, or a small constant), so `parseStylesheet` is total: no
recursion, no partial functions, and no input — however malformed, however
large — can make it loop unboundedly or crash.  `matches` is a bounded
dynamic-programming scan (component count × chain length, ≤ 32 × 64) rather
than the backtracking recursion `simplecss` itself uses, for the same reason.
-/

namespace MicroSvg
namespace Css

open Bytes

deriving instance Repr for ByteArray

/-! ## Data model -/

inductive AttrOp where
  | exists_
  | eq (v : String)
  | contains (v : String)        -- `~=`: one of the space-separated words
  | startsWithDash (v : String)  -- `|=`: exactly `v`, or `v` followed by `-`
deriving Repr, BEq, Inhabited

structure Compound where
  hasType : Bool := false
  typeName : String := ""
  id : Option String := none
  classes : Array String := #[]
  attrs : Array (String × AttrOp) := #[]
  firstChild : Bool := false
  /-- `false` once the compound used a feature outside the supported subset
  (an unsupported attribute operator or pseudo-class).  Such a selector is
  parsed structurally (so the rest of the sheet still parses normally) but
  never matches anything. -/
  valid : Bool := true
deriving Repr, BEq, Inhabited

inductive Combinator where
  | descendant
  | child
  | adjacent
deriving Repr, BEq, Inhabited

structure Component where
  /-- Combinator connecting this compound to the previous (leftward) one.
  Meaningless for `components[0]`, which has none. -/
  comb : Combinator := .descendant
  comp : Compound := {}
deriving Repr, BEq, Inhabited

structure Selector where
  /-- Leftmost compound first, target (rightmost) compound last. -/
  components : Array Component := #[]
  valid : Bool := true
deriving Repr, BEq, Inhabited

structure Decl where
  name : String := ""
  value : ByteArray := ByteArray.empty
  important : Bool := false
deriving Repr, BEq, Inhabited

structure Rule where
  selector : Selector := {}
  decls : Array Decl := #[]
  sourceOrder : Nat := 0
deriving Repr, BEq, Inhabited

structure ElemInfo where
  tag : String
  id : String
  classes : Array String
  attrs : Array (String × String)
  isFirstChild : Bool
deriving Repr, BEq, Inhabited

/-! ## Small bounded byte-scanning helpers (local to this module) -/

/-- First position in `[i0, limit)` where `pred` holds, or `limit`. -/
def scanFor (bs : ByteArray) (i0 limit : Nat) (pred : UInt8 → Bool) : Nat := Id.run do
  let mut i := i0
  for _ in [i0:limit] do
    if i ≥ limit then break
    if pred (at' bs i) then return i
    i := i + 1
  return limit

/-- Last occurrence of `c` in `bs`, or `none`. -/
def lastIndexOf (bs : ByteArray) (c : UInt8) : Option Nat := Id.run do
  let mut found : Option Nat := none
  for k in [0:bs.size] do
    if at' bs k == c then found := some k
  return found

def isIdentStart (c : UInt8) : Bool := isAlpha c || c == 45 || c == 95   -- '-' '_'
def isIdentChar (c : UInt8) : Bool := isAlpha c || isDigit c || c == 45 || c == 95

/-- Whitespace-separated tokens (drops empty pieces), for `class="a  b"`. -/
def splitWs (s : String) : Array String := Id.run do
  let mut out : Array String := #[]
  let mut cur : String := ""
  for c in s.toList do
    if c.isWhitespace then
      if cur.length > 0 then
        out := out.push cur
        cur := ""
    else
      cur := cur.push c
  if cur.length > 0 then out := out.push cur
  return out

/-- Remove `/* ... */` comments.  An unterminated comment drops the rest of
the sheet, matching the task's stated policy exactly (not `simplecss`'s own
per-token comment skipping, which is equivalent for well-formed input and
simpler to make total here). -/
def stripComments (src : ByteArray) : ByteArray := Id.run do
  let n := src.size
  let mut out := ByteArray.emptyWithCapacity n
  let mut i := 0
  for _ in [0:n + 1] do
    if i ≥ n then break
    if at' src i == 47 && at' src (i + 1) == 42 then      -- "/*"
      let close := findSeq src (i + 2) "*/"
      if close ≥ n then i := n else i := close + 2
    else
      out := out.push (at' src i)
      i := i + 1
  return out

/-- Skip a `{ ... }` block whose opening brace has already been consumed
(`i0` points right after it).  Nesting is a flat counter capped at 32 — the
cap is purely defensive (the scan is bounded by `limit` either way and always
terminates); on pathologically deep nesting it may treat a later `}` as the
close, leaving stray bytes for the caller to skip past harmlessly (never a
crash, never a hang, matching "malformed input is skipped, never fatal"). -/
def skipBlock (src : ByteArray) (i0 limit : Nat) : Nat := Id.run do
  let mut depth : Nat := 0
  let mut i := i0
  for _ in [i0:limit] do
    if i ≥ limit then break
    let c := at' src i
    if c == 123 then                 -- '{'
      depth := Nat.min 32 (depth + 1)
      i := i + 1
    else if c == 125 then            -- '}'
      if depth == 0 then return i + 1
      depth := depth - 1
      i := i + 1
    else
      i := i + 1
  return limit

/-- Skip one `@`-rule: to the next `;`, or a matched block if it has one. -/
def skipAtRule (src : ByteArray) (i0 limit : Nat) : Nat :=
  let stop := scanFor src i0 limit (fun c => c == 59 || c == 123)
  if stop ≥ limit then limit
  else if at' src stop == 59 then stop + 1
  else skipBlock src (stop + 1) limit

/-! ## Selectors -/

/-- `[attr...]`, `i0` right after the `[`.  `none` on anything outside the
supported grammar (including `^=`, `$=`, `*=`, which `simplecss` itself does
not parse either). -/
def parseAttrSelector (bs : ByteArray) (i0 limit : Nat) : Option (String × AttrOp × Nat) := Id.run do
  let i1 := skipWs bs i0
  if i1 ≥ limit then return none
  let e := skipWhile bs i1 isIdentChar
  if e == i1 then return none
  let name := toStr (bs.extract i1 e)
  let i2 := skipWs bs e
  if i2 ≥ limit then return none
  if at' bs i2 == 93 then return some (name, .exists_, i2 + 1)     -- ']'
  let (kind, opLen) :=
    if at' bs i2 == 61 then (some 0, 1)                            -- '='
    else if at' bs i2 == 126 && at' bs (i2 + 1) == 61 then (some 1, 2)   -- '~='
    else if at' bs i2 == 124 && at' bs (i2 + 1) == 61 then (some 2, 2)   -- '|='
    else (none, 0)
  match kind with
  | none => return none
  | some k =>
    let i3 := skipWs bs (i2 + opLen)
    if i3 ≥ limit then return none
    let (value, i4) : (String × Nat) ←
      if at' bs i3 == 34 || at' bs i3 == 39 then
        let q := at' bs i3
        let close := scanFor bs (i3 + 1) limit (· == q)
        if close ≥ limit then return none
        pure (toStr (bs.extract (i3 + 1) close), close + 1)
      else
        let e2 := skipWhile bs i3 isIdentChar
        if e2 == i3 then return none
        pure (toStr (bs.extract i3 e2), e2)
    let i5 := skipWs bs i4
    if i5 ≥ limit || at' bs i5 != 93 then return none
    let op := match k with
      | 0 => AttrOp.eq value
      | 1 => AttrOp.contains value
      | _ => AttrOp.startsWithDash value
    return some (name, op, i5 + 1)

/-- `:name` or `:name(arg)`, `i0` right after the `:`.  Returns
`(supported, nextPos)`; an unrecognised ident is still consumed structurally
(so parsing of the rest of the selector/sheet stays in sync) but marks the
compound unmatchable. `none` only for a hard syntax error (no ident, or an
unterminated `(...)`). -/
def parsePseudoClass (bs : ByteArray) (i0 limit : Nat) : Option (Bool × Nat) := Id.run do
  let e := skipWhile bs i0 isIdentChar
  if e == i0 then return none
  let name := bs.extract i0 e
  let mut i := e
  if i < limit && at' bs i == 40 then          -- '(' — e.g. `:lang(en)`
    let close := scanFor bs (i + 1) limit (· == 41)
    if close ≥ limit then return none
    i := close + 1
  return some (eqAscii name "first-child", i)

/-- One compound selector starting at `i0`, stopping at the first byte that
is not part of it (whitespace, combinator, `,`, `{`, or `limit`).  The `Bool`
is `false` on a hard parse failure (caller should abandon the whole
selector). -/
def parseCompound (bs : ByteArray) (i0 limit : Nat) : (Compound × Nat × Bool) := Id.run do
  let mut i := i0
  let mut comp : Compound := {}
  let mut saw := false
  if i < limit && at' bs i == 42 then          -- '*'
    i := i + 1
    saw := true
  else if i < limit && isIdentStart (at' bs i) then
    let e := skipWhile bs i isIdentChar
    comp := { comp with hasType := true, typeName := toStr (bs.extract i e) }
    i := e
    saw := true
  for _ in [0:64] do
    if i ≥ limit then break
    let c := at' bs i
    if c == 35 then                            -- '#'
      let e := skipWhile bs (i + 1) isIdentChar
      if e == i + 1 then return (comp, i, false)
      comp := { comp with id := some (toStr (bs.extract (i + 1) e)) }
      i := e
      saw := true
    else if c == 46 then                       -- '.'
      let e := skipWhile bs (i + 1) isIdentChar
      if e == i + 1 then return (comp, i, false)
      comp := { comp with classes := comp.classes.push (toStr (bs.extract (i + 1) e)) }
      i := e
      saw := true
    else if c == 91 then                       -- '['
      match parseAttrSelector bs (i + 1) limit with
      | some (name, op, next) =>
        comp := { comp with attrs := comp.attrs.push (name, op) }
        i := next
        saw := true
      | none => return (comp, i, false)
    else if c == 58 then                       -- ':'
      match parsePseudoClass bs (i + 1) limit with
      | some (supported, next) =>
        if supported then comp := { comp with firstChild := true }
        else comp := { comp with valid := false }
        i := next
        saw := true
      | none => return (comp, i, false)
    else
      break
  return (comp, i, saw)

/-- One selector spanning `[start, limit)` (already isolated from its
neighbours by the caller — `limit` is a `,` or the block's `{`).  Never
fails: a hard parse error, or more than 32 compounds, just marks the whole
selector `valid := false` and stops. -/
def parseSelector (bs : ByteArray) (start limit : Nat) : Selector := Id.run do
  let mut i := start
  let mut components : Array Component := #[]
  let mut valid := true
  for _ in [0:32] do
    if i ≥ limit then break
    i := skipWs bs i
    if i ≥ limit then break
    let mut comb := Combinator.descendant
    if components.size > 0 then
      if at' bs i == 62 then                   -- '>'
        comb := .child
        i := skipWs bs (i + 1)
      else if at' bs i == 43 then               -- '+'
        comb := .adjacent
        i := skipWs bs (i + 1)
      -- else: the whitespace already skipped above *is* the descendant combinator
      if i ≥ limit then
        valid := false
        i := limit
        break
    let (compound, next, ok) := parseCompound bs i limit
    if !ok then
      valid := false
      i := limit
      break
    if !compound.valid then valid := false
    components := components.push { comb, comp := compound }
    i := next
  if i < limit then valid := false             -- more than 32 compounds
  if components.size == 0 then valid := false
  return { components, valid }

/-! ## Declarations -/

/-- `raw`, trimmed, with a trailing `!important` (case-sensitive, exactly
like `simplecss`) split off. -/
def splitImportant (raw : ByteArray) : (ByteArray × Bool) :=
  let t := trim raw
  match lastIndexOf t 33 with                  -- '!'
  | none => (t, false)
  | some p =>
    let after := trim (t.extract (p + 1) t.size)
    if eqAscii after "important" then (trim (t.extract 0 p), true) else (t, false)

/-- End of a declaration's value: the first unquoted `;` or `}`, skipping
over `'...'`/`"..."` (so a value like `url("a;b")` keeps its semicolon). -/
def scanValueEnd (src : ByteArray) (i0 limit : Nat) : Nat := Id.run do
  let mut i := i0
  for _ in [i0:limit] do
    if i ≥ limit then break
    let c := at' src i
    if c == 39 || c == 34 then
      let close := scanFor src (i + 1) limit (· == c)
      i := if close ≥ limit then limit else close + 1
    else if c == 59 || c == 125 then
      return i
    else
      i := i + 1
  return limit

/-- Skip forward to (and past) a declaration block's closing `}`, tolerating
nested braces (bounded, see `skipBlock`).  Used to recover from a malformed
declaration, exactly where `simplecss::consume_until_block_end` is used. -/
def skipToBlockEnd (src : ByteArray) (i0 limit : Nat) : Nat := Id.run do
  let mut depth : Nat := 0
  let mut i := i0
  for _ in [i0:limit] do
    if i ≥ limit then break
    let c := at' src i
    if c == 123 then
      depth := Nat.min 32 (depth + 1)
      i := i + 1
    else if c == 125 then
      if depth == 0 then return i + 1
      depth := depth - 1
      i := i + 1
    else
      i := i + 1
  return limit

/-- Declarations in `[i0, limit)`, stopping cleanly at `}` (consumed) or
`limit`.  Any malformed declaration ends the block early, matching
`simplecss`'s "stop at the first invalid token". -/
def parseDeclarations (src : ByteArray) (i0 limit : Nat) : (Array Decl × Nat) := Id.run do
  let mut i := i0
  let mut decls : Array Decl := #[]
  for _ in [0:limit - i0 + 1] do
    if i ≥ limit then break
    i := skipWs src i
    if i ≥ limit then break
    if at' src i == 125 then
      i := i + 1
      break
    let ne := skipWhile src i isIdentChar
    if ne == i then
      i := skipToBlockEnd src i limit
      break
    let name := toStr (lower (src.extract i ne))
    let j := skipWs src ne
    if j ≥ limit || at' src j != 58 then
      i := skipToBlockEnd src i limit
      break
    let j2 := skipWs src (j + 1)
    let valEnd := scanValueEnd src j2 limit
    let (value, important) := splitImportant (src.extract j2 valEnd)
    if value.size == 0 then
      i := skipToBlockEnd src i limit
      break
    decls := decls.push { name, value, important }
    -- consume the terminating ';' (there may be several / none before '}')
    i := if valEnd < limit && at' src valEnd == 59 then valEnd + 1 else valEnd
  return (decls, i)

/-! ## Stylesheet -/

def maxRules : Nat := 10000

/-- Parse a stylesheet.  Total for any input: comments are stripped first,
every subsequent scan is bounded by the (fixed) remaining length, and rule
creation stops once `maxRules` is reached. -/
def parseStylesheet (src0 : ByteArray) : Array Rule := Id.run do
  let src := stripComments src0
  let n := src.size
  let mut i := 0
  let mut rules : Array Rule := #[]
  let mut sourceOrder := 0
  for _ in [0:n + 1] do
    if i ≥ n then break
    let i1 := skipWs src i
    if i1 ≥ n then break
    if at' src i1 == 64 then                   -- '@'
      i := skipAtRule src (i1 + 1) n
    else
      let selEnd := scanFor src i1 n (· == 123)
      if selEnd ≥ n then
        i := n
      else
        if rules.size ≥ maxRules then
          -- global cap reached: still skip this rule-set's block correctly
          -- so a later `@`-rule (if any) still parses, but stop expanding
          -- comma items into new rules.
          let (_, afterBlock) := parseDeclarations src (selEnd + 1) n
          i := afterBlock
        else
          let mut selectors : Array Selector := #[]
          let mut segStart := i1
          for _ in [0:1024] do
            if rules.size + selectors.size ≥ maxRules then break
            let segEnd := scanFor src segStart selEnd (· == 44)
            selectors := selectors.push (parseSelector src segStart segEnd)
            if segEnd ≥ selEnd then break
            segStart := segEnd + 1
          let (decls, afterBlock) := parseDeclarations src (selEnd + 1) n
          if decls.size > 0 then
            for sel in selectors do
              if rules.size < maxRules then
                rules := rules.push { selector := sel, decls, sourceOrder }
          sourceOrder := sourceOrder + 1
          i := afterBlock
  -- Sort ascending by (ids, classes+attrs+pseudos, types), then source order.
  -- Encoding `sourceOrder` in the comparator makes every pair a strict order
  -- (no true ties), so any correct sort — `Array.qsort` need not be stable —
  -- reproduces "apply in order, last write wins" faithfully.
  let specOf := fun (r : Rule) => Id.run do
    let mut ids := 0
    let mut classes := 0
    let mut types := 0
    for comp in r.selector.components do
      if comp.comp.hasType then types := types + 1
      if comp.comp.id.isSome then ids := ids + 1
      classes := classes + comp.comp.classes.size + comp.comp.attrs.size
      if comp.comp.firstChild then classes := classes + 1
    return (ids, classes, types)
  return rules.qsort (fun a b =>
    let (ai, ac, at_) := specOf a
    let (bi, bc, bt) := specOf b
    if ai != bi then ai < bi
    else if ac != bc then ac < bc
    else if at_ != bt then at_ < bt
    else a.sourceOrder < b.sourceOrder)

/-! ## Matching -/

def attrOpMatches (op : AttrOp) (v : Option String) : Bool :=
  match op, v with
  | .exists_, some _ => true
  | .eq val, some v => v == val
  | .contains val, some v => (splitWs v).contains val
  | .startsWithDash val, some v =>
    v == val || (val.isPrefixOf v && (v.drop val.length).take 1 == "-")
  | _, none => false

def compoundMatches (c : Compound) (e : ElemInfo) : Bool :=
  c.valid &&
  (!c.hasType || c.typeName == e.tag) &&
  (match c.id with | some i => e.id == i | none => true) &&
  c.classes.all (fun cl => e.classes.contains cl) &&
  c.attrs.all (fun (n, op) => attrOpMatches op ((e.attrs.find? (fun a => a.1 == n)).map (·.2))) &&
  (!c.firstChild || e.isFirstChild)

/-- Bounded DP over (component index, chain index) — see the module doc for
why this replaces the natural backtracking recursion. `chain` is ancestors
(root first) followed by the element itself. -/
-- Named with guillemets: `matches` is a reserved term-level keyword in Lean 4
-- (`e matches pat`), so the spec's API name can only be spelled `«matches»`.
def «matches» (sel : Selector) (chain : Array ElemInfo) : Bool := Id.run do
  if !sel.valid then return false
  let m := sel.components.size
  let n := chain.size
  if m == 0 || n == 0 then return false
  let lastComp := (sel.components.getD (m - 1) {}).comp
  let mut reach : Array Bool := Array.replicate n false
  if compoundMatches lastComp (chain.getD (n - 1) default) then
    reach := reach.setIfInBounds (n - 1) true
  for step in [0:m - 1] do
    let k := m - 1 - step                       -- m-1, m-2, ..., 1
    let comb := (sel.components.getD k {}).comb
    let leftComp := (sel.components.getD (k - 1) {}).comp
    let mut newReach : Array Bool := Array.replicate n false
    match comb with
    | .descendant =>
      let mut maxI : Int := -1
      for idx in [0:n] do
        if reach.getD idx false && (idx : Int) > maxI then maxI := idx
      if maxI ≥ 0 then
        for j in [0:n] do
          if (j : Int) < maxI && compoundMatches leftComp (chain.getD j default) then
            newReach := newReach.setIfInBounds j true
    | .child =>
      for idx in [0:n] do
        if reach.getD idx false && idx ≥ 1 then
          let j := idx - 1
          if compoundMatches leftComp (chain.getD j default) then
            newReach := newReach.setIfInBounds j true
    | .adjacent =>
      pure ()   -- no sibling info in `chain`: never matches (see module doc)
    reach := newReach
  for idx in [0:n] do
    if reach.getD idx false then return true
  return false

/-- All declarations from rules whose selector matches `chain`, split into
non-important and important groups, each in rule order (rules are already
sorted by specificity then source order by `parseStylesheet`, so this order
already encodes "apply in sequence, last write wins" within each group). -/
def matchingDeclsSplit (rules : Array Rule) (chain : Array ElemInfo) :
    (Array (String × ByteArray) × Array (String × ByteArray)) := Id.run do
  let mut normal : Array (String × ByteArray) := #[]
  let mut important : Array (String × ByteArray) := #[]
  for rule in rules do
    if «matches» rule.selector chain then
      for d in rule.decls do
        if d.important then important := important.push (d.name, d.value)
        else normal := normal.push (d.name, d.value)
  return (normal, important)

/-- Winning declarations in application order: non-important (by specificity,
then source order) followed by important (same order) — `!important` above
all non-important declarations, exactly as the spec requires. -/
def resolve (rules : Array Rule) (chain : Array ElemInfo) : Array (String × ByteArray) :=
  let (normal, important) := matchingDeclsSplit rules chain
  normal ++ important

/-- Build an `ElemInfo` for one element from its (already string-decoded)
attributes. -/
def buildElemInfo (tag : String) (attrs : Array (String × String)) (isFirstChild : Bool) : ElemInfo :=
  let id := (attrs.find? (fun a => a.1 == "id")).map (·.2) |>.getD ""
  let classes := match attrs.find? (fun a => a.1 == "class") with
    | some (_, v) => splitWs v
    | none => #[]
  { tag, id, classes, attrs, isFirstChild }

end Css
end MicroSvg
