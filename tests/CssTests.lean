import MicroSvg.Css

/-!
# T29 — CSS parser/matcher tests

Plain `#guard` checks: this file must compile and print nothing under
`lake env lean tests/CssTests.lean` (a failing `#guard` is an elaboration
error, so "compiles cleanly" already means every check below held).
-/

open MicroSvg.Css

def rulesOf (css : String) : Array Rule := parseStylesheet css.toUTF8

/-- The selector of the first rule a one-rule stylesheet produces. -/
def selOf (css : String) : Selector := ((rulesOf css).getD 0 {}).selector

def elemInfo (tag id : String) (classes : Array String := #[])
    (attrs : Array (String × String) := #[]) (isFirstChild : Bool := false) : ElemInfo :=
  { tag, id, classes, attrs, isFirstChild }

/-- `chain` for a lone root element (no ancestors). -/
def solo (e : ElemInfo) : Array ElemInfo := #[e]

/-! ## Comments -/

-- A rule inside a comment never exists.
#guard (rulesOf "/* rect { fill: red; } */").size == 0

-- Comments elsewhere are simply removed, the rule around them still parses.
#guard (rulesOf "/* c */ rect /* c */ { fill: green; } /* c */").size == 1

-- An unterminated comment drops the rest of the sheet (the second rule,
-- after the stray `/*`, never appears).
#guard (rulesOf "rect { fill: green; } /* oops circle { fill: red; }").size == 1

/-! ## `@`-rules -/

-- `@media (...) { ... }` is skipped as an opaque block; only the sibling
-- rule outside it survives.
#guard (rulesOf "@media (min-width: 1px) { rect { fill: red; } } rect { fill: green; }").size == 1

-- `@import "...";` is skipped to the semicolon.
#guard (rulesOf "@import \"x.css\"; rect { fill: green; }").size == 1

/-! ## Selector kinds -/

#guard «matches» (selOf "rect { fill: g }") (solo (elemInfo "rect" ""))
#guard !(«matches» (selOf "rect { fill: g }") (solo (elemInfo "circle" "")))
#guard «matches» (selOf "* { fill: g }") (solo (elemInfo "circle" ""))
#guard «matches» (selOf "#a { fill: g }") (solo (elemInfo "rect" "a"))
#guard !(«matches» (selOf "#a { fill: g }") (solo (elemInfo "rect" "b")))
#guard «matches» (selOf ".fil { fill: g }") (solo (elemInfo "rect" "" #["fil", "other"]))
#guard !(«matches» (selOf ".fil { fill: g }") (solo (elemInfo "rect" "" #["other"])))
#guard «matches» (selOf "[x] { fill: g }") (solo (elemInfo "rect" "" #[] #[("x", "1")]))
#guard !(«matches» (selOf "[x] { fill: g }") (solo (elemInfo "rect" "" #[] #[("y", "1")])))
#guard «matches» (selOf "[x=a] { fill: g }") (solo (elemInfo "rect" "" #[] #[("x", "a")]))
#guard !(«matches» (selOf "[x=a] { fill: g }") (solo (elemInfo "rect" "" #[] #[("x", "b")])))
#guard «matches» (selOf "[x~=b] { fill: g }") (solo (elemInfo "rect" "" #[] #[("x", "a b c")]))
#guard «matches» (selOf "[x|=en] { fill: g }") (solo (elemInfo "rect" "" #[] #[("x", "en-us")]))
#guard !(«matches» (selOf "[x|=en] { fill: g }") (solo (elemInfo "rect" "" #[] #[("x", "engb")])))

-- `^=`/`$=`/`*=` are outside `simplecss`'s grammar: parsed structurally, never match.
#guard !(«matches» (selOf "[x^=a] { fill: g }") (solo (elemInfo "rect" "" #[] #[("x", "abc")])))

-- `:first-child` is the one supported pseudo-class.
#guard «matches» (selOf ":first-child { fill: g }") (solo (elemInfo "rect" "" #[] #[] true))
#guard !(«matches» (selOf ":first-child { fill: g }") (solo (elemInfo "rect" "" #[] #[] false)))

-- Any other pseudo-class makes the selector never match (parsed, not fatal).
#guard !(«matches» (selOf ":hover { fill: g }") (solo (elemInfo "rect" "" #[] #[] true)))

/-! ## Combinators -/

#guard «matches» (selOf "svg rect { fill: g }") #[elemInfo "svg" "", elemInfo "g" "", elemInfo "rect" ""]
#guard «matches» (selOf "svg > rect { fill: g }") #[elemInfo "svg" "", elemInfo "rect" ""]
#guard !(«matches» (selOf "svg > rect { fill: g }") #[elemInfo "svg" "", elemInfo "g" "", elemInfo "rect" ""])

-- No sibling links in `chain`: `+` can never be evaluated, so it never matches.
#guard !(«matches» (selOf "rect + rect { fill: g }") #[elemInfo "rect" "", elemInfo "rect" ""])

/-! ## Specificity and cascade order -/

-- `resolve`'s output is "apply in order, last write wins": the higher-specificity
-- `#id` rule must win regardless of which was written first in the source.
#guard
  let decls := resolve (rulesOf "#a { fill: green; } rect { fill: red; }") (solo (elemInfo "rect" "a"))
  (decls.filter (·.1 == "fill")).back?.map (·.2) == some "green".toUTF8

#guard
  let decls := resolve (rulesOf "rect { fill: red; } #a { fill: green; }") (solo (elemInfo "rect" "a"))
  (decls.filter (·.1 == "fill")).back?.map (·.2) == some "green".toUTF8

-- Equal specificity: source order breaks the tie, later rule wins.
#guard
  let decls := resolve (rulesOf "rect { fill: red; } rect { fill: green; }") (solo (elemInfo "rect" ""))
  (decls.filter (·.1 == "fill")).back?.map (·.2) == some "green".toUTF8

/-! ## `!important` -/

-- An `!important` declaration wins over a later non-important one of equal
-- (or lower) specificity: `resolve` places all important declarations after
-- all non-important ones.
#guard
  let decls := resolve (rulesOf "#a { fill: green !important; } #a { fill: red; }") (solo (elemInfo "rect" "a"))
  (decls.filter (·.1 == "fill")).back?.map (·.2) == some "green".toUTF8

-- Case-sensitive `important` keyword (matches `simplecss`): a misspelling is
-- just a plain (non-important) declaration.
#guard
  let decls := resolve (rulesOf "#a { fill: red !IMPORTANT; } #a { fill: green; }") (solo (elemInfo "rect" "a"))
  (decls.filter (·.1 == "fill")).back?.map (·.2) == some "green".toUTF8

/-! ## Malformed input: total, never fatal -/

#guard (rulesOf "").size == 0
#guard (parseStylesheet ByteArray.empty).size == 0

-- Unclosed declaration block: whatever is parseable before EOF still counts.
#guard (rulesOf "rect { fill:red").size == 1

-- Unterminated string in an attribute selector: no crash, selector just
-- never matches (parsed, not fatal).
#guard !(«matches» (selOf "[x=\"unterminated { fill:red; }") (solo (elemInfo "rect" "" #[] #[("x", "unterminated")])))

-- 1 MB of `{`: must terminate (this guard's own evaluation proves it did)
-- and produce no rules.
#guard (parseStylesheet (ByteArray.mk (Array.replicate 1000000 (123 : UInt8)))).size == 0

-- 50 000 nested `{` inside a rule body: same totality guarantee.
#guard (parseStylesheet (("rect { ").toUTF8 ++ ByteArray.mk (Array.replicate 50000 (123 : UInt8)))).size == 0
