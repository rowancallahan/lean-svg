import LeanSvg.Svg

/-!
# T92 — CSS Values 4 units and CSS basic shapes

Plain `#guard` checks: this file must compile and print nothing under
`lake env lean tests/UnitsTests.lean`.
-/

open LeanSvg LeanSvg.Svg

/-! ## The Noto Sans metrics `ch`/`ic`/`cap`/`lh`/`rex` read -/

#guard Units.noto.upem == 1000
#guard Units.noto.zero == 572
-- no `水` in the embedded subset: CSS's `1em` fallback
#guard Units.noto.ideo == 1000
#guard Units.noto.cap == 714
#guard Units.noto.xHeight == 536
#guard Units.noto.ascent == 1069 && Units.noto.descent == 293 && Units.noto.lineGap == 0

/-! ## Units in a length -/

def ctx : Units.RootLen := { size := Fx.ofNat 20, vpW := Fx.ofNat 400, vpH := Fx.ofNat 200 }
def len (s : String) : Option Fx := parseTextLenAll (Fx.ofNat 10) 0 ctx s.toUTF8

#guard len "10vw" == some (Fx.ofNat 40)
#guard len "10vh" == some (Fx.ofNat 20)
#guard len "10vmin" == some (Fx.ofNat 20) && len "10vmax" == some (Fx.ofNat 40)
#guard len "10vi" == len "10vw" && len "10vb" == len "10vh"
#guard len "10svw" == len "10vw" && len "10lvh" == len "10vh" && len "10dvmax" == len "10vmax"
-- `lh` is Chromium's rounded line spacing: round(10.69) + round(2.93) = 14 px
#guard len "1lh" == some (Fx.ofNat 14)
-- root 20px: round(21.38) + round(5.86) = 27 px
#guard len "1rlh" == some (Fx.ofNat 27)
#guard len "2rem" == some (Fx.ofNat 40)
#guard len "1ic" == some (Fx.ofNat 10) && len "1ric" == some (Fx.ofNat 20)
-- unknown or doubled units stay errors
#guard len "10vx" == none && len "10vwvw" == none && len "10sv" == none

/-! ## Basic shapes -/

def env : BasicShape.Env := ⟨parseTextLenAll (Fx.ofNat 10) 0 ctx, parsePathData⟩
def ok (s : String) : Bool := (BasicShape.parse env s.toUTF8).isSome
def refOf (s : String) : Option BasicShape.RefBox := (BasicShape.parse env s.toUTF8).map (·.ref)

#guard ok "circle()" && ok "CIRCLE(30px AT 0 0) Fill-Box" && ok "circle(30 at left)"
#guard ok "ellipse()" && ok "ellipse(10% 2em at right 5px bottom 10%)"
#guard ok "inset(10px 20% round 5px 1px / 3px)" && ok "rect(auto 90% 80% auto)"
#guard ok "xywh(1px 2px 50% 3px round 1px)" && ok "polygon(evenodd, 0 0, 1px 1px, 0 5px)"
#guard ok "path('M0 0 H10 V10 Z') view-box" && ok "fill-box" && ok "stroke-box path(nonzero, \"M0 0 L1 1\")"
#guard refOf "circle()" == some .stroke && refOf "circle() border-box" == some .stroke
#guard refOf "content-box circle()" == some .fill && refOf "view-box" == some .view
-- invalid: no clip at all, like usvg's unparseable `clip-path`
#guard !ok "circle(-5px)" && !ok "circle() foo" && !ok "circle() fill-box stroke-box"
#guard !ok "circle(20px at right 10px bottom)" && !ok "xywh(0 0 -1px 5px)" && !ok "circle ()"
#guard !ok "inset(1px round)" && !ok "polygon()" && !ok "path('')" && !ok "star()"

/-! ## Geometry -/

def box : Box := ⟨Fx.ofNat 30, Fx.ofNat 40, Fx.ofNat 170, Fx.ofNat 140⟩
def outline (s : String) : Array PathCmd :=
  match BasicShape.parse env s.toUTF8 with
  | some spec => (BasicShape.build spec box).1
  | none => #[]
def startsAt (cmds : Array PathCmd) (x y : Int) : Bool :=
  match cmds.getD 0 .close with
  | .moveTo p => p.x == x && p.y == y
  | _ => false

-- `circle()` is the closest-side circle at the centre: radius 50 at (100, 90)
#guard startsAt (outline "circle()") (Fx.ofNat 150) (Fx.ofNat 90)
-- a zero radius or overlapping insets leave no outline (everything clipped)
#guard (outline "circle(closest-side at 0 0)").size == 0
#guard (outline "inset(60% 0 60% 0)").size == 0
-- `path()` is offset by the box origin
#guard startsAt (outline "path('M0 0 L10 0 L0 10 Z')") (Fx.ofNat 30) (Fx.ofNat 40)
