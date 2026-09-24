# Embedded fonts

Every font here is under the **SIL Open Font License 1.1**, except the DejaVu
fonts (T106), which carry the permissive Bitstream Vera / Arev licence
(`LICENSE-DejaVu.txt`: use, modify and redistribute, not sold by themselves;
modified versions must not use the names "Bitstream Vera" or "Arev" — the
embedded subsets keep the name "DejaVu"). The fonts are
subsetted (hinting dropped, only the `kern` layout feature kept) and, for
variable fonts, pinned to one static instance; the OFL permits both. None of
the families embedded here uses a Reserved Font Name in its own name. Noto
Sans SC/KR carry Adobe's copyright with the Reserved Font Name "Source" (from
Source Han Sans); the modified versions here keep the family names "Noto Sans
SC"/"Noto Sans KR" and do not use "Source".

`LeanSvg/FontSet.lean` lists them in fallback order (the order below).

| Module | Font | Version | Scripts | cmap entries | Embedded bytes | Lean source | Licence |
|---|---|---|---|---:|---:|---:|---|
| NotoSans | Noto Sans Regular | 2.000 | Latin, Greek, Cyrillic | 2793 | 272,129 | 364,692 | LICENSE-OFL.txt |
| NotoSansBold | Noto Sans Bold | 2.000 | Latin, Greek, Cyrillic | 2793 | 272,793 | 365,574 | LICENSE-OFL.txt |
| NotoSansItalic | Noto Sans Italic | 2.000 | Latin, Greek, Cyrillic | 2793 | 285,639 | 382,720 | LICENSE-OFL.txt |
| Mplus1p | Mplus 1p Regular | 1.061 | Japanese (kana, JIS kanji), Latin | 8331 | 1,728,720 | 2,337,045 | LICENSE-OFL-Mplus1p.txt |
| NotoSansSC | Noto Sans SC | 2.004, wght=400 | Chinese (Simplified, much Traditional), kana | 30890 | 10,370,644 | 13,836,489 | LICENSE-OFL-NotoSansCJK.txt |
| NotoSansKR | Noto Sans KR | 2.004, wght=400 | Korean (Hangul, Hanja) | 23174 | 5,743,856 | 7,699,771 | LICENSE-OFL-NotoSansCJK.txt |
| NotoSansThai | Noto Sans Thai | 2.002, wght=400 wdth=100 | Thai | 426 | 39,244 | 54,016 | LICENSE-OFL-NotoScripts.txt |
| NotoSansArmenian | Noto Sans Armenian | 2.008, wght=400 wdth=100 | Armenian | 430 | 44,528 | 61,080 | LICENSE-OFL-NotoScripts.txt |
| NotoSansGeorgian | Noto Sans Georgian | 2.005, wght=400 wdth=100 | Georgian | 509 | 59,744 | 81,426 | LICENSE-OFL-NotoScripts.txt |
| NotoSansEthiopic | Noto Sans Ethiopic | 2.102, wght=400 wdth=100 | Ethiopic | 860 | 346,096 | 463,558 | LICENSE-OFL-NotoScripts.txt |
| Amiri | Amiri Regular | 000.109 | Arabic (and Latin) | 1674 | 535,420 | 716,039 | LICENSE-OFL-Amiri.txt |
| NotoSansHebrew | Noto Sans Hebrew | 3.001, wght=400 wdth=100 | Hebrew | 464 | 46,560 | 63,803 | LICENSE-OFL-NotoScripts.txt |
| NotoSansDevanagari | Noto Sans Devanagari | 2.003 | Devanagari | 555 | 190,080 | 255,221 | LICENSE-OFL-NotoScripts.txt |
| NotoSansThin | Noto Sans Thin | 2.000 | Latin, Greek, Cyrillic | 2793 | 273,578 | 366,626 | LICENSE-OFL.txt |
| NotoSansLight | Noto Sans Light | 2.000 | Latin, Greek, Cyrillic | 2793 | 269,894 | 361,714 | LICENSE-OFL.txt |
| NotoSansBlack | Noto Sans Black | 2.000 | Latin, Greek, Cyrillic | 2793 | 274,404 | 367,730 | LICENSE-OFL.txt |
| DejaVuSans | DejaVu Sans Book | 2.37 | Latin, Greek, Cyrillic, symbols, maths, emoticons | 3138 | 303,681 | 407,068 | LICENSE-DejaVu.txt |
| DejaVuSansBold | DejaVu Sans Bold | 2.37 | Latin, Greek, Cyrillic, symbols | 2424 | 178,435 | 239,610 | LICENSE-DejaVu.txt |
| DejaVuSansOblique | DejaVu Sans Oblique | 2.37 | Latin, Greek, Cyrillic, symbols | 2424 | 181,794 | 244,099 | LICENSE-DejaVu.txt |
| DejaVuSansMono | DejaVu Sans Mono Book | 2.37 | Latin, Greek, Cyrillic, symbols | 2032 | 131,338 | 177,385 | LICENSE-DejaVu.txt |
| DejaVuSerif | DejaVu Serif Book | 2.37 | Latin, Greek, Cyrillic, symbols | 2069 | 148,628 | 200,257 | LICENSE-DejaVu.txt |
| Arimo | Arimo Regular | 1.341, wght=400 | Latin, Greek, Cyrillic | 1830 | 140,270 | 188,803 | LICENSE-OFL-Croscore.txt |
| ArimoBold | Arimo Bold | 1.341, wght=700 | Latin, Greek, Cyrillic | 1830 | 141,220 | 190,072 | LICENSE-OFL-Croscore.txt |
| Tinos | Tinos Regular | 1.340 | Latin, Greek, Cyrillic | 1830 | 154,997 | 208,422 | LICENSE-OFL-Croscore.txt |
| TinosBold | Tinos Bold | 1.340 | Latin, Greek, Cyrillic | 1830 | 148,256 | 199,439 | LICENSE-OFL-Croscore.txt |
| TinosItalic | Tinos Italic | 1.340 | Latin, Greek, Cyrillic | 1830 | 157,247 | 211,433 | LICENSE-OFL-Croscore.txt |
| Cousine | Cousine Regular | 1.241 | Latin, Greek, Cyrillic | 1625 | 111,478 | 150,554 | LICENSE-OFL-Croscore.txt |
| STIXTwoMath | STIX Two Math Regular | 2.12 | maths symbols and alphanumerics | 2920 | 423,839 | 567,043 | LICENSE-OFL-STIXTwo.txt |
| STIXTwoText | STIX Two Text Regular | 2.13, wght=400 | Latin, Greek, Cyrillic | 1243 | 148,480 | 199,858 | LICENSE-OFL-STIXTwo.txt |
| STIXTwoTextItalic | STIX Two Text Italic | 2.13, wght=400 | Latin, Greek, Cyrillic | 1243 | 161,928 | 217,807 | LICENSE-OFL-STIXTwo.txt |
| CMUSerif | CMU Serif Roman | 0.7.0 | Latin, Greek, Cyrillic | 1006 | 141,356 | 190,223 | LICENSE-OFL-CMU.txt |
| CMUSerifItalic | CMU Serif Italic | 0.7.0 | Latin, Greek, Cyrillic | 829 | 143,974 | 193,966 | LICENSE-OFL-CMU.txt |
| CMUSansSerif | CMU Sans Serif Medium | 0.7.0 | Latin, Greek, Cyrillic | 889 | 80,664 | 109,603 | LICENSE-OFL-CMU.txt |
| CMUTypewriter | CMU Typewriter Text Regular | 0.7.0 | Latin, Greek, Cyrillic | 877 | 106,030 | 143,461 | LICENSE-OFL-CMU.txt |
| **Total** | | | | | **23,756,944** | **31,816,607** | |

Sources (all `glyf` TrueType outlines):

- Noto Sans Regular/Bold/Italic: https://github.com/notofonts/latin-greek-cyrillic,
  the `NotoSans-{Regular,Bold,Italic}.ttf` files of the resvg test suite
  (`tests/corpora/resvg-test-suite/fonts`), the same files T25 subsetted.
  Thin/Light/Black (T97): the suite's `NotoSans-{Thin,Light,Black}.ttf`, the
  static weight instances resvg's reference images were drawn with.
- Mplus 1p: https://github.com/google/fonts/tree/main/ofl/mplus1p, the
  resvg test suite's `MPLUS1p-Regular.ttf`.
- Noto Sans SC/KR/Thai/Armenian/Georgian/Ethiopic:
  `https://github.com/google/fonts/tree/main/ofl/notosans<script>`, the
  variable `NotoSans<Script>[...].ttf` files, fetched 2026-09-23.

Regenerate one with `tests/gen_font_module.py`, e.g.

```
python3 tests/gen_font_module.py NotoSansSC[wght].ttf NotoSansSC --unicodes='*' --instance wght=400
python3 tests/gen_font_module.py NotoSans-Regular.ttf NotoSans --unicodes='*'
```

## Encoding

Each module holds its font as two `Array String`s of base64 chunks and a
packed cmap-coverage string (`Font.decodeRanges`) that font fallback reads
without touching the font. The generator moves `loca`, `hmtx`, `vmtx` and
`glyf` (in that order) to the end of the file (T94): `front` is every byte
before them and is decoded when a text run first needs the font
(`Font.parseEmbedded`; 53 KB for Noto Sans SC, 146 KB for KR), and `tail` is
the rest, which is never decoded whole: `Font.byteAt` reads an advance or a
`loca` entry, and `Font.glyphRecord` one glyph record, straight out of the
chunk strings, which Lean 4 compiles to static data. So a render pays for the
glyphs it draws, not for the font. The table bytes themselves are unchanged
(only their offsets move), which `tests/check_font.py --all --via-embedded`
checks against the original subset for every mapped codepoint.

Base64 costs 4/3 of the font size in the binary where T25's hex cost 2×;
`lake build` compiles the 25 MB of source in seconds (see `tasks/T91-fonts.md`).
`python3 tests/gen_font_module.py --from-module <Module>` re-emits a module in
the current layout from the bytes it already embeds.

## Shaped scripts (T93)

Amiri, Noto Sans Hebrew and Noto Sans Devanagari keep every GSUB/GPOS/GDEF
feature (`--layout-features='*'`), for the shaper in `LeanSvg/Shape.lean`;
the other fonts keep only `kern`. Amiri and Noto Sans Devanagari are the
resvg test suite's own files (so text in them matches the reference), Noto
Sans Hebrew comes from google/fonts (the suite has no Hebrew font; the
instancer left its name table saying "Thin", which nothing here reads).

```
python3 tests/gen_font_module.py Amiri-Regular.ttf Amiri --unicodes='*' --layout-features='*'
python3 tests/gen_font_module.py NotoSansDevanagari-Regular.ttf NotoSansDevanagari --unicodes='*' --layout-features='*'
python3 tests/gen_font_module.py 'NotoSansHebrew[wdth,wght].ttf' NotoSansHebrew --unicodes='*' --layout-features='*' --instance wght=400,wdth=100
```

## Noto Sans weights, small caps and marks (T97)

The six Noto Sans faces keep `kern`, `mark`, `mkmk`, `ccmp`, `locl`, `smcp`
and `liga` (Italic's only), for GPOS mark stacking and `font-variant:
small-caps`, and drop the `post` glyph names (`--no-glyph-names`; only the
`post` header is read), which keeps the part decoded on first use at 69 KB:

```
python3 tests/gen_font_module.py NotoSans-Thin.ttf NotoSansThin --unicodes='*' \
  --layout-features='kern,mark,mkmk,ccmp,locl,smcp,liga' --no-glyph-names
```

## Real-world families (T106)

The families matplotlib, Graphviz, PlantUML, Vega and Mermaid ask for, matched
by `LeanSvg/FamilyMatch.lean` (exact name, then alias, then CSS generic, as
Chromium on Linux does):

- **DejaVu Sans / Sans Mono / Serif 2.37** (matplotlib's default, and its
  `dejavusans` mathtext set; Chromium's `monospace`):
  https://github.com/dejavu-fonts/dejavu-fonts, release
  `dejavu-fonts-ttf-2.37.tar.bz2`.  DejaVu Sans keeps symbols, arrows, maths
  operators and mathematical alphanumerics, being the first fallback of every
  T106 family, and (T114) the Emoticons block U+1F600-1F64F, which matplotlib
  draws from it; the other faces keep text ranges only.
- **Arimo, Tinos, Cousine** in place of Liberation Sans/Serif/Mono: the
  Liberation 2.x downloads (GitHub release assets, pagure) were refused by
  this session's network policy, and Liberation 2.x is built from these
  Chrome OS core fonts with the same metrics (Arial/Helvetica,
  Times/Times New Roman, Courier/Courier New compatible).  From
  https://github.com/google/fonts/tree/main/ofl/{arimo,tinos,cousine}
  (OFL 1.1, no Reserved Font Name).  Arimo's variable font is pinned at
  wght 400 and 700.
- **STIX Two Math 2.12 and STIX Two Text 2.13** (matplotlib's `stix`/`stixsans`
  sets, STIXGeneral, STIXSize*): https://github.com/google/fonts/tree/main/ofl/
  {stixtwomath,stixtwotext}.  Reserved Font Name "TM Math", not used here.
  The `MATH` table is dropped (only `glyf` outlines are drawn).
- **CMU Serif / Serif Italic / Sans Serif / Typewriter Text 0.7.0**
  (Computer Modern Unicode, for `cmr10`, `cmmi10`, `cmss10`, `cmtt10`, …):
  https://sourceforge.net/projects/cm-unicode/, `cm-unicode-0.7.0-ttf.tar.xz`
  (CTAN was refused by the network policy).  Reserved Font Family Name
  "Computer Modern Unicode fonts", not used by the embedded family names.

All subsetted with `--no-glyph-names`, text ranges
`U+0020-007E,U+00A0-04FF,U+1E00-1EFF,U+2000-23FF,U+2500-25FF,U+FB00-FB06,U+FFFD`
(CMU: Latin/Greek/Cyrillic, punctuation, arrows, maths operators; STIX Two
Math: maths and symbol blocks, U+1D400-1D7FF), e.g.

```
python3 tests/gen_font_module.py DejaVuSans.ttf DejaVuSans --no-glyph-names --unicodes=...
python3 tests/gen_font_module.py 'Arimo[wght].ttf' ArimoBold --instance wght=700 --no-glyph-names --unicodes=...
```

## Not embedded

- **Emoji**: not now (Rowan's decision); colour emoji are bitmap/COLR, not `glyf`.
- T106, skipped: Liberation fonts themselves (download refused, see above;
  Arimo/Tinos/Cousine used instead); matplotlib's BaKoMa `cmr10.ttf` etc.
  (their licence forbids modification, which subsetting is); Microsoft core
  fonts (Arial, Times New Roman, Verdana, Trebuchet MS: not freely
  redistributable); DejaVu Sans Bold Oblique, Serif Bold/Italic, Sans Mono
  Bold, Cousine Bold, the other CMU faces (size; the nearest embedded face is
  drawn, nothing is synthesised).
- Noto Sans JP/TC: Mplus 1p and Noto Sans SC already cover kana and most
  Traditional characters; they would add ~20 MB for little reach.
