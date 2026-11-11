# Human Action — Unified UI Spec (Act I & Act II)

Reconciles the vetted prototypes into one shared component and vocabulary contract: the act
shells (`act-i.html`, `act-ii.html`), the trade dialog (`trade.html`), the market
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

- **[decided]** Act I has two stocks, **Food** and **Materials**. Act II keeps both and adds
  four typed resources: **Water, Fuel, Metal, Minerals**.
- **[decided]** Materials is one stock in both acts, under one name and one code (`MA`,
  `ma`). A recipe or action that exists in both acts costs and yields the same materials in
  both. Example: Garden bed = `8ma` in both.
- **[decided]** Resource names are lowercase in running text (`converts materials into
  fuel`); headings, labels and lot names (`Fuel ×4`) keep their case.
- **[decided]** Act II introduces **Coin** as currency. Act I has no coin. The merchant in
  Act II trades for coin; the passerby in Act I trades by barter.
- **[decided]** Population and the typed resources exist only from Act II onward.
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
| Materials  | `MA` | yes | yes |
| Water      | `WA` | no  | yes |
| Fuel       | `FU` | no  | yes |
| Metal      | `ME` | no  | yes |
| Minerals   | `MI` | no  | yes |

- **[decided]** Every token uses a two-letter label, the meta stats included (`VI`, `PO`,
  `CO`); one letter no longer disambiguates.
- **[decided]** Costs and yields in running notation use the same two letters in lowercase:
  food `fo`, materials `ma`, water `wa`, fuel `fu`, metal `me`, minerals `mi`, coin `co`.
  Energy stays `e`, hours `h`, days `d`: a cost reads `12ma 4e`, a yield `+1–3fo`, a log line
  `You spend 1.7e 1ma to begin.`
- Low/zero stocks keep the `low` value class.
- **[decided]** Order: Act I `VI FO MA`; Act II `PO VI FO MA WA FU ME MI CO`. Materials sits
  directly after food in both acts.
- **[decided]** A token rests as `AB: value` and its footprint never changes. Under the pointer
  or focus, the read form `FULL LABEL: value` (label in fg; 17px, 15px stacked at ≤760, 13px
  over Act II's line at ≤560) opens as an overlay on the token's baseline, starting at its left
  edge, on an opaque bg box with 4px padding each side. An overlay that would run past the
  stockline's right edge anchors to the token's right edge instead. It eases in and out over
  120ms (opacity with a left-to-right width reveal; none under reduced motion). While it is
  open, every other token, `|` separator and runline item whose box it overlaps, or comes
  within 4px of, fades out whole over the same 120ms and keeps its footprint; everything else
  stays as it rests. The overlay takes no pointer: hit-testing stays on the resting boxes, and
  a covered token can still be hovered at its resting box, which hands the read to it.

### 2.2 Runline (right side): Act/Day + Energy

- Act/Day: `Act II · Day 43`.
- **[proposal]** **Energy lives in the runline**, shown as a rate (generated/consumed), not
  a stock: Act II reads `⚡ +12 / −9`. Distinct from the `LABEL: value` stockline pairs so it
  never reads as a stockpile. Act I shows no energy rate.

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
  sub-line (`{effect} · you hold {n} {subject}`; a lot with no effect reads only
  `you hold {n} {subject}`), the counterpart bundle, and a corner that is `×{max lots}` or the
  refusal in danger. Refused rows stay selectable and dim. A good's effect is its roster
  effect (`you can fish`, `fishing costs less and catches more`), the same sentence BUILD
  shows.
- **Refusals** derive in order: `sold out` (buy, stock 0; long form `Sold out.`), `you hold
  {n}` (sell short), `needs {n} more {stock}` (buy short), each with a long form shown in the
  slip.
- **Empty direction.** `Nothing for sale.` (buy) / `Nothing they want.` (sell); a search
  that matches nothing reads `Nothing matches that search.`
- **Search and pagination** appear only when a direction holds more than 7 lots. Tokens AND,
  `-` negates, `is:available` / `is:refused` filter by state.
- **Deal slip** (shared with the market): `THE DEAL`, the lot, a `LOTS − n +` stepper
  `of {max}` (1..max), `YOU GIVE|PAY` / `YOU RECEIVE` scaled **linearly** by lots, `AFTER`
  before → after on only the stocks the deal touches (down warn, up good, below zero flagged),
  the consequence copy, and the CTA. A refused lot shows the long refusal and `CANNOT TRADE`.
- **Sizing.** The body is 410px high whatever lot is selected, whichever tab is open and however
  many rows have sold out; it gives way only when the window is shorter than the dialog. The
  slip stacks the heading, a content region and the CTA pinned at its foot: only the content
  region scrolls, so a tall lot cannot push the CTA out of view. 410px holds the tallest slip
  (a two-resource price, three AFTER rows, a consequence line) without scrolling. Stacked
  (≤760px), the ledger sits above a 250px slip and takes the rest of the height.
- **Behavior.** Selecting a row sets lots to 1; selecting it again deselects. Switching
  direction selects the first takeable lot and resets lots and page. **Settling does not
  close the dialog**: stocks, the visit ledger and the stepper's max update, and the AFTER
  values flash (not under reduced motion). The dialog opens with focus on the ledger.
- **Visit ledger.** `THIS VISIT {signed deltas}` or `THIS VISIT nothing traded yet`.

### 3.2 Vocabulary map

| Slot | Act I (barter) | Act II (coin) |
|------|----------------|---------------|
| Kicker | `PASSERBY · {N} DAYS LEFT` | `MERCHANT · MARKET OPEN {N} DAYS` |
| Title | `Goods on offer, and what they cost.` | `Goods on offer, and what they cost.` |
| Tabs | `BUY` / `SELL` | `BUY` / `SELL` |
| Ledger head (buy) | `THEY OFFER · YOU GIVE · STOCK` | `THEY OFFER · PRICE · STOCK` |
| Ledger head (sell) | `YOU OFFER · THEY GIVE · YOU HOLD` | `YOU OFFER · THEY PAY · YOU HOLD` |
| Give label (buy) | `YOU GIVE` | `YOU PAY` |
| Give label (sell) | `YOU GIVE` | `YOU GIVE` |
| Receive label | `YOU RECEIVE` | `YOU RECEIVE` |
| CTA | `TRADE →` | `BUY →` / `SELL →` |
| Short bundle | `2fo 8ma`, goods `Title ×n` | `5 coin`, goods `Title ×n` |

- **[decided]** The strip is the shared `merchant-strip`; its signal reads `● PASSERBY`
  (Act I) / `● MERCHANT` (Act II), set from the identity map.

---

## 4. Actions surface

- **[decided]** Both acts use the same ACTIONS catalog: heading `ACTIONS` over the statement
  `Work available to you.`, a search field (`Search actions · out:food state:ready`; fields
  `in`, `out`, `state`, `type`, `is`; `/` focuses it, Escape clears it), a toolbar, and one
  grid holding the verbs and the owned generators. Act I's grid is regular density (82px
  tiles); Act II's is **compact** (52px tiles, 6px gaps). In both acts the eating policy rides
  the **rail under BODY**, out of the catalog.
- **[decided]** A search that matches nothing reads `Nothing matches that search.`; in the
  hidden view, `Nothing hidden matches that search.`
- **[decided]** Every tile in an ACTIONS row is as tall as the row's tallest, with its edges,
  underbar and corners on the row's real edges. Every tile's content is pinned to its top, so
  a verb's name and a generator's stand on one line (12px from the tile's top, 7px compact),
  and the height the content leaves falls below it.
- **[decided]** The heading's eyebrow counts the kinds, `4 verbs · 2 generators` (Act II
  `20 verbs · 4 generators`), and each count is a toggle (`aria-pressed`): pressed, it shows
  that kind alone; pressed again, everything.
- **[decided]** The toolbar: on the left, the summary `{n} hidden out of {N} →` is one toggle
  that opens the **hidden view** — only the hidden tiles, each in a dashed line-2 outline and
  dim ink, plus an `unhide all` button — and then reads `← {n} hidden out of {N}`; with
  nothing hidden it is inert and only counts. On the right, sort chips
  `default · state · name · cost · time`: a chip opens in its natural direction (state
  descending, the rest ascending) and pressed again flips it; `aria-sort` marks the chip in
  force. `default` is the authored order, the verbs then the generators.
- **[decided]** Every tile has a `hide` corner at the top right; in the hidden view it reads
  `unhide`.
- **[decided]** A generator tile keeps its state line (`accumulating`, `off`), its
  accumulation underbar, and a mode corner at the lower right that cycles on one click:
  `● ON` (accumulates and waits to be collected, good ink) → `◉ AUTO` (collects by itself
  when the cycle completes, fg ink) → `○ OFF` (pauses, keeps its progress, dim ink). Act I
  lists Check traps and Garden bed; Act II lists the union of the Act I and Act II generators
  the settlement owns (adding Charcoal kiln and Spring well). Act II's generator tile is
  slim: the state word rides the name row, so it stands 52px tall like a verb.
- **[decided]** URL parameters seed the pane: `actionq`, `sort`, `dir`, `hidden` (a comma
  list of names), `showhidden=1`, `kind=verb|generator`.
- **[proposal, item 8]** One action tile format in both acts:
  - One left-aligned metrics run: `−{energy}e {inputs} · {duration} {curve} +{lo}–{hi}{code}`
    (true minus sign, en dash ranges): `−2e −2ma · 24h ⌒ +0–3fo`. No READY/state badge on
    action tiles: an unaffordable tile is dimmed instead. Generators keep their state line
    (`accumulating`, `off`…).
  - The numbers are the roster's: the energy, every input the verb spends, the hours, the
    curve of the dominant yield and its p10–p90 band rounded to whole units (a band that
    rounds to one value reads `+1me`).
- **[decided, item 9]** Yields and inputs use the two-letter codes (§2.1) in both acts;
  materials is `ma` in both (`+3–12ma`). Same numbers where the verb is the same.
- Distribution icons: shared `distributionLabels` map for `alt` text in both acts (keep
  "Poisson distribution" capitalization consistent).

---

## 5. Build surface

- **[decided, item 11]** Both acts use the same BUILD: heading `BUILD` over the statement
  `Recipes available to you.`, a full-width search box
  (`Search recipes · type:tool out:food state:ready`) and **sortable column headers**
  (RECIPE, COST, TIME, STATE; a new column opens in its natural direction — STATE nearest
  first, the rest ascending — and a second click flips it). No sort panel, no chip filters.
  The COST cell is one line (`12ma 4e`); TIME is in days (`0.7d`). A search that matches
  nothing reads `Nothing matches that search.`
- **[decided, item 14]** The blank BUILD shelf lists **every recipe of the act**,
  so the player sees the whole catalog; a query only narrows it.
  - Recipe states: `ready`, `reach` (short on inputs; meter + `31/48ma`), `owned`
    (`Build +1`: another unit is stock to sell, its effect does not compound), and
    `blocked` (`needs {skill or tool}` in danger, no corner action).
  - STATE sorts ready → reach → owned → blocked; a build in progress pins on top.
  - When a prerequisite is satisfied, the row turns buildable and the **event log**
    announces it, e.g. `A new recipe is within reach: Fishing net.`
  - An Act II recipe waits on the skill its roster entry names; researching that skill on
    the board unlocks the row.
  - Act II's shelf also carries the Act I goods the settlement owns, unless Act II
    authors a recipe of the same name.
- **[decided]** A row's effect is the good's roster effect, the one sentence every surface
  shows for it.
- **[decided, item 14]** BUILD calls its rows **recipes** throughout (headings, counts, summary).
- **[proposal, item 13]** One row schema, data-generated in both acts:
  - Rows generated from a recipe object (no hand-written HTML).
  - Name cell = `<strong>{name}</strong><small>{type}</small>`.
  - `type` enum: generator / tool / material / storage / comfort / transport.
  - Column order: name · cost · time · effect · state · action.
- **[proposal, item 12]** Summary wording (both): `{visible} of {total} recipes shown`, with
  no stock suffix (the stockline carries it).

---

## 6. End-of-act goal card — shared `milestone-goal` component

- **[decided, item 15]** Different buildings by design: **Shelter** (Act I) vs **Exchange**
  (Act II). But both use **one shared card component**.
- **[decided]** Both are a **collapsible disclosure** (bar → details).
- **[proposal]** Shared anatomy:
  - **Bar**: `<strong>{title}</strong>` + readiness pill + compact summary +
    `details ↓ / close ↑` toggle + primary action button.
  - **States** (shared): `locked → unfunded → ready → building → done`, with `busy` beside
    ready.
    - Act I Shelter: locked → unfunded (inputs short) → ready → building → standing.
    - Act II Exchange: locked → unfunded → ready → building → standing (opens Act III).
  - **[decided]** `building` is the sibling of a building row. A milestone is built like any
    recipe: the inputs are paid, it holds the hands and the activity strip
    (`■ BUILDING Shelter · 6.0d left`), and every other build waits on it. The rail and wash
    take the accent, the readiness reads `building · {d.d}d left` in accent, the compact
    summary reads the progress (`42%`), and every requirement reads met (`60 paid`). The CTA
    keeps its 132×28 lane as a disabled `■ BUILDING` with an accent outline and label, no
    hover lift, and a 3px accent underbar along its bottom edge filling left to right with
    the build's progress.
  - **[decided]** `busy`: conditions and inputs are all met but the hands are on other work.
    The card stays danger-toned and reads `hands busy` / `HANDS BUSY`, never `inputs short`.
  - **Requirements row**: same markup; act-specific tokens.
    - Act I: `VIGOR · FOOD · GOODS · ROPE BAG · LEAF BED · MATERIALS`.
    - Act II: `RING 4 · POPULATION · MATERIALS · MINERALS · METAL`.
  - **[decided]** Both cards are **live**: readiness recomputes from the stocks.
  - Copy (both): locked → `locked · {n} condition(s)` / CTA `LOCKED`; unfunded →
    `inputs short` / `NEEDS INPUTS`; ready → `ready to build` / `BUILD {NAME} →`.
  - **[decided]** The Exchange's details: kicker `ENDS ACT II · A PERMANENT MARKET`, copy
    `Build a standing trading floor. Once it opens, passing lots give way to a permanent
    market and Act III begins.`, locked line `Research any ring-4 skill and grow the
    population beyond 500.`, compact `ring 4 0/1 · population 7/501`, ready
    `{skill} researched · population {n} · all inputs held`, standing
    `opened after {skill} · permanent market`.

---

## 7. Tabs, RESEARCH and MARKET

- **[decided]** Act I tabs: `ACTIONS · BUILD · MARKET`. Act II tabs:
  `ACTIONS · BUILD · RESEARCH · MARKET`.
- **[decided]** RESEARCH (formerly STRUCTURE) and its hex board exist only in Act II.
  Population is an Act II concept.
- **[decided]** MARKET is `market.html`, framed by both acts: Act II frames
  `market.html?embed=1`, Act I frames `market.html?act=i&embed=1` (§7.1, Act I mode). It
  lives beside the visiting trader: the passerby or the merchant comes and goes behind the
  strip's `TRADE →`; the market is always there.
- **[decided]** The focus views are Act I's MARKET and Act II's RESEARCH and MARKET: the
  merchant and activity strips and the event log step aside, and the rail collapses on every
  entry (§8).

### 7.1 MARKET

- **[decided]** Header: `MARKET` over the statement `Neighbours, what they offer and what they
  want.` The header does not change with the view: the list and the inventory share it. Its
  right-hand counter is the whole market, `{n} offers · {m} wants`: every standing offer and
  want, the neighbours' and the player's (`1 offer`, `1 want` singular).
- **[decided]** Controls, left to right: the `INVENTORY` button first (accent while open),
  24px from the search field; the search and the `BY PERSON | GOOD` segment stay a group (in
  the inventory, `SIDE OFFERS | WANTS`). Body: list | 262px slip; foot: friction line and
  paginator (8 per page).
- **[decided]** Offer and want: what anyone posts is an **offer** (to sell) or a **want** (to
  buy); "post" stays the verb (`not posted`, `NOTHING POSTED`).
- Natural grouping is by person up to 12 neighbours, by good beyond. A person row reads as a
  sentence, `Offers {goods}. Wants {goods}.`, with a match badge (`WANTS WHAT YOU HOLD` /
  `nothing you hold`). The player's own row leads the person list: `You`, the trade, the
  badge `{n} OFFERED · {m} WANTED` (or `NOTHING POSTED`), the line `Offers … . Wants … .` (or
  `Nothing posted. Neighbours cannot trade with you.`); clicking it opens the inventory. A
  good row is notation with offered/wanted counts, an evidence range (`lo–hi coin · last n`
  or `not yet traded`) and `you spare n`.
- Search grammar: `needs:` `has:` `trade:` `is:match`, `-` negates. The inventory's own
  grammar: `type:`/`kind:` and `is:posted|idle`. A search that matches nothing reads
  `Nothing matches that search.`
- With a good selected, the slip names it and lists `CHEAPEST SELLING` and `PAYING MOST`;
  each name opens a deal, and the good's row stays highlighted while that deal is open.
- **[decided]** `THE DEAL` with a neighbour carries `← BACK` on the heading's line: back
  returns to the good's detail the deal was opened from, or closes the deal when it was
  opened from a person row. Under it, the neighbour and `{trade} · wants {good n, …}`; YOU
  GIVE (spare only; `Nothing spare they want.` when none) and YOU RECEIVE lines each with a
  stepper; a verdict (`idle`, `refuse`, `accept`, `counter`) in the neighbour's own valuation
  (refuse: `{Name} wants … — nothing you have spare.`); AFTER rows; and `PROPOSE →`, enabled
  only on accept.
- **[decided]** The inventory takes the list pane: ITEM · OFFERED stepper (WANTED on the wants
  side) · PRICE stepper · WHO WOULD BUY (WHO WOULD SELL). The offers side lists what the
  player holds, each row `{spare} spare of {held} held · {the good's short effect}`; the wants
  side lists what the market offers. An unposted row reads `not posted`. The slip summarises
  only what is posted: heading `INVENTORY`, `{n} offered · {m} wanted`, the tallies `OFFERED`
  and `WANTED`, a warning when wants commit more coin than held (`Your wants commit {c} coin
  and you hold {h}. The shortfall will not fill.`), and the lists `OFFERED` / `WANTED`
  (`Nothing offered.` / `Nothing wanted.`). Foot: `{n} offered · {m} wanted · neighbours
  trade against them while you work.`
- **[decided]** Act I mode (`?act=i`): the same view before anyone else exists. No
  neighbours: the person list is the player's row and `No neighbours yet.`, the deal slip
  reads `No deal open.`, the foot reads `A passerby trades from the strip.`, and the wants
  side of the inventory reads `Nobody is offering anything yet.`; the inventory's slip and
  foot say `no neighbours yet`. No coin: the inventory drops
  its PRICE column and the wants tally its coin, and the search placeholder drops `trade:`.
  The inventory lists food, materials and the goods the actor holds, with their short
  effects; each quantity can be posted up to its spare.
- URL parameters (review): `act=i`, `embed=1`, `stall=1` (opens the inventory), `side=buy`,
  `by=person|good`, `q`, `n` (neighbours), `per` (rows per page), `pick` (opens a deal with
  the first neighbour whose name starts with it). The act pages pass their own `stall=1` on
  to the framed market.

### 7.1a RESEARCH — the hex board

- **[decided]** A research tile is a **skill** wherever the player reads it. Topbar `RESEARCH`
  over the statement `Specialize your skills.`, with the filter chips (`researched` ·
  `available` · `all`) and a `find a skill` search; body: the board pane | 238px detail aside;
  foot: the six-resource legend, the status line (`Select an available or researched skill`)
  and the hints (`Wheel zoom / drag pan`, `Arrows move · Esc clears`).
- The board is the 620-unit viewBox fitted to the pane: a neutral hub, sixty tiles over rings
  1–4, sector labels at the rim. Locked tiles are silhouettes with no label; available and
  researched tiles carry a short label, resource rails, material dots, and (researched) a
  marker. The selection strokes `fg`; its outward neighbours stroke `warn`, dashed. Resting
  fill opacity: locked 0.14 (stroke 0.38), available 0.50 (full stroke), researched 1; hover
  lifts an available tile to 0.84, selection to 0.9.
- Camera: wheel zoom about the pointer (×1.12), drag pan past 4px, `−` / `%` / `+` / `reset`,
  zoom 0.75–2.5 in 0.2 steps. Filters and search dim (opacity 0.11), never remove.
- Detail: `RING n · ERA` (ring 2's era is `WORKS`), name, `PURE|HYBRID` · resources · state
  tags, `RESEARCH →` (or `NEEDS …` / `RESEARCHED`) with the cost line (`KNOWN FROM ACT I` for
  a ring-1 skill), the effect as a second-person sentence, RESEARCH COST (`n Resource` /
  `n held`, `Known from Act I` at zero cost), OPENS NEXT (what it opens in BUILD/ACTIONS, then
  outward tiles and their state, or `Act III frontier`). With nothing selected: kicker
  `NO SKILL SELECTED`, copy `Pick a lit tile to see its cost and what it opens.`
- **[decided]** RESEARCH is real: `RESEARCH →` pays the cost from the stocks, researches the
  skill, opens its outward neighbours, unlocks the BUILD rows that wait on it, and logs
  `{Name} researched. {cost} paid.` with the cost in lowercase words.
- **[decided]** The Exchange card (BUILD) unlocks on any ring-4 skill and a population beyond
  500; building it pays 80 materials · 40 minerals · 24 metal and begins an 18-day build, and
  when it stands the page reads as Act III (`◆ EXCHANGE`, `ENTER →`, the act label).

## 7.2 Session menu and title screen

- **[decided]** `menu.html` is the session menu, on the trade dialog's shell (620px): kicker
  `PAUSED · ACT {n} · DAY {d}`, title per screen, × resumes. Screens: menu (Continue, Save,
  Load, Settings, Quit to menu), save/load (three slots, one list flipping its verbs; a slot
  reads `Act II · Day 43 · population 7`), settings, quit confirmation (`QUIT TO MENU` ·
  `SAVE FIRST` · `CANCEL`). Escape on a sub-screen returns to the menu; on the menu it
  resumes. The HUD behind is frozen.
- **[decided]** `title.html` is the title screen: a canned attract loop behind a wordmark and
  the shared menu list (Continue disabled with its reason while no settlement exists, New
  game, Settings, Credits, Quit).
- **[decided]** Settings are one shared panel in both: DIFFICULTY, TUTORIAL, MUSIC, EFFECTS,
  UI SCALE, BRIGHTNESS, CONTRAST, WINDOW — gameplay first, then sound, then display. A setting
  with no backend is stubbed (held, no effect), not omitted.
- **[decided]** TUTORIAL is an ON/OFF pair, on by default: the first-run guidance in the log.
- **[decided]** BRIGHTNESS is a slider from 80% to 140% in steps of 5, default 100%: one linear
  multiply of every painted colour (text, lines, fills and the ground), 100% being the palette
  as authored and channels clamping at white, for monitors on which the dark palette reads too
  dark. It acts live on the whole screen behind the panel as well as on the panel itself.

---

### 7.3 Narrow widths and the keyboard

- **[decided]** At 760px and below the page stacks: one page scroll, the rail above the
  surface (HOLDINGS | BODY side by side at 760, stacked at 560 and below), every view at its
  natural height, the stockline wrapping beside the run context. RESEARCH puts a 560px board
  above its detail.
- **[decided]** A scroll region that overflows is a Tab stop; Up/Down, Page Up/Down and
  Home/End scroll the innermost region around focus, and a newly focused control scrolls into
  view. The wheel goes to the innermost region under the pointer.

## 8. Household side rail

- **[decided]** The rail is the same in both acts: HOLDINGS, BODY and the EATING POLICY. It
  holds the economic unit's holdings, its flows, the body that lives on them and how it
  consumes. The collapsed restore label reads `HOUSEHOLD` in both acts (one person in Act I,
  the settlement in Act II); the inner panel keeps its `HOLDINGS` heading.
- **[decided]** Act I: HOLDINGS + MARGINS, BODY (food lasts, full vigor). Act II: HOLDINGS +
  `FLOWS / DAY` and the settlement's BODY (population, larder, water, hall vigor). In both
  acts the **eating policy sits at the foot of the rail**, aligned to the panels and
  collapsing with them.

- **[decided, item 17]** **Per-view collapse memory** (`holdingsCollapsedByView`) in both
  acts: ACTIONS and BUILD each remember their own collapse.
- **[decided, item 17]** **Entering a focus view (Act I MARKET; Act II RESEARCH, MARKET)
  always collapses the rail** on each entry, without overwriting the other views' memory.
- **[decided, item 18]** Holdings "MARGINS" contents are act-specific by design; the *set* of
  margin rows is not fixed across acts.

---

## 9. Event log footer — shared component

- **[proposal, item 19]** Both acts: `<footer class="screen-footer" id="event-log" ...>`
  with the same `addLog(message)` contract.
- Both acts hide the log on their focus views (Act I MARKET; Act II RESEARCH, MARKET).
- **[decided, item 14]** The log is the channel for "recipe/action unlocked" announcements.

---

## 10. Body panel (eating policy)

- **[proposal, item 20]** The act-specific constants live in a labeled config, and
  `updateEatingPolicy()` is identical across acts:
  ```js
  // Act I
  const bodyConfig = { baseCoverage: 5.2, baseRecovery: 0.224 };
  // Act II
  const bodyConfig = { baseCoverage: 10.3, baseRecovery: 0.448 };
  // shared:
  const coverage = bodyConfig.baseCoverage / rate;
  const recovery = bodyConfig.baseRecovery / rate;
  ```
- Eating-policy words, slider math, and ARIA text are shared and identical.

---

## Normalization checklist (drift → action)

| # | Item | Decision | Action |
|---|------|----------|--------|
| 1 | passerby→merchant | decided | keep; shared modal skeleton |
| 2 | modal innards | proposal | one skeleton + vocabulary map (§3) |
| 3 | preview give-label | proposal | shared swap fn; Act I static GIVE (§3.2) |
| 4 | barter vs coin | decided | Coin = Act II only; Act I market has no price column |
| 5 | materials vs typed | decided | materials in both acts (`MA`, `ma`); Act II adds water, fuel, metal, minerals |
| 6 | header glyphs | decided / proposal | two-letter tokens and resource codes (decided); energy in runline (proposal) (§2) |
| 7 | actions grid vs catalog | decided | one ACTIONS catalog both acts: verbs + generators, kind toggles, hide, sort chips |
| 8 | tile metric format | proposal | `−Xe {inputs} · Yh` + curve + roster band, optional state line |
| 9 | yields resource | decided | two-letter codes, equal numbers |
| 10 | dist alt text | proposal | shared `distributionLabels` map |
| 11 | build filters | decided | one BUILD in both acts |
| 12 | summary wording | proposal | `{n} of {m} recipes shown` |
| 13 | row schema | proposal | data-generated schema both acts |
| 14 | blocked state | decided | show every recipe; `needs {skill}` rows; log unlocks; "recipe" |
| 15 | goal cards | decided/proposal | shared `milestone-goal`; both collapsible; built, not raised |
| 16 | RESEARCH only in Act II | decided | Act I tabs ACTIONS · BUILD · MARKET; Act II ACTIONS · BUILD · RESEARCH · MARKET |
| 17 | holdings collapse | decided | per-view memory; focus views (both acts) force collapse |
| 18 | margins contents | decided | act-specific |
| 19 | footer id | proposal | shared `id="event-log"` + `addLog()` |
| 20 | body constants | proposal | extract to `bodyConfig` |
| 21 | headings | decided | statements under headings, never questions |
| 22 | empty search | decided | `Nothing matches that search.` everywhere (hidden ACTIONS: `Nothing hidden matches that search.`) |
| 23 | market vocabulary | decided | offer / want; `INVENTORY`; market-total counter; `← BACK` on THE DEAL |
