import MicroSvg

/-!
# Command-line entry point (trusted shell)

This file is the only code that runs in `IO` besides `Prog.execIO`.  It parses
arguments, builds the `Prog` program from the pure `render`, hands it to the
interpreter, and prints an error message to stderr on failure.
-/

open MicroSvg

def usage : String :=
  "usage: microsvg <input.svg> <output.png> [--width N] [--zoom Z] [--background COLOR]"

def parseArgs : List String → Option (String × String × Options) → Option (String × String × Options)
  | [], acc => acc
  | "--width" :: n :: rest, some (i, o, opts) =>
    match n.toNat? with
    | some w => parseArgs rest (some (i, o, { opts with width := some w }))
    | none => none
  | "--zoom" :: z :: rest, some (i, o, opts) =>
    match parseNumberAll z.toUTF8 with
    | some v => if v > 0 then parseArgs rest (some (i, o, { opts with zoom := some v })) else none
    | none => none
  | "--background" :: c :: rest, some (i, o, opts) =>
    match Svg.parsePaint c.toUTF8 with
    | some (.solid col) => parseArgs rest (some (i, o, { opts with background := some col }))
    | _ => none
  | a :: rest, acc =>
    if a.startsWith "--" then none
    else match acc with
      | none => parseArgs rest (some (a, "", {}))
      | some (i, "", opts) => parseArgs rest (some (i, a, opts))
      | some _ => none

def main (args : List String) : IO UInt32 := do
  match parseArgs args none with
  | some (inp, out, opts) =>
    if out == "" then
      IO.eprintln usage
      return 2
    let result ← (Prog.renderProgram (render opts)).execIO ⟨inp⟩ ⟨out⟩
    match result with
    | .ok () => return 0
    | .error e =>
      IO.eprintln s!"microsvg: error: {e}"
      return 1
  | none =>
    IO.eprintln usage
    return 2
