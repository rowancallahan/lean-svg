import LeanSvg.Render

/-!
# Command line (pure)

    lean-svg <input.svg> <output.png> [--width N] [--zoom Z] [--background COLOR]
             [--viewport X Y W H] [--threads N] [--warnings]

`parse` turns the argument list into a `Config`; `Main.lean` does the file
system calls with it.  Nothing here runs in `IO`.

What is proved about `parse` and `warnPath` is in `spec/Cli.lean`
(listed in `spec/README.md`). Trusted, not proved: the Lean runtime's `IO`
primitives and `main` in `Main.lean`, which is short enough to read by eye.
-/

namespace LeanSvg
namespace Cli

/-- What `main` needs from the command line. -/
structure Config where
  input : String
  output : String
  options : Options
  /-- `--warnings`: write the warnings text to `warnPath output`. -/
  warnings : Bool

/-- The warnings file of output path `out` (T98): `out` with
`.warnings.txt` appended, so it sits next to the PNG. -/
def warnPath (out : String) : String := out ++ ".warnings.txt"

/-- A decimal integer argument; a leading `-` is allowed. -/
def parseIntArg (s : String) : Option Int :=
  let neg := s.startsWith "-"
  let body := if neg then s.drop 1 else s
  if body.isEmpty || !body.all Char.isDigit then none
  else match body.toNat? with
    | some n => some (if neg then -(n : Int) else (n : Int))
    | none => none

/-- Positional arguments and flags, left to right.  The accumulator is
`none` before the input path, then `(input, output, options)` with output
`""` until the second positional argument.  A flag before the input path, an
unknown flag, a bad flag value or a third positional argument is `none`. -/
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

/-- `--warnings` may appear anywhere and is removed before `parseArgs` sees
the rest.  Both paths must be non-empty (an empty input path used to reach
`readBinFile ""` and fail there; the exit code, 1, is the same). -/
def parse (args : List String) : Option Config :=
  match parseArgs (args.filter (· != "--warnings")) none with
  | some (input, output, options) =>
    if input == "" || output == "" then none
    else some { input, output, options, warnings := args.contains "--warnings" }
  | none => none

end Cli
end LeanSvg
