import LeanSvg.Bidi
import LeanSvg.ShapeRun
import LeanSvg.FontSet

/-!
# `shapedump`: an oracle driver for `LeanSvg.Bidi` and `LeanSvg.Shape` (T93)

Reads lines from stdin and prints one line of JSON (or text) per line:

* `S <font module> <rtl 0|1> <kern 0|1> <hex cp> ...` shapes the codepoints
  as one run with an embedded font (`FontSet.byModule`) and prints
  `[[gid, cluster, xAdvance, xOffset, yOffset], ...]` in font units, visual
  order — what `tests/check_shape.py` compares against HarfBuzz;
* `C <hex cp> ...` prints each codepoint's `Bidi.bidiClass`;
* `M <hex cp> ...` prints each codepoint's `Bidi.mirror` (`0` for none);
* `<paraLevel> <hex cp> ...` prints the paragraph levels (`pl`, before L1),
  line levels (`lv`) and visual runs (`runs`) — what
  `tests/check_bidi.py` compares against python-bidi.

Like `fontdump`, this is a separate executable; its stdin/stdout are its only
IO, and `lean-svg` does not link it.
-/

open LeanSvg

/-- Parse a hex number (`0` on junk). -/
def parseHex (s : String) : Nat :=
  s.foldl (fun acc c => acc * 16 + Bidi.hexDigit c.toLower) 0

/-- JSON list of naturals. -/
def jsonNats (a : Array Nat) : String :=
  "[" ++ ",".intercalate (a.toList.map toString) ++ "]"

def shapeLine (ws : List String) : String :=
  match ws with
  | m :: r :: k :: cps =>
    match FontSet.byModule m with
    | none => "error: unknown font module"
    | some bs =>
      match Font.parse bs with
      | none => "error: font does not parse"
      | some f =>
        let gs := Shape.shapeRun f (Shape.Layout.ofBytes bs) (cps.toArray.map parseHex) (r == "1") (k == "1")
        "[" ++ ",".intercalate (gs.toList.map fun g =>
          s!"[{g.gid},{g.cluster},{g.xAdv},{g.xOff},{g.yOff}]") ++ "]"
  | _ => "error: usage S <module> <rtl> <kern> <hex cp>..."

def main : IO Unit := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  let mut fuel := 100000000
  while fuel > 0 do
    fuel := fuel - 1
    let line ← stdin.getLine
    if line.isEmpty then break
    let ws := (line.trimAscii.toString.splitOn " ").filter (· ≠ "")
    match ws.headD "" with
    | "S" => stdout.putStrLn (shapeLine (ws.drop 1))
    | "C" =>
      let cs := (ws.drop 1).map fun w => (repr (Bidi.bidiClass (parseHex w))).pretty
      stdout.putStrLn (" ".intercalate cs)
    | "M" =>
      let ms := (ws.drop 1).map fun w => toString ((Bidi.mirror (parseHex w)).getD 0)
      stdout.putStrLn (" ".intercalate ms)
    | _ =>
      let para := (ws.headD "0").toNat?.getD 0
      let cps := (ws.drop 1).toArray.map parseHex
      let runs := Bidi.visualRuns cps para
      let rs := "[" ++ ",".intercalate (runs.toList.map fun (a, b, l) => s!"[{a},{b},{l}]") ++ "]"
      stdout.putStrLn s!"\{\"pl\":{jsonNats (Bidi.paragraphLevels cps para)},\"lv\":{jsonNats (Bidi.levels cps para)},\"runs\":{rs}}"
    stdout.flush
