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
reporting it proves nothing. As of this writing every theorem in section 1
reports `[propext]`.

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
*guarantees*. The model in `LeanSvg/Effect.lean` and the six-line
`Prog.execIO` deserve the most scrutiny, because everything else is stated
relative to them.

---

## 1. Proved

All six live in `LeanSvg/Effect.lean` and are stated against a **model** of the
filesystem, `FS`, which is a function from a path to its contents.

### Nothing but the output file is touched

> Running any program leaves every path except the output path holding exactly
> what it held before.

```lean
theorem runFS_frame (inp out : String) (p : Prog α) (fs : FS) (q : String) (hq : q ≠ out) :
    (runFS inp out p fs).2 q = fs q
```

### The result depends only on the input file

> If two filesystems agree on the input path, every program returns the same
> answer on both. So a program cannot secretly read anything else.

```lean
theorem runFS_input_only (inp out : String) (p : Prog α) (fs fs' : FS) (h : fs inp = fs' inp) :
    (runFS inp out p fs).1 = (runFS inp out p fs').1
```

### The renderer either fails cleanly or writes exactly its output

> Read the input, run the pure renderer. If it errors, the filesystem is
> untouched. If it succeeds, the output path holds exactly the bytes it
> produced. There is no third outcome.

```lean
theorem renderProgram_spec (render : ByteArray → Except ε ByteArray) (inp out : String) (fs : FS) :
    runFS inp out (renderProgram render) fs =
      match render (fs inp) with
      | .ok png => (.ok (), fs.write out png)
      | .error e => (.error e, fs)
```

The remaining three are corollaries: `renderProgram_error_no_write` (on error,
nothing changed), `renderProgram_ok_output` (on success, the output path holds
the bytes), `renderProgram_ok_frame` (on success, nothing else moved).

---

## 2. Enforced without a theorem

- **There are exactly two effects.** `Op` has two constructors, `readInput` and
  `writeOutput`. A program that opens a socket or reads a second file cannot be
  *written down*, so no theorem is needed. This is the strongest guarantee in
  the project and it is structural.
- **Everything terminates.** No `partial` anywhere, so Lean's termination
  checker has accepted every definition. Note what this does *not* say: it
  bounds nothing about how long.
- **No floats, no FFI, no `unsafe`, no dependencies.** Project invariants in
  `tasks/README.md`, kept by review and the build, not by a proof.

---

## 3. Checked at runtime

These are real protections, but they are `if` statements, not theorems.

- Canvas dimensions ≤ 16384 and total pixels ≤ 16777216.
- XML nesting depth ≤ 64; element count ≤ 1000000.
- Fuel limits on gradient `href` chains, clip nesting, composite glyphs.
- A layer-pixel budget for group opacity.

---

## 4. Not established

Read this section as the specification's honest edge.

**The output is not proved to be a valid PNG.** There is no PNG specification in
Lean here. The encoder is ordinary code, tested against a real decoder.

**The output size is not proved bounded.** `render` checks dimensions at
runtime, but no theorem relates the returned `ByteArray`'s length to them.

Work in progress in `proofs/SizeBound.lean`, which is deliberately outside the
`LeanSvg` library so its holes cannot reach `lake build`. Current state: the
supporting lemmas are proved, and the two theorems that would actually
establish the bound are `sorry`, so they report `sorryAx` and prove nothing
yet. The intended statement is about the `ByteArray` that `Png.encode`
returns, not about the file on disk — what the operating system does with
those bytes is outside the model either way.

**No-clobber is not proved, and cannot currently be stated.** The model says
`FS := String → ByteArray`: every path has contents, so a missing file reads as
empty and "this file already exists" is not expressible. Until the model
changes, the renderer may overwrite anything at the output path. Planned as
M3b item 1, and it is the next one to do.

**Input and output paths are not required to differ.** `lean-svg a.svg a.svg`
reads the file and then overwrites it. `runFS_frame` is still true, because the
output path is the one path permitted to change. The theorem is honest; it
protects less than "only touches the two files you named" suggests. No-clobber
subsumes this, which is why it is the priority.

**Time and memory are not bounded.** Termination is guaranteed, duration is not.

**Input size is not limited.** No maximum on the input file.

**`Prog.execIO` is trusted, not proved.** Six lines mapping the two operations
onto `IO.FS.readBinFile` and `IO.FS.writeBinFile`. The theorems describe the
model; this function is the claim that the model corresponds to reality. It
inherits whatever the Lean runtime and the operating system do, including
symlinks, permissions and races.

**Rendering fidelity is empirical and always will be.** Measured against resvg:
a file passes when ≥ 99% of pixels are within 8 levels. That is a measurement,
not a claim, and the reference is another program, not a specification.

---

## 5. What a reader is actually trusting

In order of how much weight each carries:

1. **The model.** `FS` and `runFS` define what the theorems mean. A wrong model
   makes a correct proof worthless — see no-clobber above for a live example.
2. **`execIO`**, six lines, unproved.
3. **The Lean kernel and toolchain** (v4.34.0), and `propext`.
4. **The invariants** in `tasks/README.md`, kept by review rather than by types.

Everything else in the renderer is a pure function from `ByteArray` to
`Except String ByteArray`, and the theorems above say exactly what happens to
the filesystem on either outcome.
