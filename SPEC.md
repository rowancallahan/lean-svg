# SPEC — what lean-svg actually promises

Every claim below is either **proved** (checked by Lean's kernel), **enforced**
(by the type checker or the compiler, without a theorem), **checked** (a runtime
test in the code), or **not established**. The fourth category is the important
one and it is listed in full.

New to this? `learn/` is a 250-line standalone project that builds the same
ideas from a hello world, with an exercise. Read that first.

Audit any claim yourself:

```bash
lake env lean --run /dev/stdin <<'EOF'
import LeanSvg.Effect
#print axioms LeanSvg.Prog.renderProgram_spec
EOF
```

`[propext]` means propositional extensionality only, which is part of Lean's
foundations. Lean has three standard axioms — `propext`, `Quot.sound` and
`Classical.choice` — and any of the three is ordinary; Mathlib rests on all
of them. `sorryAx` is the one that matters: it means a hole, and a theorem
reporting it proves nothing. The seven effect theorems report `[propext]`. The size bounds below report
`[propext, Quot.sound]` for the encoder and
`[propext, Classical.choice, Quot.sound]` for the renderer, with no `sorryAx`.

## These proofs have not been independently reviewed

Read this before relying on anything below.

The axiom list tells you a proof has no holes. It does not tell you the
theorem says what you want, and that is the harder question. A flawless proof
of the wrong statement is worthless, and this specification has already
contained one: `runFS_frame` is true and was for a time described as "only
touches the two files you named", which it does not establish — see section 4
on input and output paths.

So the statements themselves need checking by a human, line by line, against
what a reader would take them to mean. That review has not happened yet.
Until it does, treat section 1 as *claims whose proofs check*, not as
*guarantees*. The model in `LeanSvg/Effect.lean` and the eleven-line
`Prog.execIO` deserve the most scrutiny, because the effect claims are stated
relative to them. The byte-array size bounds below concern pure functions
and do not depend on the filesystem model or interpreter.

---

## 1. Proved

The seven effect theorems live in `LeanSvg/Effect.lean` and are stated against a
**model** of the filesystem, `FS := String → Option ByteArray`, a function
from a path to its contents, or `none` if the path is absent. This is what
makes "the output path already exists" expressible at all: the earlier model,
`String → ByteArray`, gave every path contents unconditionally, so a missing
file and an empty file were indistinguishable and no-clobber could not even be
stated. The separate output-size theorems live in `proofs/SizeBound.lean`.

### Nothing but the output file is touched

> Running any program leaves every path except the output path holding exactly
> what it held before.

```lean
theorem runFS_frame (inp out : String) (p : Prog α) (fs : FS) (q : String) (hq : q ≠ out) :
    (runFS inp out p fs).2 q = fs q
```

### The result depends only on the input file and whether the output exists

> If two filesystems agree on the input path, and agree on whether the output
> path is present (not on what it holds — the program can query only that),
> every program returns the same answer on both. So a program cannot secretly
> read anything else, or the output path's contents.

```lean
theorem runFS_input_only (inp out : String) (p : Prog α) (fs fs' : FS)
    (hin : fs inp = fs' inp) (hout : (fs out).isSome = (fs' out).isSome) :
    (runFS inp out p fs).1 = (runFS inp out p fs').1
```

### The renderer refuses to clobber, and otherwise fails cleanly or writes exactly its output

> Read the input. If the output path already exists, fail immediately and
> touch nothing. Otherwise run the pure renderer: if it errors, the filesystem
> is untouched; if it succeeds, the output path holds exactly the bytes it
> produced. There is no fourth outcome.

```lean
theorem renderProgram_spec (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS) :
    runFS inp out (renderProgram clobberError render) fs =
      if (fs out).isSome then
        (.error clobberError, fs)
      else
        match render ((fs inp).getD ByteArray.empty) with
        | .ok (png, warn) => (.ok (warn.size != 0), fs.write out png)
        | .error e => (.error e, fs)
```

This is the default (strict) program (T98b). `render` also returns a
warnings text; the strict program never writes it and returns only whether it
was non-empty, which `Main` turns into exit code `2`. With `--warnings`,
`Main` runs `renderProgramWarn` instead (T98): it refuses if either the output
path or `<out>.warnings.txt` exists, and otherwise also writes the non-empty
warnings text there (`renderProgramWarn_spec`, `renderProgramWarn_ok_frame`:
nothing but those two paths changes; `renderProgramWarn_never_overwrites`:
only paths that were absent change).

### No-clobber

> If the output path already holds something when the program starts, running
> it changes the file system not at all.

```lean
theorem renderProgram_no_clobber (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray))
    (inp out : String) (fs : FS) (b : ByteArray) (h : fs out = some b) :
    (runFS inp out (renderProgram clobberError render) fs).2 = fs
```

The remaining three are corollaries, each with an added `fs out = none`
hypothesis (a success or an ordinary render error can only happen once
no-clobber has let the program past its first check): `renderProgram_error_no_write`
(on error, nothing changed), `renderProgram_ok_output` (on success, the output
path holds `some` the bytes), `renderProgram_ok_frame` (nothing but the
output path ever moves), plus `renderProgram_never_overwrites` (a changed path
was absent before).

`Main.lean` writes nothing to stdout or stderr; its only other output is the
exit code (`0` ok, `2` ok with warnings, `1` failure). `Op` has no operation
that could print, and `tests/check_invariants.py` fails if the `lean-svg`
main path mentions a print, stream, trace, panic or subprocess.

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

These are claims about **function outputs only**. The filesystem, operating
system and `execIO` are outside these theorems; no disk-space or PNG-validity
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

---

## 2. Enforced without a theorem

- **There are exactly three effects.** `Op` has three constructors, `readInput`,
  `outputExists` and `writeOutput`. A program that opens a socket or reads a
  second file cannot be *written down*, so no theorem is needed. This is the
  strongest guarantee in the project and it is structural.
- **Everything terminates.** No `partial` anywhere, so Lean's termination
  checker has accepted every definition. Note what this does *not* say: it
  bounds nothing about how long.
- **No floats, no FFI, no `unsafe`, no dependencies.** Project invariants in
  `tasks/README.md`, kept by review and the build, not by a proof.

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

**No-clobber is now proved** (`renderProgram_no_clobber`, section 1). This
entry is kept, struck through in spirit, as a record of what changed: the
model was `FS := String → ByteArray`, every path had contents unconditionally,
so a missing file read as empty and "this file already exists" was not
expressible. It is now `String → Option ByteArray`.

**Input and output paths given the same value are handled by no-clobber, not
specially.** `lean-svg a.svg a.svg` reads the file, then queries whether `a.svg`
(the output path) exists — it does, since it is also the input — and refuses.
Nothing distinguishes this from any other pre-existing output; there is no
separate "paths differ" check, by design (see `PLAN.md` M3b.0).

**Time and memory are not bounded.** Termination is guaranteed, duration is not.

**`Prog.execIO` is trusted, not proved.** Eleven lines mapping the three
operations onto `System.FilePath.pathExists`, `IO.FS.readBinFile` and
`IO.FS.writeBinFile`. The theorems describe the model; this function is the
claim that the model corresponds to reality. It inherits whatever the Lean
runtime and the operating system do, including symlinks, permissions and
races — including a TOCTOU race between the `pathExists` check and the
eventual `writeBinFile`: the model treats the check as atomic with the rest of
the program, which a real filesystem does not guarantee under concurrent
writers.

**Rendering fidelity is empirical and always will be.** Measured against resvg:
a file passes when ≥ 99% of pixels are within 8 levels. That is a measurement,
not a claim, and the reference is another program, not a specification.

---

## 5. What a reader is actually trusting

In order of how much weight each carries:

1. **The model.** `FS` and `runFS` define what the theorems mean. A wrong model
   makes a correct proof worthless — no-clobber (section 1) needed the model
   itself changed, from `String → ByteArray` to `String → Option ByteArray`,
   before the property could even be stated, which is a live example of the
   risk.
2. **`execIO`**, eleven lines, unproved, including the TOCTOU gap noted above.
3. **The Lean kernel and toolchain** (v4.34.0), and `propext`.
4. **The invariants** in `tasks/README.md`, kept by review rather than by types.

Everything else in the renderer is a pure function from `ByteArray` to
`Except String ByteArray`, and the theorems above say exactly what happens to
the filesystem on either outcome.
