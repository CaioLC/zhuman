# UI design

**How the screens are shaped, and why.** [`design.md`](design.md) is what the game *is*;
this is what its interface is. The two are parallel: both describe an intended shape, and
both leave the list of work to [`roadmap.md`](roadmap.md), which stays the only document
that discusses what isn't built.

Mechanism lives elsewhere and is not repeated here — how a node is built and laid out is
[`../src/ui/README.md`](../src/ui/README.md), how a screen binds to it is
[`../src/ui_client/README.md`](../src/ui_client/README.md).

## The one rule

**A surface answers one question.** When a screen answers several, it answers all of them
badly: the shape that serves one question is rarely the shape that serves another, so a
surface with three jobs ends up with the furniture of none of them. A BUILD pane of identical
tiles would be a shop, a catalog and an inventory at once.

Everything below follows from splitting questions apart and giving each its own shape.

| Surface | Question | Shape |
|---|---|---|
| **ACTIONS** | what will this body do now? | a searchable, bounded grid of compact verbs |
| **BUILD** | what can I make next? | a sorted, filtered list of rows |
| **HOLDINGS** | what do I own, and what is it doing for me? | a persistent panel |
| **RESEARCH** | what exists, and what does it take? | a board |
| **MARKET** | who will trade with you? | a list of people (or goods) and a deal slip |

## Grammar

These hold across every screen, and a new one should read as though written by the same
hand.

**Say it in the player's words.** A row says *food keeps twice as long*, not `spoil ×0.5`.
Notation is what a box too small for a sentence forces, and five unit conventions in one
column is what it decays into. Effect text is presentation and lives in
`pages/templates/good_text.zig`, shared by every surface that names a good, so one sentence
serves both "what would this get me?" and "what is it doing for me?" rather than two lists
drifting apart.

**Units the player already reads.** Time in **days**, because the header counts days.
Hours are the authoring unit (`Requires.hours`) and stay out of the interface.

**Every unavailable state says which one it is.** Not-yet-affordable, prerequisite missing,
standing conditions unmet, hands busy, and already-built are five different facts, and
rendering them as one grey is the single largest failure the interface can make. A state
that hides a thing entirely is worse than a grey one — grey at least says the thing exists.

**Derive, never restate.** A number shown beside a number the sim owns will drift from it.
HOLDINGS computes each margin by comparing a live component against its own catalog default
rather than repeating the factor `capital.zig` applies. Where a baseline isn't reachable,
show the current value and say so, rather than copying a constant.

**Interaction reads from the box that owns it.** The interactive node is the outer box, and
its children are content — so a row is hovered as a row even while the pointer is over the
`×` inside it.

## ACTIONS — the verb browser

Twenty unlocked verbs do not fit as large cards, so ACTIONS is one search-first browser
with compact two-column rows. Each row is one full button and carries name, readiness, energy,
time, distribution shape and expected output. Plain text plus `in:`, `out:`, `type:`/`kind:`,
`state:`/`status:` and `is:` qualifiers search all 20 actions; comma alternatives, leading `-` and
`*` use the same grammar as BUILD. The grid also lists the held generator verbs, after the labor
verbs, as the generator tile (collect on the body, the mode corner on its lower right): Check
traps while the wire snares are owned, Tend garden while a garden bed is; a generator answers
`type:generator`, a verb `type:verb`. A toolbar under the search holds the hidden count on the
left and the sort chips `SORT DEFAULT · STATE · NAME · COST · TIME` on the right: a chip
pressed first sorts in its natural direction (DEFAULT the authored order, verbs then
generators; STATE ready first; the rest ascending), pressed again it flips, and equal keys read
by name. Every tile has a `hide` corner at its top right that takes it out of the grid; a
hidden generator keeps running. The count is a toggle, `{n} hidden out of {N} →`, inert
while nothing is hidden: pressed, it opens the hidden view, which lists only the hidden tiles,
dashed and dim with an `unhide` corner, under `← {n} hidden out of {N} · unhide all`,
and the kind, the search and the sort apply there too. `unhide all` empties the set and
returns to the full grid, as the view does by itself when its last tile is unhidden; the set is
per-view UI state and is not saved. The heading's eyebrow, `{n} VERBS · {m} GENERATORS`, is
two kind toggles: pressing one shows that kind alone, pressing it again shows everything.
Every act uses the same ACTIONS pane (`actions_section`); only its content differs (which verbs
and generators, the subtitle and the density). Act I lists the body's verbs and generators at the
regular density; Act II lists the settlement's verbs and the union of both acts' held
generators, compact.

**A generator is collectable passive capital.** Its tile's underbar fills from authoritative
simulation progress; while charging it is not collectable, at completion its state line reads
`ready — collect`, and collection pays the displayed small Vigor/upkeep price and realizes the
complete cycle immediately. Collection never creates or interrupts `Busy`, so a trap round, a
garden's crop, a remedy or the eggs can be collected while the body is already working. The mode corner
cycles `● ON`, `◉ AUTO` and `○ OFF` with one click. On accumulates and waits to be collected;
auto collects each complete cycle itself whenever it is payable; off freezes its current progress
and consumes nothing, and turning it on resumes from that exact point. At Act II's compact
density the state word rides the name row, so a generator tile stands as tall as a verb tile.
A generator's cost and yield are authored per cycle. Gather remedy restores direct Vigor
without raising its ceiling. No generator transfers resources every frame. Selling the good
that opens a generator stops its cycle where it stands; a second unit runs no second cycle.

The action collection—not the whole play surface—scrolls on desktop. Eating Policy is not a verb,
so it lives on the Household rail under BODY in both acts, collapsing with it. It is a `0..100` slider, not a set of named
rations: the rate is `0.5 × 4^(value/100)`, so the ends are half and double the normal
appetite and `50` is normal, and the slider's word (`meager`, `lean`, `modest`, `normal`,
`hearty`, `generous`, `lavish`) steps every sixteen points. The panel reads
`{word} · {rate}×` and projects coverage (how long the larder lasts) and recovery (days to
full vigor) from the same arithmetic the metabolism loop runs; the simulation stores only
the resulting bounded multiplier. A count-only summary reports `<visible> of 20 actions
shown`.

## BUILD — the shop

A list of **rows**, six fixed columns, sorted so the top is always the next thing.

```
Root cellar     10m 4e   0.5d   food keeps twice as long        Build →
Hatchet         48m 2e   4.2d   you can split wood        ▁▁▁  31/48m
Garden bed      12m 4e   0.7d   grows food on its own      ▓▓▁  0.3d left  ×
Work gloves     24m 1e   2.1d   splitting wood costs less  needs Split wood
```

*name · cost · time · what it changes · state · corner.* The last two carry everything a
plain grey row would hide: `Build →`, a reach meter against the limiting stock, time remaining, or
the verb a blocked good is waiting on.

**A build in progress keeps its row.** It does not become a bar on a dim box — it stays in
place, pinned to the top under every sort, and its corner is how you abandon it. A long
build with an emptying larder needs a visible way out.

**Search first; sort on demand.** A larger catalog makes fixed groups less useful, not more.
BUILD remains one list behind one search field. Plain text searches names, effects and costs;
`in:<resource>` and `out:<resource>` inspect recipe edges; `type:<kind>` covers generator,
tool, comfort, storage and shelter; `state:<state>`/`is:<value>` inspect current
state or kind. Tokens are ANDed, comma values are alternatives, a leading `-` excludes, and
`*` exposes the complete catalog. `/` focuses the field and Escape clears it.

A blank query shows the act's complete shelf — owned and distant recipes included, disabled
rather than hidden — and typing only narrows it. Act I's shelf is what its gates allow: a recipe
is listed once every gate of its `requires` passes, so the manufactured tier (gloves, cookpot,
bicycle, chicken coop) appears when the crude good or verb before it is held, and its row names
the tier beside its kind (`tool · manufactured`); a recipe whose gate fails is absent. Act II
lists research-gated and prerequisite-short recipes disabled. Every act uses the same BUILD pane
(`build_section`); only its content differs: which records are the act's recipes, whether a
failed gate hides one, the subtitle, and the milestone card. So no FILTER, SHOW, built, preset or
syntax-help rows are needed, and every recipe stays reachable.

**Sort from the column headers.** RECIPE (name), COST (order size), TIME and STATE (reach) are
sortable: clicking one sorts on it in its natural direction — STATE nearest first, the others
cheapest, quickest, A–Z — and clicking it again flips the direction. Only the column in force
wears an arrow (`↑`/`↓`) and reads in `fg`. The header row is one Tab stop; arrows rove across its
columns and Enter/Space sorts. The default is STATE ↓.

The summary is count-only (`{shown} of {total} recipes shown`); balances already live in the
header. A build in progress remains visible regardless of query and linked research updates
recipe state without rebuilding the list. There is no explanatory footnote: the browser and
goal card must explain themselves.

Defaults are the whole design: most players never touch the controls, so the blank view keeps
every recipe reachable without typing. ACTIONS and BUILD use one shared catalog scroll element
and the same global scrollbar treatment. The six-column heading is sticky, and a long list
leaves search, Exchange and the event log fixed.

**The log is part of ACTIONS and BUILD.** One four-line live event log occupies the terminal footer
on both panes and keeps its place while their result collections scroll. Lines read newest
first, each stamped with the game day and time it happened (`D19 11:45`); the newest is painted
at full tone while older lines dim a step; a gain
reads in the `good` tone. The feed keeps up to 64 lines; the footer is a four-row scroll region,
so it rests on the newest four and the wheel, the scrollbar or the keyboard reaches older ones. RESEARCH and MARKET
hide it to recover their height. At 760 px and below the fixed-height workspace is released: the page is one
scroll, the Household rail sits above the surface (HOLDINGS and BODY side by side at 760, stacked below 560),
ACTIONS and BUILD take their natural height, narrow BUILD drops lower-priority columns, and the log
remains at the end of the document. RESEARCH drops its detail under a 560 px board there.

**Every scroll answers the keyboard.** A scroll region that overflows is a Tab stop and the scroll owner of the
controls inside it: Up/Down move a line, Page Up/Down a viewport, Home/End go to the ends, and a newly focused
control inside it is scrolled into view. The wheel goes to the innermost region under the pointer, so the log
or the board never also scrolls the page around it.

**The goal card ends the act but is not filtered with ordinary goods.** One milestone
component serves both acts: a fixed semantic bar, a disclosure whose summary carries title,
readiness and a compact line, a primary action enabled only when ready, and disclosed
details (kicker, cost, copy, a live requirement row, an explanation). Its lifecycle is
`locked → unfunded → ready → done`, and every requirement is recomputed from live state each
frame and shown as `current/required`, so an unmet gate is a readable fact. In Act I this is
the Shelter, which asks for a rested body, a stocked larder, several kinds of goods already
made, and the materials for the largest build in the act; raising it pays through the same
build path as any recipe, and the curtain falls only when the build completes. In Act II it is
the **Exchange**, a standing trading floor. Its recipe is unlocked
only when population is strictly greater than 500 and at least one ring-4 technology is
Researched. The recipe costs 80 Biomass, 40 Minerals and 24 Metal and takes 18 days. Raising it pays those inputs, replaces the temporary passerby-descended merchant row
with a permanent Exchange, and opens Act III. A compact Exchange bar remains fixed below the
recipe scroller and outside filtering; its Details disclosure shrinks the list rather than growing
the pane. Locked, unfunded, ready and standing facts remain available in the disclosed body.

## HOLDINGS — the readout

A panel, never opened, because its value peaks while you are looking at something else. It
lives in the left rail, which collapses to a 36 px strip carrying a chevron and the label set
vertically; ACTIONS and BUILD each remember their own collapse, and entering RESEARCH or
MARKET forces the rail closed without touching those memories.

Three blocks. The **roster** names each owned kind with its count, since a good is not
one-per-agent: a second pair of sandals is stock, made to trade. Kinds and units are
different numbers and shown as both — four pairs of sandals are never four goods built.

The **margins** block is the reason the panel exists. Three modifiers land on Forage and
nothing else on screen explains why it costs 1.7 energy instead of 2. Every row here is
derived from a live component against its catalog default, and colored by direction: a cost
below its default is a gain, above it a penalty.

The **BODY** block projects the larder forward: how many days of food remain at the current
appetite, and whether vigor is recovering, already full, starving, or stalled on food that
feeds but does not restore. Both numbers come from the simulation's own arithmetic, never a
copied constant.

## Playback controls

The compact `<< {speed} >>` stepper sits on the HUD's right, after the run context and before
`MENU`. Its one linear scale is PAUSE, 1×, 2×, 3×: the chevrons step it and dim at their bound, and
the value cell is fixed-width so stepping never moves them. It is one accessible slider ("Simulation
speed"): arrows step, Home pauses, End jumps to 3×; the chevrons are pointer targets, not extra Tab
stops. Stepping up out of PAUSE lands on 1×. State persists across tabs and fresh runs.
The multiplier applies only to simulation time: clock, spoilage, metabolism, work, passerby phases,
and generator accumulation advance together. Pause skips that complete simulation stage without
cancelling `Busy`, discarding generator progress, or changing the selected speed. Input, rendering,
roster reload polling, and UI motion remain on real frame time, so controls, modal dismissal, and
transitions stay responsive while paused or at faster game speeds.

## Session menu

`MENU` sits at the far right, after the speed stepper. It opens the session menu on the trade
dialog's shell, through the same focus trap, Escape handling, and opener restoration; a click on
the backdrop does nothing. Opening pauses the simulation and remembers whether it was already paused; the HUD
behind it is frozen. The kicker reads `PAUSED · ACT {n} · DAY {d}` and the title names the
screen. The menu lists Continue, Save, Load, Settings and Quit to menu. Save and Load share one
list of three slots that flips its verbs (`SAVE HERE`/`OVERWRITE`, `LOAD`), each slot describing
the settlement it holds. Settings is the panel the title screen shares: difficulty, tutorial,
music, effects, UI scale, brightness, contrast and window — gameplay, then sound, then display.
Brightness (80–140% in fives) multiplies every colour on screen, live while the slider moves,
the screen behind the panel as well as the panel. Quit is the one destructive choice, so it is the one that
confirms, naming the day it would lose and offering to save first. Escape on a sub-screen returns
to the menu; on the menu, Escape or × resumes. Speed is the header stepper's alone.

## Title screen

Before a run, the title screen shows the game itself, receded: a ticking stockline, the merchant
strip, work filling and an event log behind a wordmark and the menu list (Continue, New game,
Settings, Credits, Quit). Continue stays visible but disabled, saying there is no settlement to
resume, because a hidden control teaches nothing.

## The market strip and the trade dialog

One strip and one dialog serve every counterparty the game will have; an identity map supplies
the glyph and wording (`● PASSERBY`, `● MERCHANT`, `◆ EXCHANGE`), the kicker and title, the
ledger heads and give-label for each direction, and the call to action. The strip reports who
is here and offers one action; the dialog is a modal with BUY/SELL tabs over a **ledger** of lots
on the left and a **deal slip** on the right.

**A lot is a quote, and a quote can be refused.** Each ledger row names the lot, says what you
already hold of what it moves, shows the counterpart bundle and either how many lots you could
take or, in danger, why you cannot — sold out, you hold too little, or how much more you need.
A refused row can still be selected; the slip explains it. The slip takes a lot count (linear
in the lot), shows what you give and receive and the before → after of every stock the deal
touches, and settles. Settling is atomic, and it does not close the dialog: a visit is one
sitting, the footer keeps a running tally of what the visit has moved, and the header, HOLDINGS
and the log reflect each settlement in the same frame. Search and pages appear only when a
direction holds more lots than fit. Switching direction selects the first lot that can be
taken; closing the dialog returns focus to the control that opened it.

**The dialog holds one size and its call to action holds its place.** The body under the tabs is
410px high whatever lot is selected, whichever tab is open and however many lots have sold out.
The slip stacks its heading, a content region and the call to action pinned at its foot: only
the region scrolls, so a tall lot (a two-resource price, three AFTER rows, a consequence) never
pushes the call to action out of view, and a short or refused lot leaves it in the same place.
At 410px the tallest authored slip fits without scrolling. Stacked (≤760px) the body is 460px,
the ledger above a 250px slip, and the slip's region scrolls there.

In Act I the counterparty is the passerby, who arrives on the simulation's clock, lingers
with a small satchel, and leaves; the strip reads that state and never infers it from the
day count. While absent the strip is dim and disabled and its `TRADE →` link is hidden. While
present the link returns and opens the dialog.

## MARKET — the neighbours

Act II's MARKET tab is a view, not a dialog, and its primitive is a person, not a good. With
few neighbours the list reads as people in sentences; with many it collapses to goods in
notation, each with a price range drawn only from trades that happened. A deal composes both
sides on the shared deal slip, and a refusal is answered in the counterparty's own valuation.
YOUR STALL posts sells and buys at your own prices — what the neighbours read while you work —
and each post says how many would take it at that price. Like RESEARCH it owns the whole
surface: the strips and the log step aside and the Household collapses.

## RESEARCH — the board

The board is built as a hex of sixty technologies around a neutral foundation, four rings
out (the four eras: crude production, settlement works, craft, early industrial), six wedges
for the six resources. A tile is locked (a silhouette with no label), available, or
researched; a tile becomes available when a researched neighbour on a lower ring touches it,
and nothing else opens. Selecting a tile shows its ring, era, kind and state, what it costs
against what is held, what it does, and what it opens outward; `RESEARCH →` pays the cost at
once and establishes it, or names what is short. The camera zooms on the wheel about the
pointer and pans on a drag; the arrows walk the lit tiles and Escape clears the selection.
Filters (researched, available, all) and a search dim what they leave out rather than
removing it, so the map keeps its shape. The filters are cumulative from narrow to broad:
`all` keeps the anonymous locked silhouettes, and a search never reveals a locked tile's label.

**Tile states.** A locked tile is the resource colour at about 24% opacity with no label, and
is neither selectable, clickable nor a focus target. An available tile is at about 66%, labelled
and interactive. A researched tile is at full opacity with a marker, and stays selectable to
inspect. Affordability is not a state: an available tile the settlement cannot pay for stays
available, and its action reads the deficit as a fact, `NEEDS 2 BIOMASS · 1 FOOD`, never a
route to cover it. A researched tile has no repeat action. Locked labels are hidden so that
progression and the silhouette of the board stay legible, not because the society lacks the
knowledge.

**Resource identity.** A pure tile's body is its resource colour toned toward neutral and a
hybrid's is the toned midpoint of its two. A pure tile has one inset closed rail in its
colour on all six edges; a hybrid has two, each resource owning the three contiguous edges
nearest its direction, so the pair partitions the six without overlap: 24 closed rails and 36
hybrids of two make 96 rail paths. Small material dots near a tile's lower edge show its
composition (the rule is in [`../src/README.md`](../src/README.md), *The research board*); they
do not replace the full cost in the detail pane. `HYBRID` in the detail and the tooltip is the
textual cue for the same fact. The six resource colours are equal in lightness, so bodies,
rails and dots stay distinct without harsh seams (`src/palette.zig`).

**The board's surface.** The foundation is one undivided neutral hex with no label, no rail
and no interaction: its accessible name is *Ring 0 foundation*, it is never a focus target,
hover target or action, and a camera drag may start from it. The board has no circular or
wedge backdrop, no stage-circle guides, no ring labels and no summary beneath it; the only
text outside the tiles is the six resource labels on the perimeter, on a neutral-cool charcoal
surface.

**Reading a tile.** Hovering a lit tile shows a tooltip with its name, ring, domain and state.
The detail pane shows the name, ring and era, pure or hybrid domain, state, effect, authored
cost against what is held, the deficit, and what it enables. It never offers BUILD: research
can open a recipe, and BUILD stays the construction surface. The camera has zoom-out, zoom-in,
percentage and reset controls; the scale is 100% by default and clamped to 75%–250%. A drag
pans once it passes a small movement threshold and suppresses the click that ends it, while a
press that did not move selects. Expanding or collapsing HOLDINGS never rebuilds or resets the
board.

A tile's ring is its stage and its sextant its specialization: a ring at distance *n* holds
exactly *6n* tiles, so the radius is the length of production, centre the gifts of nature and
the outer rings later stages. A tile on a seam between two wedges belongs to both trades,
which falls out of the grid rather than being authored.

**Say stages, not orders.** Menger numbers inward from consumption — first-order is the
loaf — so on a board with nature at the centre, "higher order outward" inverts him.
Böhm-Bawerk's stages run raw to finished, which is the direction drawn.

The board is the map and the place research is paid for; BUILD is the shop.

## Constraints that shape the work

Real limits. Their *fixes* are in [`roadmap.md`](roadmap.md); what they mean for a screen is
here.

- **A text leaf has exactly one fit** — free, wrapped to a width, a clipped or ellipsized
  cell of a fixed width, or vertical — chosen where it is created. A string past the text
  cap is refused whole and draws nothing rather than a cut tail (the cap is in
  [`../src/ui_client/README.md`](../src/ui_client/README.md)); copy that must exceed it is
  wrapped or split across nodes.
- **The font is monospace**, so a column's capacity is a character count: roughly 8px per
  character at body size. A cell of fixed width clips or ellipsizes; a free leaf grows.
- **An in-tree popup has no top layer.** A select's open list is painted under, and loses
  hits to, whatever follows it in the tree, so its options are reliable only where nothing
  follows them. Only separate roots (the tooltip, the modal) float.
- **The search shortcut ignores the focus trap.** With a dialog open, `/` still reaches the
  catalog's search field behind it.
- **Keyboard operation exists; screen-reader export does not.** Every control is reachable
  by Tab or a roving group, shows keyboard focus (a large element by lifting its label to
  accent, a small control by its outline), and states its condition by copy and shape as well
  as hue; the semantic tree is built but no platform exposes it. Focus shows only after
  keyboard input, as `:focus-visible` does; a click on clear space or Escape drops it, and
  Escape with nothing to dismiss opens the session menu.
- **Verification is by eye.** No synthetic input reaches the platform, so a screen is
  confirmed with a screenshot and, for a state that is hard to reach, a temporarily seeded
  world — never by a test that clicks.
