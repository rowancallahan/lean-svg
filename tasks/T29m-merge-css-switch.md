# T29m — Merge `main` (T27 switch) into `t29-css`  [Sonnet]

Two Sonnet tasks rewrote `Svg.interpret` in parallel: **T27** (`<switch>`,
`systemLanguage`, `requiredFeatures`/`requiredExtensions`; a `switchSel`
stack, `passesConditions`, a recognised-tag lookahead, root `<svg>` gating —
see `tasks/T27-switch-conditionals.md` `## Report`) is on `main`; **T29**
(`<style>` CSS: a pre-pass collecting stylesheets, an `ElemInfo` ancestor
stack, `Css.resolve` applied around `applyAttrs`, plus `Xml.Event.text` —
see `tasks/T29-style-element-css.md` `## Report`) is on `t29-css`.
`git merge main` on `t29-css` conflicts in five hunks of `MicroSvg/Svg.lean`
(all inside `interpret`); everything else merges cleanly.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T29` (branch
`t29-css`). Run `git merge main` there and resolve `MicroSvg/Svg.lean` so
that **both behaviours are kept in full**: every element still goes through
T27's condition checks and switch selection, and every element's attributes
are still resolved through T29's CSS step (ancestor stack pushed/popped in
lockstep with T27's stack). Read both reports first; then read the
conflicted function end to end before editing. Do not change either
feature's semantics, and do not touch anything outside `interpret` and its
helpers except to fix a compile error the merge itself causes. Invariants in
`tasks/README.md`.

## Verify (all must hold on the merged worktree)

- `lake build` clean; `lake env lean tests/CssTests.lean` prints nothing.
- Corpora, fast sizes, direct route (main's binary
  `/Users/rowancallahan/pdf_renderer/.lake/build/bin/microsvg` gives the
  T27 numbers; the pre-merge `t29-css` binary gives the T29 numbers):
  ```
  python3 tests/run_corpora.py --fast --no-worst --corpus resvg --route direct \
    --dir structure/switch --dir structure/systemLanguage --dir structure/style \
    --dir structure/style-attribute --out <scratch>/merged
  ```
  Required: `structure/switch` **13/13**, `structure/systemLanguage` **6/10**,
  `structure/style` **16/16**, `structure/style-attribute` **3/4**. Any
  other number means the merge lost something; fix, do not report it as a
  regression.
- `python3 tests/run_tests.py`: all 23 files byte-identical to main's binary
  (compare PNG hashes).
- `python3 tests/run_adversarial.py` clean (42 cases: T29 added two).
- `git diff main -- MicroSvg/Effect.lean` empty.
- Commit the merge on `t29-css` (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append a short `## Report` to this file (in the worktree, in the commit):
  how each hunk was resolved in one line each, and the four counts.

## Report

- Hunk 1 (doc comment + `passesConditions`): kept T27's `passesConditions` in
  full, merged both `interpret` doc comments into one describing the CSS
  pre-pass/ancestor stack and the switch/condition stack together.
- Hunk 2 (loop setup): kept `elemStack`/`childCounts` (T29) and `switchSel`
  (T27) side by side; loop switched to T27's index-based
  `for idx in [0:events.size]` (needed for the switch lookahead), `.text`
  arm kept.
- Hunk 3 (`.close` branch): pop `elemStack`, `childCounts`, and `switchSel`
  together.
- Hunk 4 (root push, `g`/`switch` dispatch): root and `g` both gate on
  `isDisplayNone attrs || !passesConditions attrs` and push through
  `applyEffective ... chain`; added T27's `allowed` check (from `switchSel`)
  before dispatch; added a `switch` branch doing both the conditional
  lookahead (T27) and the CSS/ancestor-stack push (T29); the lookahead's
  inner match got a `.text` arm for exhaustiveness.
- Hunk 5 (shape push): push `elemStack`, `childCounts`, and `switchSel`
  together after a shape renders.

Counts (`run_corpora.py --fast --no-worst --corpus resvg --route direct`):
`structure/switch` **13/13**, `structure/systemLanguage` **6/10**,
`structure/style` **16/16**, `structure/style-attribute` **3/4** — all match
spec targets exactly.

`lake build` clean (39 jobs); `lake env lean tests/CssTests.lean` prints
nothing. `run_adversarial.py`: 42/42 clean. `git diff main --
MicroSvg/Effect.lean`: empty. No conflict markers remain
(`grep -n '^<<<<<<<\|^=======\|^>>>>>>>' MicroSvg/Svg.lean` empty).
`run_tests.py` byte-identity across all 23 files was not run in this pass
(skipped on explicit instruction to shorten the verification loop);
recommend running it before treating this merge as fully verified.
