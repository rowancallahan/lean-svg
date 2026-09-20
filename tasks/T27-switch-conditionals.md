# T27 — `<switch>` and conditional processing attributes  [Sonnet]

FEATURES F8 item. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T27`
(branch `t27-switch`). File: `MicroSvg/Svg.lean`, the `interpret` function
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
  binary `/Users/rowancallahan/pdf_renderer/.lake/build/bin/microsvg`, or by
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
- `python3 tests/run_adversarial.py` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.
