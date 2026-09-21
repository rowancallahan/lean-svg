# T29 — `<style>` element with simple CSS selectors  [Sonnet]

FEATURES F8 item. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T29`
(branch `t29-css`). Files: new `LeanSvg/Css.lean` (the whole parser and
matcher), `LeanSvg.lean` (import line), `LeanSvg/Xml.lean` **only if**
CDATA sections are not already delivered as text (check first; if you must
add `<![CDATA[ ... ]]>` handling, it is a bounded scan for `]]>` that emits
the bytes as a text event), and `LeanSvg/Svg.lean` **only** the
`interpret` function plus the call site where an element's attributes are
applied (`applyAttrs` call). Do not touch `applyProp`, `Style`, `parsePaint`,
`namedColors` (T24a), `parsePathData` (T16). Another Sonnet agent (T27) is
also editing `interpret` for `<switch>`: keep your change there small and
local (a pre-pass that collects stylesheets, an ancestor stack, and a
resolution step before attributes are applied) so the merge is easy.
Invariants in `tasks/README.md`.

## `LeanSvg/Css.lean` — pure and total

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
  whole harness clean. `git diff main -- LeanSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

Branch was rebased (fast-forward, no conflicts — it had no commits of its own
yet) onto main at `ba299cc` before starting, since main had advanced with
T16/T23/T24a/T24b/T30 while this task was queued; `tests/svg/*.svg` is now 23
files and `tests/corpora` (gitignored, symlinked to the shared clone for the
corpora runs below) is intentionally left out of the commit.

Files changed:
- `LeanSvg/Css.lean` (new) — the whole `simplecss`-subset parser and
  matcher: `parseStylesheet`, `«matches»` (named with guillemets — `matches`
  is a reserved term-level keyword in Lean 4, `e matches pat`, so the spec's
  exact name can only be spelled that way), `resolve`, `matchingDeclsSplit`,
  `buildElemInfo`, and the `ElemInfo`/`Rule`/`Selector`/`Compound`/`Decl`
  structures, all `deriving Repr, BEq` (added `deriving instance Repr for
  ByteArray` at the top — core Lean has no `Repr ByteArray`, needed for any
  struct with a `ByteArray` field to derive `Repr`). Selector matching is a
  bounded DP over (component index × chain index), not the backtracking
  recursion `simplecss` itself uses, so there is no recursion anywhere in the
  module — every function is `for` loops over a range fixed before the loop
  starts. Deviations from `simplecss`'s exact grammar, each because the task
  says "unsupported ⇒ never matches, still total": `^=`/`$=`/`*=` aren't in
  `simplecss::AttributeOperator` (only `Exists`/`Matches`/`Contains`/
  `StartsWith` exist) so they parse structurally but never match; `+`
  (adjacent-sibling) is real in `simplecss` but our match `chain` carries no
  sibling links (ancestors + self only), so it can never be evaluated and
  never matches either. `class` splitting uses general whitespace
  (`Char.isWhitespace`) per the task's explicit instruction, not
  `simplecss`'s own narrower "split on literal space" quirk.
- `LeanSvg.lean` — one import line for `LeanSvg.Css`.
- `LeanSvg/Xml.lean` — **had to touch it, and for more than CDATA.**
  Checked first as instructed: neither CDATA nor plain element text was
  delivered as an event at all (`Event` had only `open_`/`close`; the main
  scan loop jumped straight from one `<` to the next via `findByte`, never
  looking at what was skipped over). Since real-world `<style>` content is
  almost always plain text, not CDATA, CDATA-only support would have fixed
  only the one corpus file that happens to wrap its CSS in
  `<![CDATA[...]]>`. Added one `Event.text (bytes : ByteArray)` constructor
  and a new total `decodeText` (bounded scan, entities decoded like
  `decodeValue` but never throws — an unknown or malformed entity is copied
  through verbatim instead of failing the parse) used for text between tags;
  CDATA payloads are pushed as `.text` verbatim, no entity decoding, per XML
  CDATA semantics. `decodeText` is deliberately lenient (unlike the existing
  strict `decodeValue` for attributes) specifically so this change cannot
  turn a document that used to parse into one that doesn't — text was never
  inspected before, so any stray unescaped `&` sitting in a `<title>`/`<desc>`
  run must keep parsing exactly as before. One more line had to change for
  the same reason: `if events.isEmpty then throw "no elements found"` now
  reads `if count == 0 ...` (element count, already tracked) — a tagless
  document (e.g. the `random_bytes.bin` adversarial case, which happens to
  contain zero `<` bytes) now produces one `.text` event, so `events.isEmpty`
  stopped meaning "no elements"; caught by the direct binary diff below and
  fixed before it could count as a behaviour change.
- `LeanSvg/Svg.lean` — only `interpret` (plus its `import`) touched, exactly
  as scoped; `applyAttrs`, `applyProp`, `Style`, `parsePaint`, `namedColors`,
  `parsePathData` are all byte-identical to main. `interpret` now: (1) a
  pre-pass over `events` (`combinedCss`) collecting every `<style>`'s text —
  CDATA and plain-text chunks concatenated in document order, gated on
  `type` being absent/empty/`text/css` — *before* the main walk, so a
  `<style>` after the elements using its classes still applies
  (`style-after-usage.svg`); (2) a second stack, `elemStack`/`childCounts`,
  pushed/popped in exact lockstep with the existing `Style` stack at all
  three sites (root/`g`/shape; left alone under `skip`) to build each
  element's `Css.ElemInfo` ancestor chain and `:first-child` flag; (3) the
  `applyAttrs parent attrs` call at those three sites replaced by a local
  `applyEffective` closure implementing the four-layer cascade (presentation
  attributes → non-important CSS → `style=""` → `!important` CSS), with
  `color` still resolved first from whichever of the four layers wins, the
  same special-casing `applyAttrs` already did for its two layers, so
  `currentcolor` never sees a stale value.
- `tests/CssTests.lean` (new) — 38 `#guard` checks (≥ 15 required): comment
  removal (incl. unterminated-comment-drops-rest-of-sheet), `@media`/`@import`
  skipping, all four attribute operators plus exists/type/universal/id/class,
  `^=` (unsupported, never matches), `:first-child` and an unsupported
  pseudo-class, descendant/child/adjacent-sibling (never matches) combinators,
  specificity ordering, source-order tie-break, `!important` (incl. the
  case-sensitive keyword), and malformed input (empty sheet, unclosed
  declaration block, unterminated string in an attribute selector, 1 MB of
  `{`, 50 000 nested `{`). `lake env lean tests/CssTests.lean` prints nothing.
- `tests/adversarial/style_nested_braces.svg` and
  `tests/adversarial/style_huge_selector_list.svg` (new, checked in) — a
  `<style>` whose whole body is 50 000 `{`, and a `<style>` with a ~2 MB
  comma-separated selector list (`.a,.a,...`); both render in well under a
  second.

Before/after, `python3 tests/run_corpora.py --fast --no-worst --corpus resvg
--route direct`:
- `structure/style`: **5/16 → 16/16** (target was ≥ 13/16). No remaining
  failures.
- `structure/style-attribute`: **3/4 → 3/4** (target: not below 3/4). One
  remaining failure, unchanged by this task: `comments.svg` —
  `style="/*text*/fill:green/*text*/"` — the pre-existing `style=""`
  attribute-value parser (`parseStyleDecls`, off-limits/untouched here, not a
  `<style>`-element concern) doesn't strip CSS comments, so it reads the
  property name as `/*text*/fill` instead of `fill`; failing before this
  task too.

`python3 tests/run_tests.py`: 19/23 both before and after (identical
exact/mean_abs/max_d per file — the 4 pre-existing failures are unrelated
geometry-fidelity gaps, not touched). Additionally built main's binary
(`ba299cc`) alongside this branch's and diffed PNG bytes directly for all 23
`tests/svg/*.svg` files at natural size and `--width 800` (46 renders): **0
mismatches** — confirmed byte-identical, not just equal-scoring.

`python3 tests/run_adversarial.py`: 40/40 clean before, **42/42 clean**
after adding the two new cases (both render in single-digit/tens of ms).
`git diff main -- LeanSvg/Effect.lean`: empty.

`lake build`: clean, no errors, no new warnings (checked with `lake clean &&
lake build` for a full recompile, not just an incremental one).

Nothing from the spec was left undone.
