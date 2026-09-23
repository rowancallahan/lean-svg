import LeanSvg

/-!
# Command-line entry point (trusted shell)

This file is the only code that runs in `IO` besides `Prog.execIO`.  It parses
arguments, builds the `Prog` program from the pure `render`, hands it to the
interpreter, and maps the outcome to an exit code.  It writes nothing to
stdout or stderr, ever (T98b): the only outputs are the files the effect
layer writes and the exit code.

    lean-svg <input.svg> <output.png> [--width N] [--zoom Z] [--background COLOR]
             [--viewport X Y W H] [--threads N] [--warnings]

Exit codes: `0` success, no warnings; `2` success with warnings (by default
they are dropped; with `--warnings` they are in `<output>.warnings.txt`);
`1` failure, nothing written (bad arguments, unreadable input, an output path
that already exists, or a render error).  See README.md for the flags.
-/

open LeanSvg

/-- A decimal integer argument; a leading `-` is allowed. -/
def parseIntArg (s : String) : Option Int :=
  let neg := s.startsWith "-"
  let body := if neg then s.drop 1 else s
  if body.isEmpty || !body.all Char.isDigit then none
  else match body.toNat? with
    | some n => some (if neg then -(n : Int) else (n : Int))
    | none => none

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
  | "--viewport" :: x :: y :: w :: h :: rest, some (i, o, opts) =>
    match parseIntArg x, parseIntArg y, w.toNat?, h.toNat? with
    | some vx, some vy, some vw, some vh =>
      if vw ≥ 1 && vh ≥ 1 then
        parseArgs rest (some (i, o, { opts with viewport := some (vx, vy, vw, vh) }))
      else none
    | _, _, _, _ => none
  | "--threads" :: n :: rest, some (i, o, opts) =>
    match n.toNat? with
    | some t => parseArgs rest (some (i, o, { opts with threads := t }))
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
  let warnings := args.contains "--warnings"
  match parseArgs (args.filter (· != "--warnings")) none with
  | some (inp, out, opts) =>
    if out == "" then return 1
    let pure_ := fun b => match renderWithWarnings opts b with
      | .ok (png, ws) => .ok (png, Warn.text ws)
      | .error _ => .error ()
    let prog := if warnings then Prog.renderProgramWarn () pure_ else Prog.renderProgram () pure_
    -- An `IO` error (unreadable input, an output that appeared after the
    -- existence check) is exit code 1 like any other failure; uncaught, the
    -- runtime would print it to stderr.
    let result ← try prog.execIO ⟨inp⟩ ⟨out⟩ catch _ => return 1
    match result with
    | .ok false => return 0
    | .ok true => return 2
    | .error () => return 1
  | none => return 1
