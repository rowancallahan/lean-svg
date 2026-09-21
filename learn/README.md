# learn — a hello-world for the effect monad

A standalone Lean project, about 250 lines including the commentary, that
builds up the idea the main renderer rests on. Nothing here is used by
`lean-svg`; it exists to be read, edited and broken.

```bash
cd learn/hello-effects
lake build
lake exe hello                      # prints usage
echo "hello there" > /tmp/in.txt
lake exe hello /tmp/in.txt /tmp/out.txt
cat /tmp/out.txt                    # HELLO THERE
```

## What to read, in order

| file | what it shows |
|---|---|
| `Tutorial/Step1IO.lean` | what `IO` is, and why no theorem about it is possible |
| `Tutorial/Step2Effects.lean` | the whole idea: describe effects as data, model them, prove three theorems |
| `Tutorial/Step3NoClobber.lean` | **the exercise** — extend the model so files can be absent, and prove no-clobber |
| `Main.lean` | the miniature renderer, actually runnable |

Step 2 is the one to understand. It is the main project's `LeanSvg/Effect.lean`
with two simplifications: files hold `String` instead of `ByteArray`, and the
names are shorter. The theorems are the same theorems.

## The exercise

`Step3NoClobber.lean` has two `sorry`s. `lake build` will keep warning about
them until you fill them in, which is the point: a warning you have not earned
the right to silence.

The task is to make the program refuse to overwrite a file that already
exists. That also settles a real gap in the main renderer, where nothing
currently stops `lean-svg picture.svg picture.svg` from reading a file and then
overwriting it.

Get the *statement* right before you worry about the proof. A correct statement
with `sorry` under it is worth more than a finished proof of the wrong thing,
because the statement is the part a human has to trust.

## Two things worth knowing before you start

**The proof is not the interesting part.** Lean's kernel checks proofs, so
nobody needs to audit a tactic block. What you are trusting is the *statement*
plus the *model* it is stated against. If `Disk` is a bad model of a disk, a
perfect proof tells you nothing. That is exactly why Step 3 exists: Step 2's
model says every file exists, which is false, and the price of that lie is that
no-clobber cannot even be written down.

**Check what your theorem actually assumed.** Run:

```bash
lake env lean --run /dev/stdin <<'EOF'
import Tutorial
#print axioms Tutorial.Prog.untouched
EOF
```

`[propext]` means it used only propositional extensionality, which is part of
Lean's foundations. If `sorryAx` appears, the proof has a hole. If
`Classical.choice` appears, you used classical reasoning, which is fine but
worth knowing. This command is the honest audit of any Lean proof, and it takes
one second.

## Where this maps onto the real project

- `Tutorial.Op` → `LeanSvg.Op`
- `Tutorial.Prog` → `LeanSvg.Prog`
- `Disk` → `LeanSvg.FS`
- `untouched` → `runFS_frame`
- `result_depends_only_on_input` → `runFS_input_only`
- `program_spec` → `renderProgram_spec`
- `execIO` → `LeanSvg.Prog.execIO`, still six lines, still trusted

`SPEC.md` in the repository root states every one of the real theorems in
English beside its Lean form, and lists what is *not* proven.
