/-!
# `main`, explained on a toy

This file has the same shape as `Main.lean`, with a fake renderer that
upper-cases a text file.  It is not part of the build (`lake build` does not
see it) and imports nothing from this project.  Run it with

    echo hello > /tmp/in.txt
    lake env lean --run docs/learn/MainExplained.lean /tmp/in.txt /tmp/out.txt
    echo $?            # 0; /tmp/out.txt now holds HELLO
    lake env lean --run docs/learn/MainExplained.lean /tmp/in.txt /tmp/out.txt
    echo $?            # 1: /tmp/out.txt exists, nothing is overwritten

and check the theorems at the bottom with `lake env lean docs/learn/MainExplained.lean`
(no output means every proof was accepted).
-/

/-! ## The pure part

A pure function only computes a value from its arguments: it cannot read
files, print, or look at the clock.  Lean checks this through the type: a
function that can do those things has `IO` in its result type. -/

/-- The fake renderer.  `Except String String` means the result is one of two
things: `.ok t` (success, carrying the output text `t`) or `.error m`
(failure, carrying a message `m`).  `.ok` is short for `Except.ok`; the
expected type tells Lean which `ok` is meant. -/
def fakeRender (text : String) : Except String String :=
  if text == "" then .error "empty input"
  -- `text.toUpper` is dot notation: it means `String.toUpper text`.
  else .ok text.toUpper

/-- The output path's companion file, like `Cli.warnPath`. -/
def notesPath (out : String) : String := out ++ ".notes.txt"

/-! ## The `IO` part -/

/-- Create `path` and write `text` to it.  `.writeNew` opens the file
exclusively: if something already exists at `path`, this raises an `IO`
error instead of overwriting it.  `fun handle => …` is an anonymous function
that `withFile` calls with the open file. -/
def writeNewFile (path : System.FilePath) (text : String) : IO Unit :=
  IO.FS.withFile path .writeNew (fun handle => IO.FS.Handle.putStr handle text)

/-- `IO UInt32` is the type of a program that may do input/output and then
produces a number, here the exit code.  `do` starts a block of steps run in
order. -/
def main (args : List String) : IO UInt32 := do
  -- `let [input, output] := args | return 1`: if `args` is a list of exactly
  -- two strings, name them `input` and `output`; otherwise run what follows
  -- `|`, which ends `main` with exit code 1.  (`Main.lean` does the same with
  -- `let some config := Cli.parse args | return 1`.)
  let [input, output] := args | return 1
  -- `try … catch _ => …`: if any step inside raises an `IO` error (a missing
  -- input file, an output file created between the check and the write), run
  -- the `catch` branch instead.  `_` ignores the error value.
  try
    -- `←` runs an `IO` action and names its result.  `let x := e` (with `:=`)
    -- only names a pure value; `let x ← e` (with `←`) runs `e` first.
    let inputText ← IO.FS.readFile input
    let outputExists ← System.FilePath.pathExists output
    if outputExists then return 1
    -- `match` looks at the shape of a value and runs the matching line:
    -- `.error _` for a failure (`_` ignores the message), `.ok outputText`
    -- for a success, naming the text it carries.
    -- `fakeRender` is pure: no `←`, it is just called.
    match fakeRender inputText with
    | .error _ => return 1
    | .ok outputText =>
      writeNewFile output outputText
      return 0
  catch _ => return 1

/-! ## Theorems about the pure part

Each theorem is a statement after the `:` and a proof after `:=`.  Lean
checks the proof; if it is wrong, the file does not compile.  The real ones
in `spec/Cli.lean` and `spec/SizeBound.lean` have the same shape:
"if the function returned `.ok x`, then something holds of `x`". -/

/-- Empty input is an error.  `rfl` ("reflexivity"): both sides compute to the
same value. -/
theorem fakeRender_empty : fakeRender "" = .error "empty input" := rfl

/-- Any other input succeeds, with the upper-cased text. -/
theorem fakeRender_nonempty (text : String) (h : text ≠ "") :
    fakeRender text = .ok text.toUpper := by
  simp [fakeRender, h]

/-- A failure happens only for empty input: the shape of
`renderWithWarnings_rejects_large`, read the other way. -/
theorem fakeRender_error (text message : String)
    (h : fakeRender text = .error message) : text = "" := by
  by_cases hEmpty : text = ""
  · exact hEmpty
  · simp [fakeRender_nonempty text hEmpty] at h

/-- On success, the output is the upper-cased input: the shape of
`renderWithWarnings_size_le` ("if it returned `.ok`, the bytes satisfy …"). -/
theorem fakeRender_ok (text outputText : String)
    (h : fakeRender text = .ok outputText) : outputText = text.toUpper := by
  by_cases hEmpty : text = ""
  · simp [hEmpty, fakeRender_empty] at h
  · simp [fakeRender_nonempty text hEmpty] at h
    exact h.symm

/-- The companion path is never the output path, like `Cli.warnPath_ne` in `spec/Cli.lean`.
`intro` assumes the equation; comparing the two sides' lengths (`out`'s
length plus 10 against `out`'s length), `simp` finds the contradiction. -/
theorem notesPath_ne (out : String) : notesPath out ≠ out := by
  intro h
  have := congrArg String.length h
  simp [notesPath] at this
