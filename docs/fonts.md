# Font provenance

## JetBrains Mono (UI body/heading/eyebrow typeface)

- **File:** `assets/fonts/JetBrainsMonoNL-Regular.ttf`
- **Family:** JetBrains Mono NL (the **"No Ligatures"** build — the `NL` suffix)
- **Weight/style shipped:** Regular (400) only. Text is regular-weight
  throughout (body 14 / small 11 / heading 21 logical px); no bold/italic is packaged.
- **Upstream:** https://github.com/JetBrains/JetBrainsMono
- **Release asset:** the `JetBrainsMono-*.zip` release ships `fonts/ttf/JetBrainsMonoNL-Regular.ttf`
  alongside the ligature build; the `NL` variant is the deligatured cut.
- **License:** SIL Open Font License, Version 1.1 (OFL-1.1).
  - Verbatim license + JetBrains copyright notice: `assets/fonts/JetBrainsMono-OFL.txt`
    (fetched from https://raw.githubusercontent.com/JetBrains/JetBrainsMono/master/OFL.txt).
  - OFL §2 **requires** that each redistributed copy carry the copyright notice and this
    license; the build's install step copies `JetBrainsMono-OFL.txt` next to the packaged
    binary so shipped builds satisfy that condition.
  - **Reserved Font Name:** "JetBrains Mono". We ship the font **unmodified** under its
    original name, so OFL §3 (no Reserved Font Name on a *modified* version) is not
    triggered — we are redistributing the Original Version, not a derivative.

## Why the "No Ligatures" (NL) build

Ligatures are disabled in two layers, the NL build and the render path:

1. **Asset:** the `NL` cut has no ligature glyphs/rules baked in, so the shaper cannot
   substitute an `->`/`==`/`!=` ligature even if asked.
2. **Render path:** tracked text is placed per codepoint-cluster in `features/text.zig`
   (see the tracking advance routine), which never feeds multi-codepoint runs to a
   shaper, so no ligature can form regardless of the font.

## Kenney fonts (unrelated)

`assets/fonts/License.txt` covers the **Kenney** display fonts (CC0). It does **not** cover JetBrains Mono; the OFL file above is JetBrains Mono's license.
