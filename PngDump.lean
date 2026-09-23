import LeanSvg.PngDecode

/-!
# `pngdump`: a debug/oracle tool over `LeanSvg.PngDecode`

`pngdump <out-dir|-> <file.png>...` decodes each file and prints one line per
file: `<path> <w> <h>` on success, `<path> none` otherwise. With an output
directory (not `-`), each decoded image is also written there as raw RGBA8
(`<basename>.rgba`) for `tests/check_png_decode.py` to compare against Pillow.

Like `fontdump`, this is its own executable (see `lakefile.toml`): `lean-svg`
does not link it, and its file IO is the only IO here. `PngDecode.decode` is
the pure, total function under test.
-/

def main (args : List String) : IO UInt32 := do
  match args with
  | outDir :: files@(_ :: _) =>
    for path in files do
      let bytes ← IO.FS.readBinFile path
      match LeanSvg.PngDecode.decode bytes with
      | some d =>
        IO.println s!"{path} {d.w} {d.h}"
        if outDir != "-" then
          let name := (System.FilePath.mk path).fileName.getD "out"
          IO.FS.writeBinFile (System.FilePath.mk outDir / (name ++ ".rgba")) d.px
      | none => IO.println s!"{path} none"
    return 0
  | _ =>
    IO.eprintln "usage: pngdump <out-dir|-> <file.png>..."
    return 2
