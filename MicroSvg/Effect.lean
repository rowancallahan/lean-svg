/-!
# Effect confinement

`Prog` is the *only* monad the renderer's top-level program lives in.  It is a
free monad over exactly two operations: read the input file and write the output
file.  There is no constructor for anything else, so a value of type `Prog α`
cannot open sockets, spawn processes, read the environment, or touch any other
file.  This is enforced by the type checker, not by review.

The theorems below are stated against a model file system (`FS`, a total map
from paths to contents) and are checked by the Lean kernel:

* `runFS_frame`         : no path other than the output path is ever modified.
* `runFS_input_only`    : the program's result depends only on the input path's contents.
* `renderProgram_spec`  : the renderer program either fails (and the file system is
                          untouched) or writes exactly the bytes produced by the pure
                          `render` function to the output path.

The one trusted piece is `Prog.execIO`, the interpreter that maps the two
operations onto real `IO` calls.  It is six lines long.  Everything else in the
renderer is a pure function of a `ByteArray`.
-/

namespace MicroSvg

/-- The complete set of effects available to a renderer program. -/
inductive Op where
  | readInput
  | writeOutput (bytes : ByteArray)

/-- The value each operation returns. -/
abbrev Op.Res : Op → Type
  | .readInput => ByteArray
  | .writeOutput _ => Unit

/-- Free monad over `Op`.  A `Prog α` is a finite tree of operations ending in
a pure result. -/
inductive Prog (α : Type) : Type where
  | pure : α → Prog α
  | step : (op : Op) → (Op.Res op → Prog α) → Prog α

namespace Prog

def bind : Prog α → (α → Prog β) → Prog β
  | .pure a, f => f a
  | .step op k, f => .step op fun r => bind (k r) f

instance : Monad Prog where
  pure := Prog.pure
  bind := Prog.bind

def readInput : Prog ByteArray := .step .readInput .pure
def writeOutput (b : ByteArray) : Prog Unit := .step (.writeOutput b) .pure

/-! ## Model semantics -/

/-- A model file system: every path has some contents (missing files read as empty). -/
abbrev FS := String → ByteArray

/-- Overwrite one path in the model file system. -/
def FS.write (fs : FS) (p : String) (b : ByteArray) : FS :=
  fun q => if q = p then b else fs q

/-- Run a program against the model, reading from `inp` and writing to `out`. -/
def runFS (inp out : String) : Prog α → FS → α × FS
  | .pure a, fs => (a, fs)
  | .step .readInput k, fs => runFS inp out (k (fs inp)) fs
  | .step (.writeOutput b) k, fs => runFS inp out (k ()) (fs.write out b)

/-- **Frame theorem.** Running any program leaves every path other than `out` unchanged. -/
theorem runFS_frame (inp out : String) (p : Prog α) (fs : FS) (q : String) (hq : q ≠ out) :
    (runFS inp out p fs).2 q = fs q := by
  induction p generalizing fs with
  | pure a => rfl
  | step op k ih =>
    cases op with
    | readInput =>
      simp only [runFS]
      exact ih _ _
    | writeOutput b =>
      simp only [runFS]
      rw [ih () (fs.write out b)]
      simp [FS.write, hq]

/-- **Input-only theorem.** The result of any program depends only on the contents of `inp`. -/
theorem runFS_input_only (inp out : String) (p : Prog α) (fs fs' : FS) (h : fs inp = fs' inp) :
    (runFS inp out p fs).1 = (runFS inp out p fs').1 := by
  induction p generalizing fs fs' with
  | pure a => rfl
  | step op k ih =>
    cases op with
    | readInput =>
      simp only [runFS]
      rw [h]
      exact ih _ _ _ h
    | writeOutput b =>
      simp only [runFS]
      apply ih
      simp only [FS.write]
      split <;> simp [*]

/-! ## The renderer program -/

/-- The whole top-level program: read the input, run a pure `render`, and either
write the result or report the error.  Nothing else. -/
def renderProgram {ε : Type} (render : ByteArray → Except ε ByteArray) :
    Prog (Except ε Unit) :=
  .step .readInput fun inp =>
    match render inp with
    | .ok png => .step (.writeOutput png) fun _ => .pure (.ok ())
    | .error e => .pure (.error e)

/-- **Specification of the renderer program.**  On the model file system it either
fails and changes nothing, or succeeds and writes exactly `render input` to `out`. -/
theorem renderProgram_spec {ε : Type} (render : ByteArray → Except ε ByteArray)
    (inp out : String) (fs : FS) :
    runFS inp out (renderProgram render) fs =
      match render (fs inp) with
      | .ok png => (.ok (), fs.write out png)
      | .error e => (.error e, fs) := by
  unfold renderProgram
  simp only [runFS]
  cases h : render (fs inp) with
  | ok png => simp only [runFS]
  | error e => simp only [runFS]

/-- On error, the file system is untouched: no output file is created or modified. -/
theorem renderProgram_error_no_write {ε : Type} (render : ByteArray → Except ε ByteArray)
    (inp out : String) (fs : FS) (e : ε) (h : render (fs inp) = .error e) :
    (runFS inp out (renderProgram render) fs).2 = fs := by
  rw [renderProgram_spec, h]

/-- On success, the output path holds exactly the rendered bytes. -/
theorem renderProgram_ok_output {ε : Type} (render : ByteArray → Except ε ByteArray)
    (inp out : String) (fs : FS) (png : ByteArray) (h : render (fs inp) = .ok png) :
    (runFS inp out (renderProgram render) fs).2 out = png := by
  rw [renderProgram_spec, h]
  simp [FS.write]

/-- On success, every path other than the output path is untouched. -/
theorem renderProgram_ok_frame {ε : Type} (render : ByteArray → Except ε ByteArray)
    (inp out : String) (fs : FS) (q : String) (hq : q ≠ out) :
    (runFS inp out (renderProgram render) fs).2 q = fs q :=
  runFS_frame inp out _ fs q hq

/-! ## The trusted interpreter -/

/-- The only place real I/O happens.  Maps the two operations to file reads and
writes on the given paths.  This is the trusted computing base of the effect layer. -/
def execIO (inp out : System.FilePath) : Prog α → IO α
  | .pure a => Pure.pure a
  | .step .readInput k => do
    let b ← IO.FS.readBinFile inp
    execIO inp out (k b)
  | .step (.writeOutput b) k => do
    IO.FS.writeBinFile out b
    execIO inp out (k ())

end Prog
end MicroSvg
