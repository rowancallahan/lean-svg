# SPEC — what lean-svg actually promises

Every claim below is either **proved** (checked by Lean's kernel), **enforced**
(by the type checker or the compiler, without a theorem), **checked** (a runtime
test in the code), or **not established**. The fourth category is the important
one and it is listed in full.

New to this? `docs/learn/MainExplained.lean` is a commented toy with the same
shape as `Main.lean` (a fake renderer, the same file-system calls, small
theorems), runnable with `lake env lean --run`. Read that first.

Audit any claim yourself:

```bash
lake env lean /dev/stdin <<'EOF'
import LeanSvg.Cli
#print axioms LeanSvg.Cli.parse_paths_mem
EOF
```

Lean has three standard axioms — `propext`, `Quot.sound` and
`Classical.choice` — and any of the three is ordinary; Mathlib rests on all
of them. `sorryAx` is the one that matters: it means a hole, and a theorem
reporting it proves nothing. `scripts/axiom_audit.py` finds every theorem in
`LeanSvg/Cli.lean` and `proofs/*.lean` from the source and fails if any
depends on anything but those three.

## These proofs have not been independently reviewed

Read this before relying on anything below.

The axiom list tells you a proof has no holes. It does not tell you the
theorem says what you want, and that is the harder question. A flawless proof
of the wrong statement is worthless, and this specification has already
contained one: a frame theorem about a model file system (since removed, see
`docs/DECISIONS.md`) was for a time described as "only touches the two files
you named", which it did not establish.

So the statements themselves need checking by a human, line by line, against
what a reader would take them to mean. That review has not happened yet.
Until it does, treat section 1 as *claims whose proofs check*, not as
*guarantees*. The file-system behaviour is not proved at all: it is `main` in
`Main.lean`, read by eye (section 1).

---

## 1. Proved, and what is read by eye

### File-system behaviour: `main`, trusted, not proved

Every file-system call `lean-svg` makes is in `main` in `Main.lean`, written
as plain Lean `IO` calls, about 30 lines. In order:

1. `Cli.parse args`; on `none` (bad arguments), exit `1`.
2. `IO.FS.readBinFile` the input path.
3. `System.FilePath.pathExists` the output path; if it exists, exit `1`.
   With `--warnings`, the same for `<output>.warnings.txt` (`Cli.warnPath`).
4. `renderWithWarnings` (pure); on `.error`, exit `1`.
5. Create the output file with `IO.FS.withFile … .writeNew` (O_EXCL: fails
   rather than overwrite) and write the PNG.
6. If the warnings text is empty, exit `0`. Otherwise, with `--warnings`,
   create `<output>.warnings.txt` the same way and write it; exit `2` either
   way (without `--warnings` the warnings are dropped).

Any `IO` error in steps 2–6 is caught and is exit `1`. Nothing is written to
stdout or stderr. `tests/check_invariants.py` fails if `IO` or `System.`
appears anywhere under `LeanSvg/`, if `Main.lean`'s file-system calls differ
from exactly this list (one `readBinFile`, two `pathExists`, one
`withFile … .writeNew` in the helper `writeNewFile`), or if the `lean-svg`
main path mentions a print, stream, trace, panic or subprocess.

### Where the paths come from (`LeanSvg/Cli.lean`)

```lean
theorem parse_paths_mem (h : parse args = some c) : c.input ∈ args ∧ c.output ∈ args
theorem parse_paths_ne_empty (h : parse args = some c) : c.input ≠ "" ∧ c.output ≠ ""
theorem parse_warnings_iff (h : parse args = some c) : c.warnings = true ↔ "--warnings" ∈ args
theorem warnPath_ne (out : String) : warnPath out ≠ out
```

So the two paths `main` touches are command-line arguments, verbatim, and the
warnings file is never the output file. `parse` is a pure function of the
arguments, so the render options come from them and nothing else.

### Returned byte arrays have a bounded size

`proofs/SizeBound.lean` proves, for every encoder input (even an RGBA array of
an unexpected length):

```lean
theorem encode_size_le_square (w h : Nat) (rgba : ByteArray) :
    (Png.encode w h rgba).size ≤ 5 * (max w h) * (max w h) + 132
```

This is 1.25 times the RGBA byte size of the enclosing square, plus **132 bytes**.
A more informative rectangular bound is also proved:
`68 + h * (4*w + 16 + 5 * (4*w / 65535))`, with natural-number division.

`render_output_size_bound` connects both bounds to the dimensions checked by
`render`, for serial, parallel and viewport output. Combining the rectangular
bound with `maxDim = 16384` and `maxPixels = 16777216` proves:

```lean
theorem render_size_le_const (opts : Options) (input png : ByteArray)
    (hr : render opts input = .ok png) : png.size ≤ 67452996
```

The same bound is stated for the function `main` calls:

```lean
theorem renderWithWarnings_size_le (options : Options) (inputBytes pngBytes : ByteArray)
    (warnings : Array String)
    (h : renderWithWarnings options inputBytes = .ok (pngBytes, warnings)) :
    pngBytes.size ≤ 67452996
```

These are claims about **function outputs only**. The filesystem and
operating system are outside these theorems; no disk-space or PNG-validity
claim is implied. Check the proofs separately from the normal build:

```bash
lake build
lake env lean proofs/SizeBound.lean
```

### The input is rejected before parsing if it is too large

`proofs/SizeBound.lean` also proves the cheapest of the resource theorems:

```lean
theorem render_rejects_large (opts : Options) (input : ByteArray) (h : input.size > maxInput) :
    ∃ e, render opts input = .error e
```

`maxInput` is 64 MiB. The check is the first line of `render`, before `Xml.parse`
runs at all, so the proof does not touch the XML/SVG pipeline.
`renderWithWarnings_rejects_large` states the same for `renderWithWarnings`.

---

## 2. Enforced without a theorem

- **Only `Main.lean` does `IO`.** The renderer is `renderWithWarnings :
  Options → ByteArray → Except String (ByteArray × Array String)`; its type
  has no `IO`, and with no `unsafe` or `@[extern]` (checked below) a pure
  function cannot open a file, a socket or a process. The invariant check in
  section 1 keeps `IO` out of `LeanSvg/` and pins `Main.lean`'s calls.
- **Everything terminates.** No `partial` anywhere, so Lean's termination
  checker has accepted every definition. Note what this does *not* say: it
  bounds nothing about how long.
- **No floats, no FFI, no `unsafe`, no dependencies.** Project invariants in
  `docs/DECISIONS.md`, kept by review and the build, not by a proof.

---

## 3. Checked at runtime

These protections are implemented as runtime checks. The output-size and
max-input-size theorems above now cover the canvas and input-size checks; the
other limits have no corresponding resource theorem here.

- Canvas dimensions ≤ 16384 and total pixels ≤ 16777216.
- Input size ≤ 64 MiB (`maxInput`; proved above, `render_rejects_large`).
- XML nesting depth ≤ 2048 (T104; pgfplots nests one `g` per path); element count ≤ 1000000.
- Fuel limits on gradient `href` chains, clip nesting, composite glyphs.
- A layer-pixel budget for group opacity.

---

## 4. Not established

Read this section as the specification's honest edge.

**The output is not proved to be a valid PNG.** There is no PNG specification in
Lean here. The encoder is ordinary code, tested against a real decoder.

**No-clobber is not a theorem.** It is `main`'s `pathExists` check plus the
exclusive create (`.writeNew`, O_EXCL), which the Lean runtime and the OS
provide.

**Input and output paths given the same value are handled by no-clobber, not
specially.** `lean-svg a.svg a.svg` reads the file, then checks whether `a.svg`
(the output path) exists — it does, since it is also the input — and refuses.
Nothing distinguishes this from any other pre-existing output; there is no
separate "paths differ" check, by design (see `PLAN.md` M3b.0).

**Time and memory are not bounded.** Termination is guaranteed, duration is not.

**`main` is trusted, not proved.** It inherits whatever the Lean runtime and
the operating system do, including symlinks and permissions. A file created
at the output path between the `pathExists` check and the write makes the
exclusive create fail (exit `1`, nothing overwritten). With `--warnings`, a
warnings file created in that window makes the second create fail after the
PNG was written: exit `1` with the PNG left in place.

**Rendering fidelity is empirical and always will be.** Measured against resvg:
a file passes when ≥ 99% of pixels are within 8 levels. That is a measurement,
not a claim, and the reference is another program, not a specification.

---

## 5. What a reader is actually trusting

In order of how much weight each carries:

1. **`main` in `Main.lean`**, about 30 lines, read by eye, and the Lean
   runtime's `readBinFile`, `pathExists` and `withFile … .writeNew`.
2. **The Lean kernel and toolchain** (v4.34.0), and the standard axioms.
3. **The invariants** in `docs/DECISIONS.md`, kept by review and
   `tests/check_invariants.py` rather than by types.

Everything else in the renderer is a pure function from `ByteArray` to
`Except String (ByteArray × Array String)`.
