# T29 — `<style>` element with simple CSS selectors  [Sonnet]

FEATURES F8 item. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T29`
(branch `t29-css`). Files: new `MicroSvg/Css.lean` (the whole parser and
matcher), `MicroSvg.lean` (import line), `MicroSvg/Xml.lean` **only if**
CDATA sections are not already delivered as text (check first; if you must
add `<![CDATA[ ... ]]>` handling, it is a bounded scan for `]]>` that emits
the bytes as a text event), and `MicroSvg/Svg.lean` **only** the
`interpret` function plus the call site where an element's attributes are
applied (`applyAttrs` call). Do not touch `applyProp`, `Style`, `parsePaint`,
`namedColors` (T24a), `parsePathData` (T16). Another Sonnet agent (T27) is
also editing `interpret` for `<switch>`: keep your change there small and
local (a pre-pass that collects stylesheets, an ancestor stack, and a
resolution step before attributes are applied) so the merge is easy.
Invariants in `tasks/README.md`.

## `MicroSvg/Css.lean` — pure and total

usvg uses the `simplecss` crate; match its supported subset
(https://github.com/linebender/simplecss, `src/lib.rs` and `selector.rs`):

- Comments `/* ... */` removed (unterminated comment: rest of sheet is
  ignored). `@`-rules skipped: `@import ...;` to the semicolon, block rules
  by matching braces (depth bounded at 32).
- Rule = selector list (comma-separated) + declaration block. Declaration:
  `name : value` with optional `!important`; value kept as raw bytes
  (trimmed). Unknown or malformed rules are skipped, never fatal.
- Selectors: compound = optional type name or `*`, then any of `#id`,
  `.class`, `[attr]`, `[attr=value]`, `[attr~=value]`, `[attr|=value]`,
  `[attr^=value]`, `[attr$=value]`, `[attr*=value]`, `:first-child`.
  Combinators: descendant (whitespace), child `>`, adjacent `+` if simplecss
  supports it (check; otherwise a selector using it never matches).
  Pseudo-classes other than `first-child` → selector never matches.
- Specificity `(ids, classes+attrs+pseudos, types)`; ordering: by
  specificity, then source order; `!important` declarations above all
  non-important ones.
- Structures `deriving Repr, BEq`. API:
  ```
  def parseStylesheet (src : ByteArray) : Array Rule
  structure ElemInfo where tag : String; id : String; classes : Array String; attrs : Array (String × String); isFirstChild : Bool
  def matches (sel : Selector) (chain : Array ElemInfo) : Bool   -- chain = ancestors (root first) ++ [element]
  def resolve (rules : Array Rule) (chain : Array ElemInfo) : Array (String × ByteArray)  -- winning declarations, in application order
  ```
  Bounds: rules ≤ 10 000, compounds per selector ≤ 32, chain depth ≤ 64 (the
  XML depth cap); all loops `for` over ranges.

## Integration in `interpret`

Effective properties of an element, lowest to highest precedence: presentation
attributes, then CSS declarations from `resolve` (non-important), then the
`style=""` attribute, then CSS `!important` declarations. Every `<style>`
element in the document contributes (elements *before* a `<style>` are
affected too, so collect all stylesheets in a pre-pass over the event array),
provided `type` is absent, empty or `text/css`. Keep an ancestor stack of
`ElemInfo` (parse `class` as whitespace-separated names; `isFirstChild` from a
per-level child counter).

## Verify

- `lake build` clean.
- A file `tests/CssTests.lean` with `#guard` checks (at least 15) covering:
  comment removal, `@media` skipping, each selector kind, specificity
  ordering, `!important`, malformed input (unclosed brace, unclosed string,
  empty sheet, 1 MB of `{`). Compile it with
  `lake env lean tests/CssTests.lean` (must print nothing).
- Before/after on the suite, fast sizes:
  ```
  python3 tests/run_corpora.py --fast --no-worst --corpus resvg --route direct \
    --dir structure/style --out <scratch>/before
  python3 tests/run_corpora.py --fast --no-worst --corpus resvg --route direct \
    --dir structure/style --out <scratch>/after --compare <scratch>/before/resvg_direct.csv
  ```
  Target: `structure/style` from 5/16 to ≥ 13/16; `structure/style-attribute`
  not below 3/4. One line per remaining failure.
- `python3 tests/run_tests.py`: all 21 byte-identical to main's binary.
- Two new adversarial cases under `tests/adversarial/` (a `<style>` with 50 000
  nested `{`, and a 2 MB selector list) run through `run_adversarial.py`; the
  whole harness clean. `git diff main -- MicroSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.
