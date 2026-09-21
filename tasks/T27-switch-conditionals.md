# T27 — `<switch>` and conditional processing attributes  [Sonnet]

FEATURES F8 item. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T27`
(branch `t27-switch`). File: `LeanSvg/Svg.lean`, the `interpret` function
and one new helper next to it. Do not touch `applyProp`, `Style`,
`parsePaint`, `namedColors` (T24a is editing those), `parsePathData` (T16),
or anything in other modules. Invariants in `tasks/README.md` (no
`partial`, bounded loops, no `!` indexing).

## Behaviour (match usvg; read `crates/usvg/src/parser/switch.rs` and the
conditional-attribute handling in `crates/usvg/src/parser/converter.rs` or
`svgtree` in the resvg checkout under `tests/corpora/` if present, else
https://github.com/linebender/resvg)

1. **`systemLanguage`** on any element: value is a comma-separated list;
   an entry matches if, after trimming, it equals `en` or begins with `en-`
   (usvg's default languages list is `["en"]`). No entry matches → the
   element and its whole subtree are skipped (same mechanism as unsupported
   elements, the `skipDepth` path). An empty attribute value → skipped.
2. **`requiredExtensions`** and **`requiredFeatures`**: follow usvg exactly
   (check what it does with each; record it in the report).
3. **`<switch>`**: of its *direct child elements*, render only the first
   one that passes the conditional attributes; skip every other child
   (including later passing ones). A `switch` with no passing child renders
   nothing. `switch` itself is a container like `g`: its presentation
   attributes and transform apply to the chosen child. Nested `switch`
   works through the normal stack.

## Verify

- `lake build` clean.
- Before/after on the suite, fast sizes (run the *before* with the main
  binary `/Users/rowancallahan/pdf_renderer/.lake/build/bin/lean-svg`, or by
  running the harness once before you edit):
  ```
  python3 tests/run_corpora.py --fast --no-worst --corpus resvg --route direct \
    --dir structure/switch --dir structure/systemLanguage --out <scratch>/before
  python3 tests/run_corpora.py --fast --no-worst --corpus resvg --route direct \
    --dir structure/switch --dir structure/systemLanguage --out <scratch>/after \
    --compare <scratch>/before/resvg_direct.csv
  ```
  Targets: `structure/switch` from 1/13 to ≥ 10/13, `structure/systemLanguage`
  from 4/10 to ≥ 8/10. For every file still failing, one line saying why
  (which feature it needs that we do not have).
- `python3 tests/run_tests.py`: all 21 byte-identical to main's binary (none
  of them use these features).
- `python3 tests/run_adversarial.py` clean; `git diff main -- LeanSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

**Files changed**: `LeanSvg/Svg.lean` only — added one new helper,
`passesConditions`, immediately above `interpret`, and rewrote `interpret`.
`LeanSvg/Effect.lean` is byte-identical to main (`git diff main --
LeanSvg/Effect.lean` empty). No other module touched.

**What changed in `interpret`**: a parallel `switchSel : Array (Option
(Option Nat))` tracks, per currently-open frame (pushed/popped alongside
`stack`), what a `<switch>` ancestor demands of its direct children — `none`
(not a switch, unfiltered), `some none` (switch with no passing child, all
children skipped), or `some (some j)` (only the direct child whose `.open_`
event is at index `j` may render). `g`, `switch` and shape elements now also
check `passesConditions attrs` alongside the existing `isDisplayNone`. The
root `<svg>` gets the same two checks too (see below). A `<switch>` that
passes its own checks runs a bounded forward lookahead from its own index to
find the first direct child (depth 0) whose tag is a name usvg's `svgtree`
recognises (see the `non-SVG-child` note below) and whose own
`passesConditions` holds; that index becomes its `switchSel` target.

**Before/after pass counts** (`tests/run_corpora.py --fast --no-worst
--corpus resvg --route direct`, main's binary vs. this worktree's):

| directory | before | after | target |
|---|---|---|---|
| `structure/switch` | 1/13 | **13/13** | ≥ 10/13 |
| `structure/systemLanguage` | 4/10 | **6/10** | ≥ 8/10 |

`structure/switch` is fully passing. `structure/systemLanguage` improved by
2 (`ru-Ru.svg`, `on-svg.svg`) but falls short of the ≥8/10 target; the 4
remaining failures all need a feature this task is explicitly barred from
touching, not a switch/conditional-processing fix:

- `on-clipPath.svg` — needs `clip-path`/`clipPath` support. usvg's
  `is_condition_passed`/`systemLanguage` is irrelevant here: `clipPath`
  itself is never condition-checked (`convert_clip_path_elements` checks
  `is_visible_element` on the clipPath's *children*, not the `clipPath`
  element), confirmed by rendering the reference at width 100 — center pixel
  green, corner transparent, i.e. the star clip is applied regardless of
  `clip1`'s `systemLanguage="ru-RU"`. We don't implement `clip-path` at all
  (`applyProp` has no case for it), so `rect1` always renders unclipped.
- `on-defs.svg` / `on-linearGradient.svg` — need gradient (`linearGradient`)
  and paint-server (`url(#...)`) support; `parsePaint` resolves `url(...)` to
  `.none` unconditionally, unrelated to conditional processing.
- `on-tspan.svg` — needs `text`/`tspan` support; `text` is not in `isShape`
  and hits the unknown-tag branch, so the whole element (both tspans) is
  skipped regardless of the `systemLanguage` on `tspan2`.

**requiredExtensions / requiredFeatures, per usvg**
(`crates/usvg/src/parser/switch.rs::is_condition_passed`): `requiredExtensions`
present at all (any value, even `""`) always fails the element — usvg
supports no extensions. `requiredFeatures` is space-split (`str::split(' ')`,
not trimmed, not collapsed — a stray double space or an empty value produces
an empty token) and every token must be one of usvg's own ~26 hard-coded SVG
1.1 Feature Strings (the `FEATURES` static in `switch.rs`); we match that
exact list, not the (much smaller) set of features *we* actually render, per
the spec. Reproduced verbatim in `passesConditions`.

**A real usvg quirk that had to be replicated for `structure/switch` to hit
13/13**:
1. `display-none-on-child.svg`: `switch`'s child search
   (`is_condition_passed`) does *not* check `display:none` — only
   `requiredExtensions`/`requiredFeatures`/`systemLanguage`. So a
   `display:none` first child still "wins" the search, and since
   `switch::convert` never backtracks to the next sibling once it has
   picked a child, the whole `switch` renders nothing (both children are
   red here, so this only shows up as a pixel diff, not a color story).
   `interpret` replicates this: the lookahead only calls
   `passesConditions`, and `isDisplayNone`/`passesConditions` are re-checked
   only once we reach the chosen child via `switchSel`, with no fallback.
2. `non-SVG-child.svg`: rendering the reference showed **green** (`rect1`
   wins), not "nothing", which surprised me — usvg's tree builder
   (`svgtree/parse.rs::parse_xml_node`) drops any element whose tag name
   isn't one of ~54 known SVG 1.1 element names *before* it becomes a node
   at all (`<style>` is dropped too, as a special case), so `<random/>`
   never exists for `switch`'s child search to land on. `interpret`'s
   lookahead now also requires the candidate's tag to be in that same
   name list (embedded as a local `let` inside the lookahead, not a second
   top-level helper) before treating it as a candidate; otherwise it's
   skipped over (depth tracked, not "won") like a failing sibling.
3. `on-svg.svg`: `systemLanguage` (and, by the same code path, `display` and
   transform validity) on the **root** `<svg>` is *not* a no-op in usvg —
   `converter::convert_doc` calls `svg.is_visible_element(opt)` directly and
   returns an empty (but correctly sized) `Tree` if it fails, confirmed by
   rendering the reference: fully transparent 200×200, not even the frame
   rect. `interpret`'s root branch now runs the same two checks and, on
   failure, sets `skip := 1` on the root's own open event so the whole rest
   of the document is skipped via the existing skip-counter mechanism,
   leaving `root` (for sizing) set but `shapes` empty.

**Verification**:
- `lake build`: clean, no new warnings.
- `run_tests.py` byte-identity: this task's worktree is branched from
  `aa0324f`, before `t23-dashes` and other work landed on main (main is now
  at 23 fixture files; this worktree still has the original 21, and per
  "do not push or merge" I did not rebase). Comparing main's *current*
  binary against this worktree's edited one would conflate unrelated
  upstream drift with this change, so instead I built a same-worktree
  reference binary from `LeanSvg/Svg.lean` at `aa0324f` (`git stash` /
  build / `git stash pop` / rebuild, never touching main), and diffed all
  21 fixtures byte-for-byte at natural size and `--width 800` against the
  post-edit binary: **all 21 identical** (none exercise `switch`,
  `systemLanguage`, `requiredFeatures` or `requiredExtensions`).
  `run_tests.py` itself (fidelity vs. resvg, a different, threshold-based
  check) reports the same 17/21 pass, 4 fail as before my change
  (`12_badge`, `14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`
  — pre-existing, unrelated antialiasing/complex-path gaps).
- `run_adversarial.py`: 38/38 clean, no violations.
- `git diff main -- LeanSvg/Effect.lean`: empty.
