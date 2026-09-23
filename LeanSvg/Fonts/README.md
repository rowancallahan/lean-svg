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
| NotoSans | Noto Sans Regular | 2.000 | Latin, Greek, Cyrillic | 2793 | 241,000 | 323,045 | LICENSE-OFL.txt |
| NotoSansBold | Noto Sans Bold | 2.000 | Latin, Greek, Cyrillic | 2793 | 241,624 | 323,886 | LICENSE-OFL.txt |
| NotoSansItalic | Noto Sans Italic | 2.000 | Latin, Greek, Cyrillic | 2793 | 254,260 | 340,742 | LICENSE-OFL.txt |
| Mplus1p | Mplus 1p Regular | 1.061 | Japanese (kana, JIS kanji), Latin | 8331 | 1,728,720 | 2,337,045 | LICENSE-OFL-Mplus1p.txt |
| NotoSansSC | Noto Sans SC | 2.004, wght=400 | Chinese (Simplified, much Traditional), kana | 30890 | 10,370,644 | 13,836,489 | LICENSE-OFL-NotoSansCJK.txt |
| NotoSansKR | Noto Sans KR | 2.004, wght=400 | Korean (Hangul, Hanja) | 23174 | 5,743,856 | 7,699,771 | LICENSE-OFL-NotoSansCJK.txt |
| NotoSansThai | Noto Sans Thai | 2.002, wght=400 wdth=100 | Thai | 426 | 39,244 | 54,016 | LICENSE-OFL-NotoScripts.txt |
| NotoSansArmenian | Noto Sans Armenian | 2.008, wght=400 wdth=100 | Armenian | 430 | 44,528 | 61,080 | LICENSE-OFL-NotoScripts.txt |
| NotoSansGeorgian | Noto Sans Georgian | 2.005, wght=400 wdth=100 | Georgian | 509 | 59,744 | 81,426 | LICENSE-OFL-NotoScripts.txt |
| NotoSansEthiopic | Noto Sans Ethiopic | 2.102, wght=400 wdth=100 | Ethiopic | 860 | 346,096 | 463,558 | LICENSE-OFL-NotoScripts.txt |
| **Total** | | | | | **19,069,716** | **25,521,058** | |

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

## Not embedded

- **Arabic** (Amiri in the test suite; Noto Naskh/Sans Arabic) and **Hebrew**:
  need right-to-left bidi reordering, and Arabic also joining forms (GSUB
  `init`/`medi`/`fina`). Unshaped, left-to-right Arabic is not recognisably
  right, so neither is embedded (bidi/RTL scope is an open question for Rowan).
- **Devanagari** and the other Indic scripts: need reordering (the pre-base
  vowel sign `ि`) and conjunct formation.
- **Emoji**: not now (Rowan's decision); colour emoji are bitmap/COLR, not `glyf`.
- Noto Sans JP/TC: Mplus 1p and Noto Sans SC already cover kana and most
  Traditional characters; they would add ~20 MB for little reach.
