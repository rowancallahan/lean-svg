import LeanSvg.JpegDecode

/-!
# `jpegdump`: a debug/oracle tool over `LeanSvg.JpegDecode` (T62)

`jpegdump <in.jpg> <out.rgba> [<in.jpg> <out.rgba> ...]` decodes each input
with `JpegDecode.decode` and prints one line per pair: `w h` (and writes the
straight RGBA8 pixels to the output path) or `NONE`. Used by
`tests/check_jpeg_decode.py` to compare against zune-jpeg and to fuzz.

Like `fontdump`, it is its own executable (see `lakefile.toml`); `lean-svg`
does not link it, and its file IO is outside `LeanSvg/`.
-/

def run : List String → IO UInt32
  | inp :: out :: rest => do
    let bytes ← IO.FS.readBinFile inp
    match LeanSvg.JpegDecode.decode bytes with
    | some d =>
      IO.FS.writeBinFile out d.px
      IO.println s!"{d.w} {d.h}"
    | none => IO.println "NONE"
    run rest
  | [] => return 0
  | _ => do
    IO.eprintln "usage: jpegdump <in.jpg> <out.rgba> [<in.jpg> <out.rgba> ...]"
    return 2

def main (args : List String) : IO UInt32 :=
  if args.isEmpty then run ["-"] else run args
