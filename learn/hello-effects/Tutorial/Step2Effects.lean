/-!
# Step 2 — A tiny language of effects you *can* inspect

The trick: instead of writing a program that *does* things, write a value that
*describes* what it would do.  A description is ordinary data, so you can pattern
match on it, and therefore prove things about it.

This file is the whole idea of the main project, shrunk to fit on two screens.
The only simplification is that files hold `String` instead of `ByteArray`.
-/

namespace Tutorial

/-! ## The two things a program is allowed to do

This is the most important declaration in the file.  A program may read the
input, or write the output.  There is no third constructor, so there is no
such thing as a program that opens a socket.  Not "we checked and it doesn't" —
*it cannot be written down*. -/
inductive Op where
  | read
  | write (content : String)

/-- What each operation hands back when it runs. -/
abbrev Op.Result : Op → Type
  | .read => String
  | .write _ => Unit

/-! ## Programs

A program is a finite tree: either it is finished (`done`), or it performs one
operation and then, *given that operation's result*, continues as another
program (`step`).

The function inside `step` is what makes `do`-notation work: "read the file,
**and then**, with the contents in hand, do the rest". -/
inductive Prog (α : Type) where
  | done : α → Prog α
  | step : (op : Op) → (Op.Result op → Prog α) → Prog α

namespace Prog

/-- Running one program and then another.  This is what `←` compiles to. -/
def bind : Prog α → (α → Prog β) → Prog β
  | .done a, f => f a
  | .step op k, f => .step op (fun r => bind (k r) f)

instance : Monad Prog where
  pure := Prog.done
  bind := Prog.bind

def read : Prog String := .step .read .done
def write (s : String) : Prog Unit := .step (.write s) .done

/-- Now we can use `do`-notation, exactly like `IO`, but on data we can inspect. -/
def shout : Prog Unit := do
  let s ← read
  write s.toUpper

/-! ## A model of the disk

To say what a program *means*, we need something for it to act on.  The
simplest possible model: a disk is a function from a path to its contents.
(Every path has contents; a missing file reads as `""`.  Remember this — it is
exactly the assumption Step 3 asks you to remove.) -/
abbrev Disk := String → String

/-- Overwrite one path. -/
def Disk.set (d : Disk) (path content : String) : Disk :=
  fun q => if q = path then content else d q

/-- **The meaning of a program.**  Walk the tree, feeding `read` the contents of
`inPath` and sending each `write` to `outPath`.  Returns the program's result
and the disk afterwards. -/
def run (inPath outPath : String) : Prog α → Disk → α × Disk
  | .done a, d => (a, d)
  | .step .read k, d => run inPath outPath (k (d inPath)) d
  | .step (.write s) k, d => run inPath outPath (k ()) (d.set outPath s)

/-! ## The theorems

Now that a program is data and `run` says what it means, we can finally state
the things we care about — and Lean can check them. -/

/-- **Nothing else is touched.**  In English: after running *any* program at
all, every path except the output path holds exactly what it held before.

Read the statement, not the proof.  The statement is what you are trusting;
the proof is just the kernel's problem. -/
theorem untouched (inPath outPath : String) (p : Prog α) (d : Disk)
    (q : String) (hq : q ≠ outPath) :
    (run inPath outPath p d).2 q = d q := by
  -- Induction on the shape of the program: it is either `done`, or one step
  -- followed by a smaller program.
  induction p generalizing d with
  | done a => rfl                     -- nothing ran, so nothing changed
  | step op k ih =>
    cases op with
    | read =>                          -- reading changes no file
      simp only [run]
      exact ih _ _
    | write s =>                       -- writing changes only `outPath`
      simp only [run]
      rw [ih () (d.set outPath s)]
      simp [Disk.set, hq]

/-- **The answer depends only on the input file.**  In English: if two disks
agree on the input path, every program returns the same result on both — so a
program cannot secretly read anything else. -/
theorem result_depends_only_on_input
    (inPath outPath : String) (p : Prog α) (d d' : Disk) (h : d inPath = d' inPath) :
    (run inPath outPath p d).1 = (run inPath outPath p d').1 := by
  induction p generalizing d d' with
  | done a => rfl
  | step op k ih =>
    cases op with
    | read =>
      simp only [run]
      rw [h]
      exact ih _ _ _ h
    | write s =>
      simp only [run]
      apply ih
      simp only [Disk.set]
      split <;> simp [*]

/-! ## The whole renderer, in miniature

The real project's top-level program is this shape: read, run a *pure*
function, then either write its output or report an error.  `transform` stands
in for the entire SVG renderer. -/
def program (transform : String → Except String String) : Prog (Except String Unit) :=
  .step .read fun input =>
    match transform input with
    | .ok output => .step (.write output) fun _ => .done (.ok ())
    | .error e => .done (.error e)

/-- **What the program does, completely.**  Either it fails and the disk is
untouched, or it succeeds and the output path holds exactly what `transform`
produced.  There is no third possibility. -/
theorem program_spec (transform : String → Except String String)
    (inPath outPath : String) (d : Disk) :
    run inPath outPath (program transform) d =
      match transform (d inPath) with
      | .ok output => (.ok (), d.set outPath output)
      | .error e => (.error e, d) := by
  unfold program
  simp only [run]
  cases h : transform (d inPath) with
  | ok output => simp only [run]
  | error e => simp only [run]

/-- On failure, the disk is exactly as it was.  Follows in one line. -/
theorem program_error_writes_nothing (transform : String → Except String String)
    (inPath outPath : String) (d : Disk) (e : String)
    (h : transform (d inPath) = .error e) :
    (run inPath outPath (program transform) d).2 = d := by
  rw [program_spec, h]

/-! ## The trusted part

Everything above is about the *model*.  To actually run, we need to connect the
two operations to real files.  That is this function, and it is the one piece
nobody proves — you read it and decide you believe it.  Six lines is about as
small as a trusted base gets. -/
def execIO (inPath outPath : System.FilePath) : Prog α → IO α
  | .done a => Pure.pure a
  | .step .read k => do
    let s ← IO.FS.readFile inPath
    execIO inPath outPath (k s)
  | .step (.write s) k => do
    IO.FS.writeFile outPath s
    execIO inPath outPath (k ())

end Prog
end Tutorial
