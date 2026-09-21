# T43 — CI that enforces the proof boundary  [Sonnet]

PLAN M8b. The project's strongest claims are currently kept by review:
`Op` has exactly two constructors, no IO exists outside `Effect.lean`, the six
effect theorems depend on `propext` alone, and `LeanSvg/` contains no
`partial`, `unsafe`, `panic!`, `!`-indexing or `Float`. Nothing checks any of
that. Several agents edit this repository concurrently, so each of these
should fail the build rather than a code review.

Deliverables: `tests/check_invariants.py` (or a Lean file plus a small
driver, if that is cleaner) and `.github/workflows/ci.yml`. No renderer
changes.

## Checks

**1. Axioms.** Elaborate a file that does `#print axioms` for each of
`LeanSvg.Prog.runFS_frame`, `runFS_input_only`, `renderProgram_spec`,
`renderProgram_error_no_write`, `renderProgram_ok_output` and
`renderProgram_ok_frame`. Every one must report exactly `[propext]`. Fail on
anything else, and in particular on `sorryAx`, which also catches a `sorry`
added to make something compile. Note that the theorems live in the
`LeanSvg.Prog` namespace, not `LeanSvg`.

**2. Two effects.** `Op` in `LeanSvg/Effect.lean` must have exactly the
constructors `readInput` and `writeOutput`. Prefer a check that survives
reformatting: for example, elaborate a Lean snippet that pattern matches on
`Op` and would fail to compile if a constructor were added or renamed, rather
than counting lines with a regex. Say in the report which approach you chose
and what it would miss.

**3. No IO outside the effect layer.** `IO.` must not appear in any
`LeanSvg/*.lean` other than `Effect.lean`. `FontDump.lean` and `Main.lean` are
outside `LeanSvg/` and are allowed IO.

**4. Mechanical invariants** from `tasks/README.md`, across `LeanSvg/`:
no `partial`, `unsafe`, `@[extern]`, `panic!`, `!`-indexing (`[i]!`, `get!`,
`set!`) and no `Float`. Beware false positives: a word may appear inside a
comment or a string, and `partial` appears in prose in several doc comments.
Decide whether to strip comments first and state the choice in the report.

**5. Build and tests.** `lake build` with no errors, `tests/CssTests.lean`
elaborating silently, and `run_tests.py`, `run_tiles.py`, `run_adversarial.py`
all passing. These need resvg and the test corpora, unlike checks 1 to 4.

## Workflow

`.github/workflows/ci.yml`, on push and pull request:

- **Job `invariants`**: install elan and the pinned toolchain, `lake build`,
  run checks 1 to 4. Fast, no external dependencies, and it is the job that
  should gate everything.
- **Job `tests`**: additionally install resvg 0.48.1 and clone the resvg test
  suite shallowly (`git clone --depth 1 https://github.com/linebender/resvg`;
  its tests live at `crates/resvg/tests`, symlinked to
  `tests/corpora/resvg-test-suite`), then run check 5. If installing resvg
  from source is slow, cache it and report cold and warm times.

Cache elan and the Lake build. Do not run on pull requests from forks with
secrets. Report both jobs' cold and warm durations.

## Verify

- Every check passes on current `main`.
- **Each check actually fails when it should.** Demonstrate all four by
  temporarily breaking them locally, one at a time, and show the failure
  output in the report: add a third `Op` constructor; add an `IO.println` to a
  `LeanSvg` module; add a `sorry`; add a `partial def`. Revert each one. A
  check that cannot be shown to fail is not a check.
- The workflow file is valid (`actionlint` if available, else a careful read).
- `git diff origin/main -- LeanSvg/` empty at the end.

Commit with author Rowan Callahan <rowan.l.callahan@gmail.com> and a message
ending `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`, push, and open
a pull request against main whose description is the report and ends with
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do not merge.

Note: a separate session may add `.github/workflows/pages.yml`; keep this
workflow in its own file so the two do not conflict.
