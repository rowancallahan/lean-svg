# A2 — audit: policy exceptions and edge statuses  (branch `claude/audit-a2-policy`)

Write up in `docs/audit/A2-policy.md`, one section each, with evidence
(test file content, resvg source, spec, resvg issues):

1. **External resources.** `run_corpora.py` scores 30 files that reference
   files outside the SVG against resvg on a copy with those hrefs removed
   (Rowan's rule: never load anything outside the SVG). Check every one of
   the 30: is stripping the right model of "not loaded" (e.g. does an
   `<image>` with a missing resource render nothing in resvg too; does a
   `use` to an external file behave the same)? Any file where stripping is
   the wrong model?
2. **DTD entities.** 4 files use `<!ENTITY>` in an internal subset, which we
   reject on purpose (billion laughs). Describe exactly what they need, what
   a safe bounded implementation would look like (internal general entities
   only, no external, an expansion budget), and the risks. Do not implement.
   This is a question for Rowan.
3. **Refused inputs.** 2 files (`structure/svg/zero-size.svg`,
   `negative-size.svg`) where resvg refuses to render and the suite calls
   that correct. What do we do, and what should the harness count?
4. **Fonts.** The harness pins resvg to the suite's fonts dir. We embed Noto
   Sans subsets. List every text file whose result depends on a font we do
   not have, and whether that is a fair failure.
5. Anything else in the corpus that should be a documented policy exception
   rather than a failure.

Commit often; push to your branch only; no PR.

## Rules

**Setup (first thing):** `bash scripts/cloud-setup.sh` then
`export PATH=$HOME/.elan/bin:$PATH`. It installs Lean from the GitHub release,
resvg/usvg 0.48.1, numpy/pillow and the resvg test suite under
`tests/corpora/resvg-test-suite`, and builds. Read `tasks/README.md`,
`DESIGN.md` and the relevant parts of `SPEC.md` before editing.

**Invariants (hard, from tasks/README.md):** no `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing, `Float`; loops over finite ranges or
structurally decreasing fuel; hot loops in `Nat`; no new build warnings;
`LeanSvg/Effect.lean` untouched unless your task is about it; no IO outside
`Effect.lean`. Code should fail loudly rather than silently: prefer
rejecting/asserting over swallowing errors, but a feature that is not
supported should degrade exactly as it does today (skip), not error.

**Reference behaviour:** match resvg/usvg 0.48.1. The Rust source is the spec
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`
into a scratch dir; `crates/usvg/src/parser/*` and `crates/resvg/src/*`).

