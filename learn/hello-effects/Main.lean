import Tutorial

/-!
A runnable version of the miniature renderer from Step 2.

    lake exe hello in.txt out.txt

It reads `in.txt`, upper-cases it, and writes `out.txt`.  The "renderer" is the
pure function `shoutTransform`; everything effectful goes through `Prog`, whose
only two operations are read and write.
-/

open Tutorial.Prog

/-- The pure part.  In the real project this is the entire SVG renderer. -/
def shoutTransform (input : String) : Except String String :=
  if input.isEmpty then .error "input is empty" else .ok input.toUpper

def main (args : List String) : IO UInt32 := do
  match args with
  | [inPath, outPath] =>
    -- `program` is a *value* describing what to do; `execIO` is the trusted
    -- six lines that actually do it.
    match ← execIO inPath outPath (program shoutTransform) with
    | .ok () =>
      IO.println s!"wrote {outPath}"
      return 0
    | .error e =>
      IO.eprintln s!"hello: error: {e}"
      return 1
  | _ =>
    IO.println "hello, effects"
    IO.println "usage: lake exe hello <input.txt> <output.txt>"
    return 0
