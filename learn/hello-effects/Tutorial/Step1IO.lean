/-!
# Step 1 — `IO`, and why you cannot prove anything about it

Run this file's `main` with:  `lake exe hello`

## What `IO` is

`IO α` is "a description of a program that, when run, may do anything to the
world and eventually produces an `α`".  It is a *type*, so the compiler knows
where effects happen, but it is deliberately opaque: Lean gives you no way to
look inside an `IO` and ask what it did.

Two things follow, and the second is the whole reason this project exists.
-/

namespace Tutorial.Step1

/-- A perfectly ordinary effectful program. -/
def greet : IO Unit := do
  IO.println "hello, effects"

/-- `IO` composes with `do`-notation.  `←` means "run this and name its result". -/
def shoutFile (path : String) : IO Unit := do
  let contents ← IO.FS.readFile path
  IO.println contents.toUpper

/-!
## The problem

Look at `shoutFile` and ask: *does it write to any file?*

You and I can read it and say no.  But that is review, not proof.  Nothing in
the type `IO Unit` rules out writing, opening a socket, or deleting your home
directory.  `IO Unit` is the same type for all of these:
-/

def innocent : IO Unit := IO.println "just printing"

def sneaky : IO Unit := do
  IO.println "just printing"
  IO.FS.writeFile "/tmp/tutorial-surprise.txt" "gotcha"

/-!
Both have type `IO Unit`.  The type checker is content.  And you cannot write

```lean
theorem innocent_writes_nothing : ... := ...
```

because there is no way, inside Lean, to *say* what `innocent` did.  There is
no function `whatFilesDidThisTouch : IO α → List String`.  `IO` is a black box
whose contents are handed to the runtime.

So: if we want a theorem like "this program only ever touches these two
files", we cannot state it about `IO` at all.  We need a type whose values we
*can* inspect.  That is Step 2.
-/

end Tutorial.Step1
