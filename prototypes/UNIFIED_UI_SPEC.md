# Human Action — Unified UI Spec (Act I & Act II)

Reconciles the vetted prototypes into one shared component and vocabulary contract: the act
shells (`act-i.html`, `act-ii.html`), the trade dialog (`trade.html`), the neighbours view
(`market.html`), the session menu (`menu.html`) and the title screen (`title.html`). The
last four are the most recent decisions and win over anything older that contradicts them.
Act II is a deliberate evolution of Act I, not a different product: the city grows, the
economy matures, but the same instruments are recognizable across acts.

**Parity rule.** The Zig game reproduces every prototype visually and functionally. Only
*content* may differ (which goods, which prices, which names): a Zig passerby may sell a
hatchet where the prototype sells a hand axe, provided the screen looks and behaves the same.

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
has a moneyed trader). One modal serves both, driven by an identity map. **`trade.html` is
the authoritative design**; `act-i.html` and `act-ii.html` frame it (`trade.html?act=i|ii&embed=1`)
behind their `TRADE →` rather than carrying copies.

### 3.1 Shared structure (identical in both)
Header (kicker + title + close) · direction tabs (+ lot search when busy) · body: **ledger**
(left) | **deal slip** (250px, right) · footer (visit ledger · paginator when busy · LEAVE).

- **Ledger.** A sticky three-column head and one row per lot: lot name over a derived
  sub-line (`{effect} · you hold {n} {subject}`), the counterpart bundle, and a corner that is
  `×{max lots}` or the refusal in danger. Refused rows stay selectable and dim.
- **Refusals** derive in order: `sold out` (buy, stock 0), `you hold {n}` (sell short),
  `needs {n} more {stock}` (buy short), each with a long form shown in the slip.
- **Search and pagination** appear only when a direction holds more than 7 lots. Tokens AND,
  `-` negates, `is:available` / `is:refused` filter by state.
- **Deal slip** (shared with the neighbours view): `THE DEAL`, the lot, a `LOTS − n +` stepper
  `of {max}` (1..max), `YOU GIVE|PAY` / `YOU RECEIVE` scaled **linearly** by lots, `AFTER`
  before → after on only the stocks the deal touches (down warn, up good, below zero flagged),
  the consequence copy, and the CTA. A refused lot shows the long refusal and `CANNOT TRADE`.
- **Behavior.** Selecting a row sets lots to 1; selecting it again deselects. Switching
  direction selects the first takeable lot and resets lots and page. **Settling does not
  close the dialog**: stocks, the visit ledger and the stepper's max update, and the AFTER
  values flash (not under reduced motion). The dialog opens with focus on the ledger.
- **Visit ledger.** `THIS VISIT {signed deltas}` or `THIS VISIT nothing traded yet`.

### 3.2 Vocabulary map

| Slot | Act I (barter) | Act II (coin) |
|------|----------------|---------------|
| Kicker | `PASSERBY · {N} DAYS LEFT` | `MERCHANT · MARKET OPEN {N} DAYS` |
| Title | `What will you trade?` | `What will you trade?` |
| Tabs | `BUY` / `SELL` | `BUY` / `SELL` |
| Ledger head (buy) | `THEY OFFER · YOU GIVE · STOCK` | `THEY OFFER · PRICE · STOCK` |
| Ledger head (sell) | `YOU OFFER · THEY GIVE · YOU HOLD` | `YOU OFFER · THEY PAY · YOU HOLD` |
| Give label (buy) | `YOU GIVE` | `YOU PAY` |
| Give label (sell) | `YOU GIVE` | `YOU GIVE` |
| Receive label | `YOU RECEIVE` | `YOU RECEIVE` |
| CTA | `TRADE →` | `BUY →` / `SELL →` |
| Short bundle | `2f 8m`, goods `Title ×n` | `5 coin`, goods `Title ×n` |

- **[decided]** The strip is the shared `merchant-strip`; its signal reads `● PASSERBY`
  (Act I) / `● MERCHANT` (Act II), set from the identity map.

---

## 4. Actions surface

- **[decided]** Both acts use the same ACTIONS catalog: heading + count, a search field
  (`Search actions · out:food state:ready`, `/` focuses it), `{n} of {m} actions shown`, and
  the tiles in authored order. **No sorting** for actions. Act I's grid is regular density
  (82px tiles); Act II's is **compact** (52px tiles, 6px gaps). In both acts the eating
  policy rides the **rail under BODY**, out of the catalog.
- **[decided]** Both acts have a **GENERATORS** tab, one shared view: owned generators as
  action-like tiles with a state line, an accumulation underbar and an ON/OFF switch in the
  lower-right corner. Act II lists the union of the Act I and Act II generators the
  settlement owns, at the act's compact density.
- **[proposal, item 8]** Normalize the **action tile** to Act II's format in both acts:
  - Metrics string: `−{energy}e · {duration}` (middot separator).
  - One left-aligned metrics run: `−{energy}e {inputs} · {duration} {curve} +{lo}–{hi}{unit}`
    (true minus sign, en dash ranges). No READY/state badge on action tiles: an unaffordable
    tile is dimmed instead. Generators keep their state line (`accumulating`, `off`…).
- **[decided, item 9]** Yields reference the act's resource model: Act I materials
  (`+3–5m`), Act II biomass (`+3–5b`). Same numbers where the recipe is the same.
- Distribution icons: shared `distributionLabels` map for `alt` text in both acts (keep
  "Poisson distribution" capitalization consistent).

---

## 5. Build surface

- **[decided, item 11]** Adopt **Act II's BUILD** everywhere: a full-width search box
  (`Search recipes · type:tool out:food state:ready`) and **sortable column headers**
  (RECIPE, COST, TIME, STATE; a new column opens in its natural direction — STATE nearest
  first, the rest ascending — and a second click flips it). No sort panel, no chip filters.
  The COST cell is one line (`12m 4e`).
- **[decided, item 14 — revised]** The blank BUILD shelf lists **every recipe of the act**,
  so the player sees the whole catalog; a query only narrows it.
  - Recipe states: `ready`, `reach` (short on inputs; meter + `31/48m`), `owned`
    (`Build +1`: another unit is stock to sell, its effect does not compound), and
    `blocked` (`needs {tech or tool}` in danger, no corner action).
  - STATE sorts ready → reach → owned → blocked; a build in progress pins on top.
  - When a prerequisite is satisfied, the row turns buildable and the **event log**
    announces it, e.g. `A new recipe is within reach: Fishing net.`
  - Act II's shelf also carries the Act I goods the settlement owns, unless Act II
    authors a recipe of the same name.
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
  - **[decided]** Both cards are **live**: readiness recomputes from the stocks.
  - Copy (both): locked → `locked · {n} condition(s)` / CTA `LOCKED`; unfunded →
    `inputs short` / `NEEDS INPUTS`; ready → `ready to raise` / `RAISE {NAME} →`.

---

## 7. Tabs, RESEARCH and MARKET

- **[decided]** Act I tabs: `ACTIONS · BUILD · GENERATORS`. Act II tabs:
  `ACTIONS · BUILD · GENERATORS · RESEARCH · MARKET`.
- **[decided]** RESEARCH (formerly STRUCTURE) and its hex board exist only in Act II.
  Population is an Act II concept.
- **[decided]** MARKET is the neighbours view (`market.html`, framed by `act-ii.html`). It
  lives beside the visiting merchant: the merchant comes and goes behind the strip's
  `TRADE →`; the neighbours are always there.
- **[decided]** RESEARCH and MARKET are **focus views**: the merchant and activity strips and
  the event log step aside, and the Household collapses on every entry (§8).

### 7.1 MARKET — the neighbours view

- Head `Who will trade with you?` (stall: `What will you post?`) with a count line; controls:
  search, a `BY PERSON | GOOD` segment (stall: `SIDE SELLING | BUYING`), `YOUR STALL` toggle;
  body: list | 262px deal slip; foot: friction line and paginator (8 per page).
- Natural grouping is by person up to 12 neighbours, by good beyond. A person row reads as a
  sentence with a match badge; a good row is notation with offered/wanted counts and an
  evidence range (`lo–hi coin · last n` or `not yet traded`) and `you spare n`.
- Search grammar: `needs:` `has:` `trade:` `is:match`, `-` negates. The stall's own grammar:
  `type:`/`kind:` and `is:posted|idle`.
- Deal slip with a neighbour: YOU GIVE (spare only) and YOU RECEIVE lines each with a stepper,
  a verdict (`idle`, `refuse`, `accept`, `counter`) in the neighbour's own valuation, AFTER
  rows, and `PROPOSE →` enabled only on accept. With a good selected: the cheapest sellers and
  the best-paying buyers, each name opening a deal.
- Stall: ITEM · POSTED/WANTED stepper · PRICE stepper · WHO WOULD BUY/SELL; the slip becomes a
  summary with a warning when buy posts commit more coin than held.

## 7.2 Session menu and title screen

- **[decided]** `menu.html` is the session menu, on the trade dialog's shell (620px): kicker
  `PAUSED · ACT {n} · DAY {d}`, title per screen, × resumes. Screens: menu (Continue, Save,
  Load, Settings, Quit to menu), save/load (three slots, one list flipping its verbs), settings,
  quit confirmation (`QUIT TO MENU` · `SAVE FIRST` · `CANCEL`). Escape on a sub-screen returns
  to the menu; on the menu it resumes. The HUD behind is frozen.
- **[decided]** `title.html` is the title screen: a canned attract loop behind a wordmark and
  the shared menu list (Continue disabled with its reason while no settlement exists, New
  game, Settings, Credits, Quit).
- **[decided]** Settings are one shared panel in both: DIFFICULTY, MUSIC, EFFECTS, UI SCALE,
  CONTRAST, WINDOW. A setting with no backend yet is stubbed (held, no effect), not omitted.

---

## 8. Household side rail

- **[decided]** The rail is the **HOUSEHOLD**: the economic unit's holdings, its flows, the
  body that lives on them and how it consumes. The collapsed restore label reads `HOUSEHOLD`
  in both acts (one person in Act I, the settlement in Act II); the inner panel keeps its
  `HOLDINGS` heading.
- **[decided]** Act I: HOLDINGS + MARGINS, BODY (food lasts, full vigor). Act II: HOLDINGS +
  `FLOWS / DAY` and the settlement's BODY (population, larder, water, hall vigor). In both
  acts the **eating policy sits at the foot of the rail**, aligned to the panels and
  collapsing with them.

- **[decided, item 17]** **Per-view collapse memory** (`holdingsCollapsedByView`) in both
  acts: ACTIONS, BUILD and GENERATORS each remember their own collapse.
- **[decided, item 17]** **Entering a focus view (RESEARCH, MARKET) always collapses
  holdings** on each entry, without overwriting the other views' memory.
- **[decided, item 18]** Holdings "MARGINS" contents are act-specific by design (resource
  renaming intentional); the *set* of margin rows is not fixed across acts.

---

## 9. Event log footer — shared component

- **[proposal, item 19]** Both acts: `<footer class="screen-footer" id="event-log" ...>`
  with the same `addLog(message)` contract.
- Act II additionally hides the log on the focus views (RESEARCH, MARKET); Act I has none.
- **[decided, item 14]** The log is the channel for "recipe/action unlocked" announcements.

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
| 14 | blocked state | decided (revised) | show every recipe; `needs {tech}` rows; log unlocks; "recipe" |
| 15 | goal cards | decided/proposal | shared `milestone-goal`; both collapsible |
| 16 | RESEARCH only in Act II | decided | Act II tabs ACTIONS · BUILD · GENERATORS · RESEARCH · MARKET |
| 17 | holdings collapse | decided | per-view memory; focus views force collapse |
| 18 | margins contents | decided | act-specific |
| 19 | footer id | proposal | shared `id="event-log"` + `addLog()` |
| 20 | body constants | proposal | extract to `bodyConfig` |
