# Embedded fonts

Every font here is under the **SIL Open Font License 1.1**, except the DejaVu
fonts (T106), which carry the permissive Bitstream Vera / Arev licence
(`licenses/fonts/DejaVu-LICENSE.txt`: use, modify and redistribute, not sold
by themselves; modified versions must not use the names "Bitstream Vera" or
"Arev" — the embedded subsets keep the name "DejaVu"). The fonts are
subsetted (hinting dropped, only the `kern` layout feature kept) and, for
variable fonts, pinned to one static instance; the OFL permits both. None of
the families embedded here uses a Reserved Font Name in its own name. The
licence of Noto Sans SC/KR declares the Reserved Font Name "Source" (from
Source Han Sans); the modified versions here keep the family names "Noto Sans
SC"/"Noto Sans KR" and do not use "Source".

`LeanSvg/FontSet.lean` lists them in fallback order (the order below).

The licence files linked in the table are byte-for-byte copies of upstream
files, listed with URL, SHA-256 and download date in `licenses/MANIFEST.csv`.
The copyright notices are in those files and in each font's own copyright
record (`name` ID 0), which the subsets keep unchanged;
`python3 tests/check_licenses.py --online` checks that record against the
upstream font. Where each font came from is in the "Sources" table below.

| Module | Font | Version | Scripts | cmap entries | Embedded bytes | Lean source | Licence |
|---|---|---|---|---:|---:|---:|---|
| NotoSans | Noto Sans Regular | 2.000 | Latin, Greek, Cyrillic | 2793 | 272,129 | 364,692 | [NotoSans-OFL.txt](../../licenses/fonts/NotoSans-OFL.txt) |
| NotoSansBold | Noto Sans Bold | 2.000 | Latin, Greek, Cyrillic | 2793 | 272,793 | 365,574 | [NotoSans-OFL.txt](../../licenses/fonts/NotoSans-OFL.txt) |
| NotoSansItalic | Noto Sans Italic | 2.000 | Latin, Greek, Cyrillic | 2793 | 285,639 | 382,720 | [NotoSans-OFL.txt](../../licenses/fonts/NotoSans-OFL.txt) |
| Mplus1p | Mplus 1p Regular | 1.061 | Japanese (kana, JIS kanji), Latin | 8331 | 1,728,720 | 2,337,045 | [Mplus1p-OFL.txt](../../licenses/fonts/Mplus1p-OFL.txt) |
| NotoSansSC | Noto Sans SC | 2.004, wght=400 | Chinese (Simplified, much Traditional), kana | 30890 | 10,370,644 | 13,836,489 | [NotoSansSC-OFL.txt](../../licenses/fonts/NotoSansSC-OFL.txt) |
| NotoSansKR | Noto Sans KR | 2.004, wght=400 | Korean (Hangul, Hanja) | 23174 | 5,743,856 | 7,699,771 | [NotoSansKR-OFL.txt](../../licenses/fonts/NotoSansKR-OFL.txt) |
| NotoSansThai | Noto Sans Thai | 2.002, wght=400 wdth=100 | Thai | 426 | 39,244 | 54,016 | [NotoSansThai-OFL.txt](../../licenses/fonts/NotoSansThai-OFL.txt) |
| NotoSansArmenian | Noto Sans Armenian | 2.008, wght=400 wdth=100 | Armenian | 430 | 44,528 | 61,080 | [NotoSansArmenian-OFL.txt](../../licenses/fonts/NotoSansArmenian-OFL.txt) |
| NotoSansGeorgian | Noto Sans Georgian | 2.005, wght=400 wdth=100 | Georgian | 509 | 59,744 | 81,426 | [NotoSansGeorgian-OFL.txt](../../licenses/fonts/NotoSansGeorgian-OFL.txt) |
| NotoSansEthiopic | Noto Sans Ethiopic | 2.102, wght=400 wdth=100 | Ethiopic | 860 | 346,096 | 463,558 | [NotoSansEthiopic-OFL.txt](../../licenses/fonts/NotoSansEthiopic-OFL.txt) |
| Amiri | Amiri Regular | 000.109 | Arabic (and Latin) | 1674 | 535,420 | 716,039 | [Amiri-OFL.txt](../../licenses/fonts/Amiri-OFL.txt) |
| NotoSansHebrew | Noto Sans Hebrew | 3.001, wght=400 wdth=100 | Hebrew | 464 | 46,560 | 63,803 | [NotoSansHebrew-OFL.txt](../../licenses/fonts/NotoSansHebrew-OFL.txt) |
| NotoSansDevanagari | Noto Sans Devanagari | 2.003 | Devanagari | 555 | 190,080 | 255,221 | [NotoSans-OFL.txt](../../licenses/fonts/NotoSans-OFL.txt) |
| NotoSansThin | Noto Sans Thin | 2.000 | Latin, Greek, Cyrillic | 2793 | 273,578 | 366,626 | [NotoSans-OFL.txt](../../licenses/fonts/NotoSans-OFL.txt) |
| NotoSansLight | Noto Sans Light | 2.000 | Latin, Greek, Cyrillic | 2793 | 269,894 | 361,714 | [NotoSans-OFL.txt](../../licenses/fonts/NotoSans-OFL.txt) |
| NotoSansBlack | Noto Sans Black | 2.000 | Latin, Greek, Cyrillic | 2793 | 274,404 | 367,730 | [NotoSans-OFL.txt](../../licenses/fonts/NotoSans-OFL.txt) |
| DejaVuSans | DejaVu Sans Book | 2.37 | Latin, Greek, Cyrillic, symbols, maths, emoticons | 3138 | 303,681 | 407,068 | [DejaVu-LICENSE.txt](../../licenses/fonts/DejaVu-LICENSE.txt) |
| DejaVuSansBold | DejaVu Sans Bold | 2.37 | Latin, Greek, Cyrillic, symbols | 2424 | 178,435 | 239,610 | [DejaVu-LICENSE.txt](../../licenses/fonts/DejaVu-LICENSE.txt) |
| DejaVuSansOblique | DejaVu Sans Oblique | 2.37 | Latin, Greek, Cyrillic, symbols | 2424 | 181,794 | 244,099 | [DejaVu-LICENSE.txt](../../licenses/fonts/DejaVu-LICENSE.txt) |
| DejaVuSansMono | DejaVu Sans Mono Book | 2.37 | Latin, Greek, Cyrillic, symbols | 2032 | 131,338 | 177,385 | [DejaVu-LICENSE.txt](../../licenses/fonts/DejaVu-LICENSE.txt) |
| DejaVuSerif | DejaVu Serif Book | 2.37 | Latin, Greek, Cyrillic, symbols | 2069 | 148,628 | 200,257 | [DejaVu-LICENSE.txt](../../licenses/fonts/DejaVu-LICENSE.txt) |
| Arimo | Arimo Regular | 1.341, wght=400 | Latin, Greek, Cyrillic | 1830 | 140,270 | 188,803 | [Arimo-OFL.txt](../../licenses/fonts/Arimo-OFL.txt) |
| ArimoBold | Arimo Bold | 1.341, wght=700 | Latin, Greek, Cyrillic | 1830 | 141,220 | 190,072 | [Arimo-OFL.txt](../../licenses/fonts/Arimo-OFL.txt) |
| Tinos | Tinos Regular | 1.340 | Latin, Greek, Cyrillic | 1830 | 154,997 | 208,422 | [Tinos-OFL.txt](../../licenses/fonts/Tinos-OFL.txt) |
| TinosBold | Tinos Bold | 1.340 | Latin, Greek, Cyrillic | 1830 | 148,256 | 199,439 | [Tinos-OFL.txt](../../licenses/fonts/Tinos-OFL.txt) |
| TinosItalic | Tinos Italic | 1.340 | Latin, Greek, Cyrillic | 1830 | 157,247 | 211,433 | [Tinos-OFL.txt](../../licenses/fonts/Tinos-OFL.txt) |
| Cousine | Cousine Regular | 1.241 | Latin, Greek, Cyrillic | 1625 | 111,478 | 150,554 | [Cousine-OFL.txt](../../licenses/fonts/Cousine-OFL.txt) |
| STIXTwoMath | STIX Two Math Regular | 2.12 | maths symbols and alphanumerics | 2920 | 423,839 | 567,043 | [STIXTwoMath-OFL.txt](../../licenses/fonts/STIXTwoMath-OFL.txt) |
| STIXTwoText | STIX Two Text Regular | 2.13, wght=400 | Latin, Greek, Cyrillic | 1243 | 148,480 | 199,858 | [STIXTwoText-OFL.txt](../../licenses/fonts/STIXTwoText-OFL.txt) |
| STIXTwoTextItalic | STIX Two Text Italic | 2.13, wght=400 | Latin, Greek, Cyrillic | 1243 | 161,928 | 217,807 | [STIXTwoText-OFL.txt](../../licenses/fonts/STIXTwoText-OFL.txt) |
| CMUSerif | CMU Serif Roman | 0.7.0 | Latin, Greek, Cyrillic | 1006 | 141,356 | 190,223 | [CMU-OFL.txt](../../licenses/fonts/CMU-OFL.txt) |
| CMUSerifItalic | CMU Serif Italic | 0.7.0 | Latin, Greek, Cyrillic | 829 | 143,974 | 193,966 | [CMU-OFL.txt](../../licenses/fonts/CMU-OFL.txt) |
| CMUSansSerif | CMU Sans Serif Medium | 0.7.0 | Latin, Greek, Cyrillic | 889 | 80,664 | 109,603 | [CMU-OFL.txt](../../licenses/fonts/CMU-OFL.txt) |
| CMUTypewriter | CMU Typewriter Text Regular | 0.7.0 | Latin, Greek, Cyrillic | 877 | 106,030 | 143,461 | [CMU-OFL.txt](../../licenses/fonts/CMU-OFL.txt) |
| NotoSansExtraCondensed | Noto Sans ExtraCondensed | 2.000 | Latin, Greek, Cyrillic | 2793 | 266,481 | 356,958 | [NotoSans-OFL.txt](../../licenses/fonts/NotoSans-OFL.txt) |
| **Total** | | | | | **24,023,425** | **32,173,565** | |

## Sources

The upstream font file each module was subset from, as listed in
`licenses/FONT-SOURCES.csv` (which also gives each file's SHA-256). A URL
with a `#` fragment names a file inside that archive.

| Module | Upstream font file (pinned) | Downloaded |
|---|---|---|
| NotoSans | [linebender/resvg-test-suite@d8e0643 `fonts/NotoSans-Regular.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/NotoSans-Regular.ttf) | 2026-09-24 |
| NotoSansBold | [linebender/resvg-test-suite@d8e0643 `fonts/NotoSans-Bold.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/NotoSans-Bold.ttf) | 2026-09-24 |
| NotoSansItalic | [linebender/resvg-test-suite@d8e0643 `fonts/NotoSans-Italic.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/NotoSans-Italic.ttf) | 2026-09-24 |
| Mplus1p | [linebender/resvg-test-suite@d8e0643 `fonts/MPLUS1p-Regular.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/MPLUS1p-Regular.ttf) | 2026-09-24 |
| NotoSansSC | [google/fonts@23e54b5 `ofl/notosanssc/NotoSansSC[wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf) | 2026-09-24 |
| NotoSansKR | [google/fonts@23e54b5 `ofl/notosanskr/NotoSansKR[wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanskr/NotoSansKR%5Bwght%5D.ttf) | 2026-09-24 |
| NotoSansThai | [google/fonts@23e54b5 `ofl/notosansthai/NotoSansThai[wdth,wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansthai/NotoSansThai%5Bwdth,wght%5D.ttf) | 2026-09-24 |
| NotoSansArmenian | [google/fonts@23e54b5 `ofl/notosansarmenian/NotoSansArmenian[wdth,wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansarmenian/NotoSansArmenian%5Bwdth,wght%5D.ttf) | 2026-09-24 |
| NotoSansGeorgian | [google/fonts@23e54b5 `ofl/notosansgeorgian/NotoSansGeorgian[wdth,wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansgeorgian/NotoSansGeorgian%5Bwdth,wght%5D.ttf) | 2026-09-24 |
| NotoSansEthiopic | [google/fonts@23e54b5 `ofl/notosansethiopic/NotoSansEthiopic[wdth,wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosansethiopic/NotoSansEthiopic%5Bwdth,wght%5D.ttf) | 2026-09-24 |
| Amiri | [linebender/resvg-test-suite@d8e0643 `fonts/Amiri-Regular.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/Amiri-Regular.ttf) | 2026-09-24 |
| NotoSansHebrew | [google/fonts@23e54b5 `ofl/notosanshebrew/NotoSansHebrew[wdth,wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanshebrew/NotoSansHebrew%5Bwdth,wght%5D.ttf) | 2026-09-24 |
| NotoSansDevanagari | [linebender/resvg-test-suite@d8e0643 `fonts/NotoSansDevanagari-Regular.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/NotoSansDevanagari-Regular.ttf) | 2026-09-24 |
| NotoSansThin | [linebender/resvg-test-suite@d8e0643 `fonts/NotoSans-Thin.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/NotoSans-Thin.ttf) | 2026-09-24 |
| NotoSansLight | [linebender/resvg-test-suite@d8e0643 `fonts/NotoSans-Light.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/NotoSans-Light.ttf) | 2026-09-24 |
| NotoSansBlack | [linebender/resvg-test-suite@d8e0643 `fonts/NotoSans-Black.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/NotoSans-Black.ttf) | 2026-09-24 |
| DejaVuSans | [SourceForge `dejavu-fonts-ttf-2.37.tar.bz2`, member `dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf`](https://sourceforge.net/projects/dejavu/files/dejavu/2.37/dejavu-fonts-ttf-2.37.tar.bz2/download#dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf) | 2026-09-24 |
| DejaVuSansBold | [SourceForge `dejavu-fonts-ttf-2.37.tar.bz2`, member `dejavu-fonts-ttf-2.37/ttf/DejaVuSans-Bold.ttf`](https://sourceforge.net/projects/dejavu/files/dejavu/2.37/dejavu-fonts-ttf-2.37.tar.bz2/download#dejavu-fonts-ttf-2.37/ttf/DejaVuSans-Bold.ttf) | 2026-09-24 |
| DejaVuSansOblique | [SourceForge `dejavu-fonts-ttf-2.37.tar.bz2`, member `dejavu-fonts-ttf-2.37/ttf/DejaVuSans-Oblique.ttf`](https://sourceforge.net/projects/dejavu/files/dejavu/2.37/dejavu-fonts-ttf-2.37.tar.bz2/download#dejavu-fonts-ttf-2.37/ttf/DejaVuSans-Oblique.ttf) | 2026-09-24 |
| DejaVuSansMono | [SourceForge `dejavu-fonts-ttf-2.37.tar.bz2`, member `dejavu-fonts-ttf-2.37/ttf/DejaVuSansMono.ttf`](https://sourceforge.net/projects/dejavu/files/dejavu/2.37/dejavu-fonts-ttf-2.37.tar.bz2/download#dejavu-fonts-ttf-2.37/ttf/DejaVuSansMono.ttf) | 2026-09-24 |
| DejaVuSerif | [SourceForge `dejavu-fonts-ttf-2.37.tar.bz2`, member `dejavu-fonts-ttf-2.37/ttf/DejaVuSerif.ttf`](https://sourceforge.net/projects/dejavu/files/dejavu/2.37/dejavu-fonts-ttf-2.37.tar.bz2/download#dejavu-fonts-ttf-2.37/ttf/DejaVuSerif.ttf) | 2026-09-24 |
| Arimo | [google/fonts@23e54b5 `ofl/arimo/Arimo[wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/arimo/Arimo%5Bwght%5D.ttf) | 2026-09-24 |
| ArimoBold | [google/fonts@23e54b5 `ofl/arimo/Arimo[wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/arimo/Arimo%5Bwght%5D.ttf) | 2026-09-24 |
| Tinos | [googlefonts/tinos@3b4482a `fonts/ttf/Tinos-Regular.ttf`](https://raw.githubusercontent.com/googlefonts/tinos/3b4482a99b80ea5fc75f187b1be3120a3f5905b3/fonts/ttf/Tinos-Regular.ttf) | 2026-09-24 |
| TinosBold | [googlefonts/tinos@3b4482a `fonts/ttf/Tinos-Bold.ttf`](https://raw.githubusercontent.com/googlefonts/tinos/3b4482a99b80ea5fc75f187b1be3120a3f5905b3/fonts/ttf/Tinos-Bold.ttf) | 2026-09-24 |
| TinosItalic | [googlefonts/tinos@3b4482a `fonts/ttf/Tinos-Italic.ttf`](https://raw.githubusercontent.com/googlefonts/tinos/3b4482a99b80ea5fc75f187b1be3120a3f5905b3/fonts/ttf/Tinos-Italic.ttf) | 2026-09-24 |
| Cousine | [google/fonts@23e54b5 `ofl/cousine/Cousine-Regular.ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/cousine/Cousine-Regular.ttf) | 2026-09-24 |
| STIXTwoMath | [google/fonts@23e54b5 `ofl/stixtwomath/STIXTwoMath-Regular.ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwomath/STIXTwoMath-Regular.ttf) | 2026-09-24 |
| STIXTwoText | [google/fonts@23e54b5 `ofl/stixtwotext/STIXTwoText[wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwotext/STIXTwoText%5Bwght%5D.ttf) | 2026-09-24 |
| STIXTwoTextItalic | [google/fonts@23e54b5 `ofl/stixtwotext/STIXTwoText-Italic[wght].ttf`](https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/stixtwotext/STIXTwoText-Italic%5Bwght%5D.ttf) | 2026-09-24 |
| CMUSerif | [SourceForge `cm-unicode-0.7.0-ttf.tar.xz`, member `cm-unicode-0.7.0/cmunrm.ttf`](https://sourceforge.net/projects/cm-unicode/files/cm-unicode/0.7.0/cm-unicode-0.7.0-ttf.tar.xz/download#cm-unicode-0.7.0/cmunrm.ttf) | 2026-09-24 |
| CMUSerifItalic | [SourceForge `cm-unicode-0.7.0-ttf.tar.xz`, member `cm-unicode-0.7.0/cmunti.ttf`](https://sourceforge.net/projects/cm-unicode/files/cm-unicode/0.7.0/cm-unicode-0.7.0-ttf.tar.xz/download#cm-unicode-0.7.0/cmunti.ttf) | 2026-09-24 |
| CMUSansSerif | [SourceForge `cm-unicode-0.7.0-ttf.tar.xz`, member `cm-unicode-0.7.0/cmunss.ttf`](https://sourceforge.net/projects/cm-unicode/files/cm-unicode/0.7.0/cm-unicode-0.7.0-ttf.tar.xz/download#cm-unicode-0.7.0/cmunss.ttf) | 2026-09-24 |
| CMUTypewriter | [SourceForge `cm-unicode-0.7.0-ttf.tar.xz`, member `cm-unicode-0.7.0/cmuntt.ttf`](https://sourceforge.net/projects/cm-unicode/files/cm-unicode/0.7.0/cm-unicode-0.7.0-ttf.tar.xz/download#cm-unicode-0.7.0/cmuntt.ttf) | 2026-09-24 |
| NotoSansExtraCondensed | [linebender/resvg-test-suite@d8e0643 `fonts/NotoSans-ExtraCondensed.ttf`](https://raw.githubusercontent.com/linebender/resvg-test-suite/d8e064337faf01bc5a9579187a56dbdbe3eacc72/fonts/NotoSans-ExtraCondensed.ttf) | 2026-09-24 |

Notes on the sources (all `glyf` TrueType outlines):

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
`lake build` compiles the 25 MB of source in seconds.
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
  `dejavu-fonts-ttf-2.37.tar.bz2` (the SourceForge copy in "Sources").  DejaVu Sans keeps symbols, arrows, maths
  operators and mathematical alphanumerics, being the first fallback of every
  T106 family, and (T114) the Emoticons block U+1F600-1F64F, which matplotlib
  draws from it; the other faces keep text ranges only.
- **Arimo, Tinos, Cousine** in place of Liberation Sans/Serif/Mono: the
  Liberation 2.x downloads (GitHub release assets, pagure) were refused by
  this session's network policy, and Liberation 2.x is built from these
  Chrome OS core fonts with the same metrics (Arial/Helvetica,
  Times/Times New Roman, Courier/Courier New compatible).  Arimo and
  Cousine from google/fonts `ofl/{arimo,cousine}`, Tinos from
  googlefonts/tinos (google/fonts no longer has `ofl/tinos`); pinned URLs in
  "Sources" above (OFL 1.1, no Reserved Font Name).  Arimo's variable font is pinned at
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

## Noto Sans ExtraCondensed (T118)

The suite's `NotoSans-ExtraCondensed.ttf` (typographic family "Noto Sans",
OS/2 width class 2), the face `font-stretch` selects (`FamilyMatch.pick`
matches stretch before style and weight, as fontdb does). Same options as the
T97 faces:

```
python3 tests/gen_font_module.py NotoSans-ExtraCondensed.ttf NotoSansExtraCondensed --unicodes='*' \
  --layout-features='kern,mark,mkmk,ccmp,locl,smcp,liga' --no-glyph-names
```

## Not embedded

- **Source Sans Pro** (T118, not embedded): Adobe's OFL 1.1 names the Reserved
  Font Name "Source"; the OFL counts deleting components or changing formats
  as a Modified Version (subsetting and the Lean module encoding are both),
  and §3 forbids a Modified Version from using the RFN without Adobe's written
  permission. It is not embedded, and must not be without that permission,
  under its own name or another name that `font-family="Source Sans Pro"`
  resolves to.
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
