# Hex tech board — assembly spec

A pointy-top hexagonal technology board that grows outward from one neutral foundation hex at `(0, 0)`. Six resource families map to six fixed directions around that root. Ring 1 contains the crude production technologies that establish those resources; rings 2-4 represent increasingly capable local production systems within Act II. Players specialize by pushing some wedges deep while neglecting others.

This is an **adoption and implementation board**, not a discovery tree. The setting has access to modern human knowledge. Research spends real inputs to establish a technology locally; there is no Knowledge resource, discovery currency, or epistemic fog.

---

## 0. Project context — the Act I handoff

### What Act I already establishes

Act I is the single-person **Robinson Crusoe** phase. The player controls one body and makes immediate choices through the existing ACTIONS and BUILD surfaces while managing Holdings, BODY/vigor, eating policy, activity, and the event log.

Act I deliberately has only two economic stocks:

- **Food** — a perishable larder that sustains the body.
- **Materials** — one fungible durable stockpile, gathered principally through Scavenge and spent on rudimentary capital.

Act I already includes personal-scale Forage and Split wood behavior. Their ring-1 counterparts must not unlock those verbs a second time. Ring-1 **Foraging** and **Woodcutting** instead mean that Food and Biomass production are established as Act II resource domains that can support a growing population.

Raising **Shelter** ends Act I: other people ask to move in, population can rise above one, and Act II opens. The Act II UI increments this shell rather than replacing it. STRUCTURE remains a tab beside ACTIONS and BUILD; leaving STRUCTURE returns to the preserved Holdings/BODY/eating/activity experience. The Act II prototype drops the persistent event-log footer so the active surface, especially the research board, receives that vertical space.

### Transition into Act II

At the Act I-to-II curtain:

1. Carry the current Food balance forward unchanged.
2. Convert the entire **unspent generic Materials balance** into Biomass at `1:1`.
3. Do not convert, destroy, or relabel built goods and other Holdings; only the fungible raw balance migrates.
4. Remove generic Materials as an economic balance. It cannot be earned or spent in Act II.
5. Start **Foraging** and **Woodcutting** Researched because Act I already established their personal-scale foundations.
6. Start **Spring well**, **Firepit**, **Surface ore**, and **Quarry pit** Available. Each can be researched using only Food and Biomass, the two resource balances available at the curtain.

The interactive Act II board therefore begins with:

- the neutral ring-0 foundation logically Researched;
- ring-1 Foraging and Woodcutting Researched;
- the other four ring-1 technologies Available;
- five ring-2 technologies Available through normal inward adjacency:
  - Gamekeeping;
  - Net fishery;
  - Pottery works;
  - Loom & ropewalk;
  - Field cultivation;
- every other ring-2 technology and all outer technologies Locked until an inward neighbor is Researched.

This start is deliberately uneven. Act II does not wait for all six ring-1 branches before opening.

### Canonical Act II resource vocabulary

Research costs and resource accounting use exactly these six resource keys:

|Canonical resource|Transition or meaning|
|-|-|
|Food|Act I Food carried forward unchanged|
|Water|Local production established by Spring well; may be imported earlier|
|Fuel|Local production established by Firepit; may be imported earlier|
|Metal|Local gathering established by Surface ore; may be imported earlier; replaces Iron as a resource key|
|Minerals|Local gathering established by Quarry pit; may be imported earlier; replaces Stone as a resource key|
|Biomass|Receives unspent Act I Materials; encompasses the old Wood and Fibre resource balances|

### Act II market context

Act II has an operating market descended from the Act I passerby: finite-stock BUY and SELL lots settle atomically in Coin. Lots may contain typed Act II resources, so a resource can be held and spent before its local ring-1 production technology is Researched. Players may therefore import an input, establish its local production, or combine both approaches. Selling resources and goods can replenish Coin for later purchases.

**Coin is separate.** It is the market's settlement medium and is never a research input. Population and vigor are also not resources on this board. Market access does not change a tile's adjacency state; it changes whether the tile's authored resource bundle can be paid.

Replace legacy resource labels, costs, filters, and accounting references to Wood, Fibre, Stone, and Iron with Biomass, Minerals, and Metal as appropriate. Concrete nouns may remain in authored names and prose: *planks*, *rope*, *woodcutting*, and **Iron smelting** describe specific goods or processes, not resource-accounting keys.

The capitalized Act I balance **Materials** may appear in transition copy and save migration code only. It must not appear as an Act II header balance, research currency, or seventh board resource.

---

## 1. Geometry

- **Hex orientation:** pointy-top (a vertex points up).
- **Coordinates:** axial `(q, r)`. The resource hub is `(0, 0)`.
- **Screen position** for hex size `s` (center to vertex) and board center `(cx, cy)`:
  - `x = cx + sqrt(3) * s * (q + r / 2)`
  - `y = cy + 1.5 * s * r`
- **Ring of a hex:** `ring = max(|q|, |r|, |q + r|)`
- **Hexes per ring:** ring 0 = 1, ring `n` = `6n`. The complete Act II board is rings 0–4, totaling 61 logical hexes. Expansion beyond ring 4 belongs to Act III and is outside this document.
- **Hex vertices:** angles `-30°, 30°, 90°, 150°, 210°, 270°` around the center at radius `s`.
- Draw ordinary tile polygons at radius `s - 1.5` to leave a visible gap between neighbors.

## 2. Wedge order

Clockwise on screen, starting at 3 o'clock. Screen coordinates have `y` pointing down, so “clockwise” means visual clockwise.

|Index|Resource|Direction vector `(q, r)`|Screen angle|Code|Color family|
|-|-|-|-|-|-|
|0|Food|`(1, 0)`|0° (right)|`FO`|Coral / red-orange|
|1|Water|`(0, 1)`|60° (lower right)|`WA`|Blue|
|2|Fuel|`(-1, 1)`|120° (lower left)|`FU`|Amber|
|3|Metal|`(-1, 0)`|180° (left)|`ME`|Gray / steel|
|4|Minerals|`(0, -1)`|240° (upper left)|`MI`|Purple / violet|
|5|Biomass|`(1, -1)`|300° (upper right)|`BI`|Green|

The order is deliberate: every adjacent pair forms a meaningful hybrid domain (see §4). **Do not reorder it.** The two-letter codes are deliberate too: single initials would make Food/Fuel and Metal/Minerals ambiguous.

## 3. Classifying a ring hex

For a hex at ring `n ≥ 1`:

- **Corner (pure) hex:** `(q, r) = n * dir[w]` for exactly one wedge `w`. It belongs to that single resource. There are 6 per ring.
- **Edge (hybrid) hex:** every other hex on the ring. It lies between corners `w` and `w+1` (mod 6) and combines those two adjacent resources. There are `n - 1` per edge and `6(n - 1)` per ring.

Coordinates of edge hexes between wedge `w` and `w+1` at ring `n`, for `k = 1 .. n-1`:

```text
pos = n * dir[w] + k * (dir[w+1] - dir[w])
```

`k` small means closer to wedge `w`; `k` large means closer to wedge `w+1`. Technologies are written to lean toward the nearer resource.

Classify from exact axial coordinates. For each tile, first compare against the six corner equations; otherwise find the unique `(w, k)` satisfying the edge equation. Do **not** classify gameplay data by rounded screen angle. Screen coordinates are a rendering transform, and floating-point angle thresholds introduce avoidable boundary ambiguity.

## 4. Adjacent-pair domains

|Edge|Domain|Flavor|
|-|-|-|
|Food–Water|Fishing, irrigation, aquaculture|The river delta|
|Water–Fuel|Steam, hydro, coolant|The energy state|
|Fuel–Metal|Smelting, engines, rail|The industrial forge|
|Metal–Minerals|Concrete, glass, deep mining|The constructor|
|Minerals–Biomass|Kilns, ceramics, paper|The artisan|
|Biomass–Food|Farming, husbandry, storage|The pastoral homestead|

Non-adjacent pairs such as Food–Metal have no hybrid hexes by design.

## 5. Ring-0 foundation

Ring 0 is one logical hex at `(0, 0)`. It is the visual origin and common inward neighbor of ring 1, but it is not a resource balance, technology, or research action.

- Render one undivided, visually unlabeled neutral hex; do not place `R0` text inside it.
- Give it the accessible name **Ring 0 foundation** and no interactive role, focus target, hover expansion, tap pin, or keyboard behavior.
- Let board-camera drag begin from the center just as it can from other non-control board space.
- Keep resource-family identity in the six perimeter labels and the pure/hybrid technology fills rather than dividing the center.
- Treat the foundation as logically Researched only for ring-1 adjacency; do not count it among the 60 technology states.

## 6. Visual states for rings 1+

Each technology hex has exactly one progression state:

|State|Rendering and interaction|
|-|-|
|**Locked**|Resource color at low but legible opacity (~24%); no label; not selectable, clickable, or keyboard-focusable|
|**Available**|Resource color at inviting mid-high opacity (~66%); label visible; interactive; subtle pulse optional|
|**Researched**|Resource color at full opacity; label visible; interactive for inspection; thin dark outline in the same color family|

Pure hexes use a solid fill. Hybrid rendering is selected through a named visual template; templates must not alter technology identity, progression state, selection, filtering, camera state, costs, or material dots.

|Template id|Body|Resource treatment|Purpose|
|-|-|-|-|
|`rails-all` (default)|Muted resource body for pure; muted midpoint for hybrid|One full six-edge pure rail; two three-edge hybrid rails|Consistent rail language across every technology tile|
|`rails`|Solid resource body for pure; muted midpoint for hybrid|No pure rail; two three-edge hybrid rails|Hybrid-only rail comparison|
|`blend`|Solid resource body for pure; smooth two-color hybrid gradient|No rails|Retained comparison baseline|

In `rails-all`, every pure technology receives one inset closed rail covering all six edges in its resource color. Every hybrid retains two rails: each domain resource owns exactly three contiguous edges by nearest radial resource direction, and the pair partitions all six edges without overlap. Pure bodies are toned toward neutral so a same-color rail remains legible; hybrid bodies use the toned resource midpoint. Ring 0 stays neutral and has no rail.

The `rails` template preserves full-color pure bodies without pure rails while keeping the same hybrid body and split rails. The `blend` template preserves full-color pure bodies and tile-specific hybrid gradients; each gradient's local tangent makes its midpoint seam radial to the board center, with endpoint colors held through `32%`/`68%`.

Populate the STRUCTURE toolbar selector from the template registry. `?hybrid=rails-all`, `?hybrid=rails`, and `?hybrid=blend` select shareable initial states. `window.prototypeBoard.setHybridTemplate(id)` switches existing nodes in place, and `activeHybridTemplate()` reports the current id. Adding a future option should extend the registry and its SVG/CSS treatment rather than replace another template.

The `HYBRID` detail tag and tooltip remain textual cues in every template. Every technology tile carries compact material-reference dots near its lower edge. These are an at-a-glance composition cue, not a replacement for the complete authored cost shown in the detail pane. Domain resources appear first; when an advanced tile needs another dot, use the first distinct resource in its authored research cost:

|Ring|Pure tile dots|Hybrid tile dots|
|-|-|-|
|1|1|n/a|
|2|1|2|
|3|2|2|
|4|2|3|

Use this equal-lightness resource palette so pure fills, hybrid rails, dots, and retained blend gradients remain distinct without harsh luminance seams:

|Resource|Color|
|-|-|
|Food|`#D97966` coral|
|Water|`#5B9FC4` blue|
|Fuel|`#D5A64E` amber|
|Metal|`#8497A3` steel|
|Minerals|`#9A7CB4` violet|
|Biomass|`#78A276` green|

Do not place the board on a full circular or six-wedge backdrop, and do not draw dashed stage-circle guides. Do not render `R0` or `R1`-`R4` text overlays on the board; keep the six perimeter resource labels and bottom board summary. Resource families remain legible through brighter tile fills, the neutral ring-0 foundation, material dots, perimeter labels, and hybrid blends. Use a neutral-cool charcoal board surface so the palette remains clean without abandoning the terminal frame.

At Act II entry, Foraging and Woodcutting are Researched; the other four ring-1 tiles are Available. Affordability does not create another tile state. An Available technology that the settlement cannot currently afford remains Available; its detail action communicates the deficit.

Locked labels are hidden to keep progression and the board silhouette legible, not because the society lacks knowledge of the technology. Do not add discovery points, a Knowledge balance, or hidden-tech reveal mechanics.

## 7. Unlocking and research

### Adjacency rule

A Locked hex becomes Available when at least one of its six neighbors with a **strictly lower ring number** is Researched.

- The ring-0 foundation is the common logical Researched neighbor of all six ring-1 tiles, so every ring-1 technology is at least Available.
- Foraging and Woodcutting are promoted from Available to Researched by the Act I migration state.
- Pure corner technologies chain outward along their wedge.
- Hybrid technologies are reachable from either adjacent wedge, so a player deep in one wedge can enter the neighboring hybrid domain without first researching that neighboring pure corner.
- Researching a technology can change only its immediate outward neighbors from Locked to Available. Nothing unrelated elsewhere on the board opens.

### Meaning of research

The primary detail action is **RESEARCH →**. In this setting, research means locally adapting, prototyping, and establishing already-known human technology. It does not mean discovering an unknown idea.

For the UX prototype, research resolves immediately and atomically:

1. Verify that the tile is Available and that every required resource quantity is held.
2. Deduct the complete resource bundle. Never make a partial payment.
3. Mark the selected tile Researched.
4. Recompute only its outward neighbors under the adjacency rule.
5. Update the detail pane, board, header balances, and status feedback together.

Research does not construct the resulting capital good. It may unlock or improve actions, resource transformations, and BUILD recipes, but actual goods are still made through BUILD.

### Research costs

- The four initially Available ring-1 technologies—Spring well, Firepit, Surface ore, and Quarry pit—cost an authored combination of **Food and Biomass only**.
- Foraging and Woodcutting incur no new Act II research payment because they enter Researched through the Act I migration.
- Ring-2 through ring-4 technologies cost an authored bundle containing one or more of the six canonical resources: Food, Water, Fuel, Metal, Minerals, and Biomass.

The five technologies Available at the opening use these resource families; exact quantities remain authored balancing data:

|Opening technology|Research-cost resource families|
|-|-|
|Gamekeeping|Food + Biomass|
|Net fishery|Biomass + Water|
|Pottery works|Biomass + Minerals|
|Loom & ropewalk|Biomass + Food|
|Field cultivation|Food + Biomass|

Net fishery and Pottery works deliberately demonstrate imported inputs: Water or Minerals can come from the market before Spring well or Quarry pit establishes local production.

For every Available technology, each resource type in its cost must have a current acquisition route: an existing balance, established local production, or an active market lot. A shortage of quantity or Coin is valid; relying on a resource type with no current source is not. If market stock is the only route, the relevant lot must be deliberately authored and present rather than left to random future stock.

- Costs generally become more demanding in outer rings so specializing in roughly 40–50% of the board can consume a full playthrough's practical surplus; completing every wedge should be infeasible.
- A tile's wedge or hybrid pair identifies its technological domain, **not an automatic cost recipe**. A pure technology may need supporting resources, and a hybrid need not cost only its two color families.
- Store costs explicitly with each technology, for example `cost: { biomass: 4, food: 2 }`; omit zero entries.
- Exact quantities are balancing content and are not specified by this assembly document. Do not invent a Knowledge conversion formula in their place.
- Coin, vigor, population, finished goods, and generic Act I Materials are not research currencies in Act II.

If the player lacks inputs, keep the tile Available and disable its action with a concrete deficit such as `NEEDS 2 BIOMASS · 1 FOOD`.

Show the factual deficit only. Do not append acquisition-route advice or direct the player toward a specific solution; production, purchase, sale, and waiting are choices for the player to infer.

## 8. Board interaction contract

- STRUCTURE remains a tab beside ACTIONS and BUILD. It may use the approved focused layout that temporarily hides Holdings, the merchant row, and the activity strip so the map and right detail pane have room; those systems remain intact on the other tabs.
- Ring 0 is a neutral, noninteractive foundation hex and never opens a detail or research action.
- Available and Researched technology tiles can be selected with pointer or keyboard. Locked tiles are absent from the focus order and expose no click action.
- The right detail pane shows: technology name, ring/era, pure or hybrid domain, progression state, effect, authored resource cost, current affordability/deficits, and what the technology enables.
- An Available and affordable tile shows **RESEARCH →**. An Available but unaffordable tile shows its missing resources. A Researched tile has no repeat-research action.
- Do not show BUILD in the board detail. Research can unlock a BUILD recipe, but the BUILD tab remains the construction surface.
- Board filters are cumulative from narrow to broad: `researched` shows only Researched tiles; `available` shows Available plus Researched tiles; `all` adds anonymous Locked silhouettes.
- Search must not reveal labels or detail interactions for Locked cells.
- Arrow-key navigation moves among interactive technology tiles; Enter/Space selects; Escape clears selection. Ring 0 stays outside the focus order.
- The board camera supports accessible zoom-out, zoom-in, percentage, and reset controls; wheel zooms around the pointer; pointer or touch drag pans after a movement threshold. Panning must suppress the resulting tile click, while an unmoved tile press still selects normally. Default scale is `100%`, clamped to `75%-250%`.
- The persistent header exposes population and all six canonical resource balances. Food and Biomass carry opening values; Water, Fuel, Metal, and Minerals begin at zero but may rise through market purchases before their ring-1 production technologies are Researched. Coin remains beside them as a separate market balance. Generic Materials is absent.

## 9. Rings as eras

Ring 1 is the crude production foundation. Rings 2–4 are the technological eras contained in Act II.

|Ring|Era|Nodes|
|-|-|-|
|0|Neutral foundation|1 undivided logical hex|
|1|Crude production|6 technologies|
|2|Settlement works|12 technologies|
|3|Craft|18 technologies|
|4|Early industrial|24 technologies|

Act II ends at ring 4. Any outward expansion belongs to a separate Act III specification and must not be rendered, labeled, or reserved on the Act II board.

Net fishery is ring 2 on the Food–Water edge and unlocks Fishing net production through BUILD.

---

## 10. Technologies, rings 1–4

Format: **Name** — effect. Coordinates are axial `(q, r)`.

### Ring 1 — Crude production (all pure)

All six technologies are reachable from the ring-0 hub. Two carry forward as Researched from Act I; the remaining four begin Available and use Food + Biomass research costs.

|Coord|Resource|Initial state|Technology|
|-|-|-|-|
|`(1, 0)`|Food|Researched|**Foraging** — establishes Food gathering at Act II population scale; does not re-unlock the existing personal Forage action|
|`(0, 1)`|Water|Available|**Spring well** — establishes local fresh-water production|
|`(-1, 1)`|Fuel|Available|**Firepit** — establishes local conversion of Biomass into Fuel|
|`(-1, 0)`|Metal|Available|**Surface ore** — establishes local gathering of native copper and bog iron|
|`(0, -1)`|Minerals|Available|**Quarry pit** — establishes local gathering of loose stone and clay|
|`(1, -1)`|Biomass|Researched|**Woodcutting** — establishes Biomass gathering at Act II population scale; does not re-unlock the existing personal Split wood behavior|

### Ring 2 — Settlement works

Ring 2 establishes the first production systems of a small settlement. These are known techniques being organized at local scale, not historical discoveries.

Pure:

|Coord|Resource|Technology|
|-|-|-|
|`(2, 0)`|Food|**Gamekeeping** — managed traps and hunting grounds; steadier food from wildlife|
|`(0, 2)`|Water|**Well & cistern** — reliable water extraction and storage; buffers dry periods|
|`(-2, 2)`|Fuel|**Charcoal works** — controlled conversion of Biomass into Fuel at improved yield|
|`(-2, 0)`|Metal|**Smithy** — shapes and repairs available metal; unlocks basic metal tools|
|`(0, -2)`|Minerals|**Stoneworks** — dressed stone and aggregate; sturdier foundations and buildings|
|`(2, -2)`|Biomass|**Loom & ropewalk** — produces rope and cloth; enables clothing and rigging|

Hybrid (`k = 1`):

|Coord|Edge|Technology|
|-|-|-|
|`(1, 1)`|Food–Water|**Net fishery** — organized coastal fishing; unlocks Fishing net production|
|`(-1, 2)`|Water–Fuel|**Peat works** — drains, cuts, and dries wetland peat for Fuel|
|`(-2, 1)`|Fuel–Metal|**Smelting hearth** — charcoal-fired ore reduction; establishes worked-metal production|
|`(-1, -1)`|Metal–Minerals|**Masonry workshop** — metal tooling for shaping stone; improves Minerals yield|
|`(1, -2)`|Minerals–Biomass|**Pottery works** — fired vessels for storage; reduces spoilage|
|`(2, -1)`|Biomass–Food|**Field cultivation** — expands garden-scale growing into reliable crop production|

### Ring 3 — Craft

Pure:

|Coord|Resource|Technology|
|-|-|-|
|`(3, 0)`|Food|**Salting & smoking** — preserve food; much lower spoilage|
|`(0, 3)`|Water|**Aqueduct** — move water across distance|
|`(-3, 3)`|Fuel|**Coal mining** — extract coal seams; big fuel yield|
|`(-3, 0)`|Metal|**Bronze casting** — alloys; better tools and weapons|
|`(0, -3)`|Minerals|**Brickworks** — fired brick; cheap durable construction|
|`(3, -3)`|Biomass|**Carpentry** — joinery and planks; larger wooden buildings|

Hybrid (`k = 1` nearer the first resource, `k = 2` nearer the second):

|Coord|Edge|k|Technology|
|-|-|-|-|
|`(2, 1)`|Food–Water|1|**Fishing boats** — reach deep water; +food|
|`(1, 2)`|Food–Water|2|**Irrigation canals** — farms no longer need river adjacency|
|`(-1, 3)`|Water–Fuel|1|**Water wheel** — mechanical power from rivers|
|`(-2, 3)`|Water–Fuel|2|**Tar pits** — collect surface oil and bitumen|
|`(-3, 2)`|Fuel–Metal|1|**Bellows forge** — hotter fires; faster smelting|
|`(-3, 1)`|Fuel–Metal|2|**Iron smelting** — iron replaces bronze|
|`(-2, -1)`|Metal–Minerals|1|**Nails & fittings** — cheaper construction|
|`(-1, -2)`|Metal–Minerals|2|**Glassblowing** — glass from sand; windows and vessels|
|`(1, -3)`|Minerals–Biomass|1|**Lime kiln** — mortar; stone buildings gain height|
|`(2, -3)`|Minerals–Biomass|2|**Papermaking** — paper; boosts coordination and record-keeping|
|`(3, -2)`|Biomass–Food|1|**Animal husbandry** — livestock; food plus hide|
|`(3, -1)`|Biomass–Food|2|**Granary** — bulk food storage|

### Ring 4 — Early industrial

Pure:

|Coord|Resource|Technology|
|-|-|-|
|`(4, 0)`|Food|**Selective breeding** — higher crop and livestock yields|
|`(0, 4)`|Water|**Pumping station** — deep wells; water anywhere|
|`(-4, 4)`|Fuel|**Coke ovens** — refine coal to coke; high-grade fuel|
|`(-4, 0)`|Metal|**Precision machining** — machine parts; +efficiency for metal buildings|
|`(0, -4)`|Minerals|**Portland cement** — modern concrete|
|`(4, -4)`|Biomass|**Managed forests** — sustainable, high-yield timber|

Hybrid (`k = 1..3`, low `k` nearer the first resource):

|Coord|Edge|k|Technology|
|-|-|-|-|
|`(3, 1)`|Food–Water|1|**Fish farming** — controlled food from water tiles|
|`(2, 2)`|Food–Water|2|**Ice houses** — cold storage; near-zero spoilage|
|`(1, 3)`|Food–Water|3|**Sanitation** — clean water; population health and growth|
|`(-1, 4)`|Water–Fuel|1|**Hydropower** — dams; large mechanical/electric energy|
|`(-2, 4)`|Water–Fuel|2|**Steam engine** — fuel to work; powers factories|
|`(-3, 4)`|Water–Fuel|3|**Oil drilling** — well technology applied to oil; unlocks petroleum|
|`(-4, 3)`|Fuel–Metal|1|**Blast furnace** — coke-fired; mass iron|
|`(-4, 2)`|Fuel–Metal|2|**Steelmaking** — steel; unlocks all late structures|
|`(-4, 1)`|Fuel–Metal|3|**Railways** — rail transport; logistics across the map|
|`(-3, -1)`|Metal–Minerals|1|**Deep mining** — shaft mines; both ore and stone yields|
|`(-2, -2)`|Metal–Minerals|2|**Reinforced concrete** — steel + concrete; tall buildings|
|`(-1, -3)`|Metal–Minerals|3|**Plate glass** — large panes; greenhouses and factories|
|`(1, -4)`|Minerals–Biomass|1|**Porcelain** — fine ceramics; trade goods and money|
|`(2, -4)`|Minerals–Biomass|2|**Pulp mill** — industrial paper; large coordination boost|
|`(3, -4)`|Minerals–Biomass|3|**Lumber yard** — standardized timber; cheap fast building|
|`(4, -3)`|Biomass–Food|1|**Fertilizer** — compost and manure; +farm yield|
|`(4, -2)`|Biomass–Food|2|**Crop rotation** — sustained soil; no yield decay|
|`(4, -1)`|Biomass–Food|3|**Food processing** — mills and presses; food output multiplier|

---

## 11. Quick verification checklist

### Act handoff and vocabulary

- Act I context is explicit: one person, Food plus generic Materials, rudimentary ACTIONS/BUILD, and Shelter as the transition.
- At the curtain, Food carries forward and only the unspent Materials balance converts `1:1` into Biomass; built goods remain unchanged.
- Generic Materials is absent from Act II balances and research costs.
- Foraging and Woodcutting begin Researched; Spring well, Firepit, Surface ore, and Quarry pit begin Available and cost Food + Biomass.
- At Act II entry, exactly Gamekeeping, Net fishery, Pottery works, Loom & ropewalk, and Field cultivation are Available in ring 2; other outer technologies are Locked.
- Gamekeeping, Loom & ropewalk, and Field cultivation use Food/Biomass opening costs; Net fishery uses Biomass/Water; Pottery works uses Biomass/Minerals.
- Typed resources can be bought from finite market lots before their local ring-1 production technology is Researched.
- Every resource type required by an Available technology has a current route through holdings, production, or authored market stock.
- There is no Knowledge resource, research-point counter, or discovery mechanic.
- Wood/Fibre/Stone/Iron are not resource-accounting keys; Coin remains separate from research resources.

### Ring-0 foundation

- Ring 0 is one undivided, visually unlabeled neutral hex accessibly named **Ring 0 foundation**.
- It has no segment codes, hit targets, hover/focus expansion, touch pinning, query state, or research action.
- It remains the common logical Researched neighbor of all six ring-1 technologies and permits camera drag from the center.

### Geometry and classification

- Food corner is at 3 o'clock; wedges run clockwise Food → Water → Fuel → Metal → Minerals → Biomass.
- Ring `n` has exactly 6 pure and `6(n - 1)` hybrid hexes.
- The complete Act II board is rings 0–4 and contains exactly 61 logical hexes; it exposes no placeholder rings for Act III.
- Hybrid identity comes from exact axial coordinates, not screen-angle rounding.
- Hybrid templates are switchable through the generated toolbar selector, `?hybrid=<id>`, and the public board API without rebuilding tiles or changing progression/camera state.
- `rails-all` is the default: 24 pure technologies each have one full six-edge rail, while 36 hybrids each have two three-edge rails, for 96 resource-rail paths total; R0 has none.
- `rails` keeps only the 72 hybrid rail paths visible and restores unmuted pure bodies.
- `blend` hides all rails, restores unmuted pure bodies, and gives all 36 hybrids their unique tangent gradients with `32%`/`68%` held endpoints and radial midpoint seams.
- Material-reference markers follow the exact count table: ring 1 = 6 dots total, ring 2 = 18, ring 3 = 36, and ring 4 = 66; pure ring-3/ring-4 tiles have two, while ring-4 hybrids have three.
- Dashed stage-circle guides and `R0`/`R1`-`R4` board overlays are absent; perimeter resource labels and the bottom board summary remain.

### Progression and interaction

- Locked tiles have no label and are not interactive; Available and Researched tiles are inspectable.
- An unaffordable technology remains Available and reports its missing resource bundle without suggesting production or market routes.
- Research uses **RESEARCH →**, consumes its authored resource bundle atomically, and never consumes Coin, Knowledge, or generic Materials.
- Researching a tile lights only eligible immediate outward neighbors; nothing opens elsewhere.
- Research never constructs an item directly; resulting goods remain in BUILD.
- The board preserves ACTIONS, BUILD, Holdings/BODY, eating policy, and activity. The Act II prototype intentionally omits the persistent event-log footer to reserve vertical space.
- Filters compound as Researched < Available < All, and zoom/pan/reset do not interfere with tile, ring-0, search, or keyboard interactions.
