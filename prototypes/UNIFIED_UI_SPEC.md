# Human Action — Unified UI Spec (Act I & Act II)

Reconciles the two vetted prototypes (`act-i.html`, `act-ii.html`) into one shared
component and vocabulary contract. Act II is a deliberate evolution of Act I, not a
different product: the city grows, the economy matures, but the same instruments are
recognizable across acts.

Legend: **[decided]** = confirmed design intent. **[proposal]** = resolves an open
drift/question and is open to revision.

---

## 1. Economy & resource model

- **[decided]** Act I uses a single generic stock, **Materials (MA)**. Act II replaces it
  with six typed resources: **Food, Water, Fuel, Metal, Minerals, Biomass**.
- **[decided]** Entering Act II, **Materials convert 1:1 into Biomass**. Recipe/action
  costs expressed in Materials (Act I) and Biomass (Act II) **must be numerically
  identical** for the same recipe. Example: Garden bed = `8` in both (`8m` / `8 biomass`).
  Any same-named recipe whose Act I "m" cost differs from its Act II "biomass" cost is a
  bug to fix, not a design choice.
- **[decided]** Act II introduces **Coin** as currency. Act I has no coin. The merchant in
  Act II trades for coin; the passerby in Act I trades by barter.
- **[decided]** Population and typed resources exist only from Act II onward.
- **[decided]** Energy is a **flow**, not a stockpile. It is never in the stockline.

---

## 2. Header (HUD) — shared token format

Both acts use the same `LABEL: value` token format with **two-letter labels** and a `|`
separator. Tokens present depend on the act.

### 2.1 Stockline tokens

| Token | Label | Act I | Act II |
|-------|-------|:----:|:-----:|
| Vigor      | `VI` | yes | yes |
| Population | `PO` | no  | yes |
| Coin       | `CO` | no  | yes |
| Food       | `FO` | yes | yes |
| Materials  | `MA` | yes | no  |
| Water      | `WA` | no  | yes |
| Fuel       | `FU` | no  | yes |
| Metal      | `ME` | no  | yes |
| Minerals   | `MI` | no  | yes |
| Biomass    | `BI` | no  | yes |

- **[proposal]** Promote Act I's `V:`/`F:`/`M:` to the two-letter scheme `VI FO MA`.
- **[decided]** Act II uses two-letter labels (`FO WA FU ME MI BI`); one letter no longer
  disambiguates.
- **[proposal]** Two-letter labels for the meta stats too: `VI`, `PO`, `CO`.
- Low/zero stocks keep the `low` value class (existing Act II behavior).

### 2.2 Runline (right side): Act/Day + Energy

- Act/Day unchanged: `Act II · Day 43`.
- **[proposal]** **Energy lives in the runline**, shown as a rate (generated/consumed), not
  a stock. Suggested format: `⚡ +12 / −9 /d` or net `⚡ +3/d`. Distinct from the
  `LABEL: value` stockline pairs so it never reads as a stockpile.
- Applies to both acts (Act I may show a simpler `⚡ −Ne/d` if it surfaces energy at all).

---

## 3. Trade modal — shared skeleton, act-specific vocabulary

**[decided]** Passerby (Act I) → Merchant (Act II) is intentional (the city evolves and now
has a moneyed trader). **[proposal]** They must feel like the same instrument, so both use
one modal skeleton driven by an identity map.

### 3.1 Shared structure (identical in both)
Header (kicker + title + close) · direction tabs · body grid
(their-stock | preview | your-stock) · footer (note + LEAVE + primary CTA).

### 3.2 Vocabulary map

| Slot | Act I (barter) | Act II (coin) |
|------|----------------|---------------|
| Kicker | `PASSERBY · {N} DAYS LEFT` | `MERCHANT · MARKET OPEN {N} DAYS` |
| Title | `What will you trade?` | `What will you trade?` |
| Tabs | `BUY` / `SELL` | `BUY` / `SELL` |
| Their column heading | `THEIR STOCK` | `THEIR STOCK` |
| Your column heading | `YOU HOLD` | `YOU HOLD` |
| Give label (buy) | `YOU GIVE` | `YOU PAY` |
| Give label (sell) | `YOU GIVE` | `YOU GIVE` |
| Receive label | `YOU RECEIVE` | `YOU RECEIVE` |
| CTA | `TRADE →` | `BUY →` / `SELL →` |
| Footer note | barter ratios, finite stock, limited time | coin prices, finite stock, limited market time |

- **[proposal]** Unify title, tab labels, and column headings across acts (was
  "BUY FROM THEM"/"SELL YOUR STOCK", "PASSERBY STOCK"/"MERCHANT STOCK",
  "YOU HOLD"/"YOUR PURSE & STOCK").
- **[proposal, item 3]** The give-label swap function exists in **both** acts (shared code).
  Act I's map returns `YOU GIVE` for both buy and sell (barter is symmetric); Act II returns
  `YOU PAY` (buy) / `YOU GIVE` (sell). Receive label constant.
- **[proposal]** Rename CSS class `passerby-strip` → shared `merchant-strip` (the stylesheet
  already duplicates the two selectors; collapse to one). Element becomes act-neutral;
  copy differs via the identity map. Signal glyph: `● PASSERBY` (Act I) / `● MERCHANT`
  (Act II) still varies, set from the map.

---

## 4. Actions surface

- **[decided]** Act I stays a static 5-tile grid. Act II is the searchable/sortable catalog
  (search bar, sort panel, `in:/out:/type:/state:` query syntax). Act I does not need this.
- **[proposal, item 8]** Normalize the **action tile** to Act II's format in both acts:
  - Metrics string: `−{energy}e · {duration}` (middot separator).
  - Optional `action-state` sub-line, rendered only when a state copy exists. Act I tiles
    (all "ready") omit it. Same `renderActionTile()` contract.
- **[decided, item 9]** Yields reference the act's resource model: Act I materials
  (`+3–5m`), Act II biomass (`+3–5b`). Same numbers where the recipe is the same.
- Distribution icons: shared `distributionLabels` map for `alt` text in both acts (keep
  "Poisson distribution" capitalization consistent).

---

## 5. Build surface

- **[decided, item 11]** Adopt **Act II's BUILD** everywhere: search box + sort dropdown
  panel. Drop Act I's chip filters (SORT/SHOW chips, "□ built" toggle).
- **[decided, item 14]** **Remove the "blocked" state entirely.**
  - Recipes/actions the player cannot possibly do are **not shown**.
  - Recipe states reduce to: `ready`, `reach` (in-reach, short on inputs), `owned`.
  - When a prerequisite becomes satisfied, the recipe **appears** and the **event log**
    announces it, e.g. `A new recipe is within reach: Fishing net.`
  - Removes Act I's "needs Split wood" and Act II's "needs {Tech}" rows.
- **[decided, item 14]** Rename **"good" → "recipe"** throughout (headings, counts, summary).
- **[proposal, item 13]** Normalize row schema to Act II's data-generated model:
  - Rows generated from a recipe object (no hand-written HTML).
  - Name cell = `<strong>{name}</strong><small>{type}</small>` in both acts.
  - `type` enum: generator / tool / material / storage / comfort / transport.
  - Drop Act I's `data-tier` (crude/made) and `data-effect` category enum.
  - Column order (both): name · cost · time · effect · state · action.
- **[proposal, item 12]** Summary wording (both): `{visible} of {total} recipes shown`.
  Drop the "· N materials on hand" suffix (duplicates the stockline).

---

## 6. End-of-act goal card — shared `milestone-goal` component

- **[decided, item 15]** Different buildings by design: **Shelter** (Act I) vs **Exchange**
  (Act II). But both use **one shared card component**.
- **[decided]** Adopt the **collapsible disclosure** for both (bar → details).
- **[proposal]** Shared anatomy:
  - **Bar**: `<strong>{title}</strong>` + readiness pill + compact summary +
    `details ↓ / close ↑` toggle + primary action button.
  - **States** (shared): `locked → unfunded → ready → done`.
    - Act I Shelter: locked → unfunded (inputs short) → ready → built.
    - Act II Exchange: locked → unfunded → ready → standing (opens Act III).
  - **Requirements row**: same markup; act-specific tokens.
    - Act I: `VIGOR · FOOD · RECIPES · MATERIALS`.
    - Act II: `RING4 · PEOPLE · BIOMASS · MINERALS · METAL`.
  - **[proposal]** Promote Act I Shelter from **static to live** (recompute readiness on
    resource change), matching Act II, so both behave identically.

---

## 7. Structure / research tab

- **[decided, item 7 & 16]** STRUCTURE tab and the hex research board exist only in Act II.
  Population is an Act II concept. Act I has ACTIONS + BUILD only.

---

## 8. Holdings side rail

- **[proposal, item 17]** Adopt Act II's **per-view collapse memory**
  (`holdingsCollapsedByView`) as the shared model. Act I (single view) degenerates to the
  same behavior.
- **[decided, item 17]** **Entering STRUCTURE always collapses holdings by default**, and
  unlike other views it **forces collapse on each entry** (does not restore remembered
  state). Actions/Build restore their remembered state.
- **[decided, item 18]** Holdings "MARGINS" contents are act-specific by design (resource
  renaming intentional); the *set* of margin rows is not fixed across acts.

---

## 9. Event log footer — shared component

- **[proposal, item 19]** Both acts: `<footer class="screen-footer" id="event-log" ...>`
  with the same `addLog(message)` contract.
- Act II additionally hides the log on the STRUCTURE tab; Act I has no such logic but keeps
  the identical id and API.
- **[decided, item 14]** The log is the channel for "recipe/action unlocked" announcements
  now that "blocked" rows are gone.

---

## 10. Body panel (eating policy)

- **[proposal, item 20]** Extract the act-specific constants into a labeled config; make
  `updateEatingPolicy()` identical across acts:
  ```js
  // Act I
  const bodyConfig = { baseCoverage: 5.2, baseRecovery: 0.224 };
  // Act II
  const bodyConfig = { baseCoverage: 10.3, baseRecovery: 0.448 };
  // shared:
  const coverage = bodyConfig.baseCoverage / rate;
  const recovery = bodyConfig.baseRecovery / rate;
  ```
- Eating-policy words, slider math, and ARIA text remain shared/identical.

---

## Normalization checklist (drift → action)

| # | Item | Decision | Action |
|---|------|----------|--------|
| 1 | passerby→merchant | decided | keep; shared modal skeleton |
| 2 | modal innards | proposal | one skeleton + vocabulary map (§3) |
| 3 | preview give-label | proposal | shared swap fn; Act I static GIVE (§3.2) |
| 4 | barter vs coin | decided | Coin = Act II only |
| 5 | materials vs typed | decided | 1:1 Materials→Biomass; equal costs |
| 6 | header glyphs | proposal | two-letter tokens; energy in runline (§2) |
| 7 | actions grid vs catalog | decided | Act I static, Act II catalog |
| 8 | tile metric format | proposal | Act II format `−Xe · Yh`, optional state line |
| 9 | yields resource | decided | act-specific units, equal numbers |
| 10 | dist alt text | proposal | shared `distributionLabels` map |
| 11 | build filters | decided | adopt Act II BUILD |
| 12 | summary wording | proposal | `{n} of {m} recipes shown` |
| 13 | row schema | proposal | Act II data-generated schema both acts |
| 14 | blocked state | decided | remove; hide undoable; log unlocks; "recipe" |
| 15 | goal cards | decided/proposal | shared `milestone-goal`; both collapsible |
| 16 | no STRUCTURE in Act I | decided | keep |
| 17 | holdings collapse | proposal/decided | per-view memory; STRUCTURE forces collapse |
| 18 | margins contents | decided | act-specific |
| 19 | footer id | proposal | shared `id="event-log"` + `addLog()` |
| 20 | body constants | proposal | extract to `bodyConfig` |
