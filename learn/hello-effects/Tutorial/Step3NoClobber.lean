/-!
# Step 3 — Your turn: no-clobber

Step 2's model has a quiet lie in it:

```lean
abbrev Disk := String → String
```

Every path has contents.  There is no such thing as a file that does not
exist — a missing file just reads as `""`.  That is convenient, and it is why
`untouched` is the strongest thing we could state there.

It also means the model cannot express the property we actually want:

> the program never overwrites a file that was already there.

This matters for a real reason.  Nothing currently stops someone running
`lean-svg picture.svg picture.svg`.  The program reads the file and then
overwrites it with a PNG.  `untouched` is still *true* — the output path is
the one path allowed to change — but it protected less than it sounded like.

**No-clobber fixes that and more:** if the program refuses to write to any path
that already exists, then the same-path case is covered automatically, along
with "oops, I overwrote my thesis".

## The exercise

Below is the skeleton.  Four things to do, in order:

1. Change the disk so a path may be absent.  `Option String` is the obvious
   choice: `none` means "no file here".
2. Add a third operation, `exists?`, that asks whether the output path is
   taken.  (Yes — this widens what a program may do.  That is a real cost, and
   you should be able to say why it is worth it.)
3. Write `program` so it checks first and fails without writing if the path is
   taken.
4. State and prove `no_clobber`.

Replace each `sorry` with real code.  `lake build` will tell you when the
statement typechecks; it will still warn about `sorry` until the proof is
done.  That is the honest signal, so do not delete the warning by deleting the
theorem.

Hints, only if you want them, are at the bottom.
-/

namespace Tutorial.Exercise

/-! ### 1. A disk where files can be absent -/

abbrev Disk := String → Option String

def Disk.set (d : Disk) (path content : String) : Disk :=
  fun q => if q = path then some content else d q

/-! ### 2. Three operations now -/

inductive Op where
  | read
  | write (content : String)
  | exists?

abbrev Op.Result : Op → Type
  | .read => String
  | .write _ => Unit
  | .exists? => Bool

inductive Prog (α : Type) where
  | done : α → Prog α
  | step : (op : Op) → (Op.Result op → Prog α) → Prog α

namespace Prog

def bind : Prog α → (α → Prog β) → Prog β
  | .done a, f => f a
  | .step op k, f => .step op (fun r => bind (k r) f)

instance : Monad Prog where
  pure := Prog.done
  bind := Prog.bind

def read : Prog String := .step .read .done
def write (s : String) : Prog Unit := .step (.write s) .done
def outputExists : Prog Bool := .step .exists? .done

/-- Reading a missing input file gives `""`, the same convention as before.
Everything else follows Step 2. -/
def run (inPath outPath : String) : Prog α → Disk → α × Disk
  | .done a, d => (a, d)
  | .step .read k, d => run inPath outPath (k ((d inPath).getD "")) d
  | .step (.write s) k, d => run inPath outPath (k ()) (d.set outPath s)
  | .step .exists? k, d => run inPath outPath (k (d outPath).isSome) d

/-! ### 3. The program that refuses to clobber

Read the input, check whether the output path is taken, and only write if it
is free. -/
def program (transform : String → Except String String) : Prog (Except String Unit) :=
  sorry

/-! ### 4. The theorem

In English: if the output path already held something, then after running the
program the disk is exactly as it was.

Write the statement first.  Getting the statement right *is* the exercise; the
proof is usually shorter than you expect. -/
theorem no_clobber (transform : String → Except String String)
    (inPath outPath : String) (d : Disk) (old : String)
    (h : d outPath = some old) :
    (run inPath outPath (program transform) d).2 = d := by
  sorry

/-! ### Worth thinking about, once it compiles

- You added an operation, so a program can now learn one bit about the world
  beyond the input file.  Does Step 2's `result_depends_only_on_input` still
  hold?  If not, what is the true statement now?  (This is the interesting
  part.  A program's output may now depend on the input file *and* on whether
  the output path is taken — and nothing more.  Try stating that.)
- `execIO` needs a third case.  What real `IO` call does `exists?` become, and
  what happens if the file appears between the check and the write?  No
  theorem about the model can save you from that; it is a property of the real
  filesystem.  Write down what you are assuming.
- Is refusing better than overwriting for a rendering tool people will run
  twice?  There is no proof-shaped answer; decide and write the reason down.

### Hints

1. `program` has the shape: `read`, then `outputExists`, then branch.  In
   `do`-notation it is about six lines.  Decide what error message a taken
   path produces.
2. For the proof, `unfold program` then `simp only [run]`, then `cases` on the
   result of `transform` and rewrite with `h`.  `Option.isSome` on `some old`
   reduces with `simp [h]`.
3. If a goal looks stuck, `sorry` the rest and check the statement typechecks
   first.  A statement that is right and unproved beats a proof of the wrong
   thing.
-/

end Prog
end Tutorial.Exercise
