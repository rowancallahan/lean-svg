# Embedded fonts

Every font here is under the **SIL Open Font License 1.1**. The fonts are
subsetted (hinting dropped, only the `kern` layout feature kept) and, for
variable fonts, pinned to one static instance; the OFL permits both. None of
the families embedded here uses a Reserved Font Name in its own name. Noto
Sans SC/KR carry Adobe's copyright with the Reserved Font Name "Source" (from
Source Han Sans); the modified versions here keep the family names "Noto Sans
SC"/"Noto Sans KR" and do not use "Source".

`LeanSvg/FontSet.lean` lists them in fallback order (the order below).

| Module | Font | Version | Scripts | cmap entries | Embedded bytes | Lean source | Licence |
|---|---|---|---|---:|---:|---:|---|
| NotoSans | Noto Sans Regular | 2.000 | Latin, Greek, Cyrillic | 2793 | 241,000 | 322,624 | LICENSE-OFL.txt |
| NotoSansBold | Noto Sans Bold | 2.000 | Latin, Greek, Cyrillic | 2793 | 241,624 | 323,461 | LICENSE-OFL.txt |
| NotoSansItalic | Noto Sans Italic | 2.000 | Latin, Greek, Cyrillic | 2793 | 254,260 | 340,315 | LICENSE-OFL.txt |
| Mplus1p | Mplus 1p Regular | 1.061 | Japanese (kana, JIS kanji), Latin | 8331 | 1,728,720 | 2,336,619 | LICENSE-OFL-Mplus1p.txt |
| NotoSansSC | Noto Sans SC | 2.004, wght=400 | Chinese (Simplified, much Traditional), kana | 30890 | 10,370,644 | 13,836,062 | LICENSE-OFL-NotoSansCJK.txt |
| NotoSansKR | Noto Sans KR | 2.004, wght=400 | Korean (Hangul, Hanja) | 23174 | 5,743,856 | 7,699,339 | LICENSE-OFL-NotoSansCJK.txt |
| NotoSansThai | Noto Sans Thai | 2.002, wght=400 wdth=100 | Thai | 426 | 39,244 | 53,590 | LICENSE-OFL-NotoScripts.txt |
| NotoSansArmenian | Noto Sans Armenian | 2.008, wght=400 wdth=100 | Armenian | 430 | 44,528 | 60,650 | LICENSE-OFL-NotoScripts.txt |
| NotoSansGeorgian | Noto Sans Georgian | 2.005, wght=400 wdth=100 | Georgian | 509 | 59,744 | 80,992 | LICENSE-OFL-NotoScripts.txt |
| NotoSansEthiopic | Noto Sans Ethiopic | 2.102, wght=400 wdth=100 | Ethiopic | 860 | 346,096 | 463,133 | LICENSE-OFL-NotoScripts.txt |
| Amiri | Amiri Regular | 000.109 | Arabic (and Latin) | 1674 | 535,420 | 715,618 | LICENSE-OFL-Amiri.txt |
| NotoSansHebrew | Noto Sans Hebrew | 3.001, wght=400 wdth=100 | Hebrew | 464 | 46,560 | 63,375 | LICENSE-OFL-NotoScripts.txt |
| NotoSansDevanagari | Noto Sans Devanagari | 2.003 | Devanagari | 555 | 190,080 | 254,796 | LICENSE-OFL-NotoScripts.txt |
| **Total** | | | | | **19,841,776** | **26,550,574** | |

Sources (all `glyf` TrueType outlines):

- Noto Sans Regular/Bold/Italic: https://github.com/notofonts/latin-greek-cyrillic,
  the `NotoSans-{Regular,Bold,Italic}.ttf` files of the resvg test suite
  (`tests/corpora/resvg-test-suite/fonts`), the same files T25 subsetted.
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

Each module holds its font as an `Array String` of base64 chunks
(`Font.base64DecodeChunks`, decoded and parsed only when a text run needs that
font) and a packed cmap-coverage string (`Font.decodeRanges`) that font
fallback reads without decoding the font. Base64 costs 4/3 of the font size
in the binary where T25's hex cost 2×; `lake build` compiles the 25 MB of
source in seconds (see `tasks/T91-fonts.md`).

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

## Not embedded

- **Emoji**: not now (Rowan's decision); colour emoji are bitmap/COLR, not `glyf`.
- Noto Sans JP/TC: Mplus 1p and Noto Sans SC already cover kana and most
  Traditional characters; they would add ~20 MB for little reach.
