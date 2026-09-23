import LeanSvg

/-!
# Command-line entry point (trusted shell)

This file is the only code that runs in `IO` besides `Prog.execIO`.  It parses
arguments, builds the `Prog` program from the pure `render`, hands it to the
interpreter, and prints an error message to stderr on failure.
-/

open LeanSvg

def usage : String :=
  "usage: lean-svg <input.svg> <output.png> [--width N] [--zoom Z] [--background COLOR]\n" ++
  "                [--viewport X Y W H] [--threads N]\n" ++
  "  --viewport X Y W H  render only the W x H window whose top-left corner is\n" ++
  "                      at (X, Y) in the zoomed image; X and Y are integers and\n" ++
  "                      may be negative.  The zoom is still whatever --width or\n" ++
  "                      --zoom asks for, so a viewer can tile a large virtual\n" ++
  "                      image; the size limits apply to the tile.  Zoom factors\n" ++
  "                      above 4096x are clamped.\n" ++
  "  --threads N         render the image on up to N threads, as horizontal\n" ++
  "                      bands (0 or 1 = serial, the default).  The output is\n" ++
  "                      byte-identical whatever N is.  Set LEAN_NUM_THREADS to\n" ++
  "                      size the runtime's worker pool."

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
  match parseArgs args none with
  | some (inp, out, opts) =>
    if out == "" then
      IO.eprintln usage
      return 2
    let clobberError := s!"refusing to overwrite existing file {out}"
    let result ← (Prog.renderProgram clobberError (render opts)).execIO ⟨inp⟩ ⟨out⟩
    match result with
    | .ok () => return 0
    | .error e =>
      IO.eprintln s!"lean-svg: error: {e}"
      return 1
  | none =>
    IO.eprintln usage
    return 2
