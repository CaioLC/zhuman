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
surface with three jobs ends up with the furniture of none of them. The BUILD pane was
sixteen identical tiles because it was simultaneously a shop, a catalog and an inventory.

Everything below follows from splitting questions apart and giving each its own shape.

| Surface | Question | Shape |
|---|---|---|
| **ACTIONS** | what will this body do now? | a searchable, bounded grid of compact verbs |
| **BUILD** | what can I make next? | a sorted, filtered list of rows |
| **HOLDINGS** | what do I own, and what is it doing for me? | a persistent panel |
| **STRUCTURE** | what exists, and what does it take? | a board |

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

Twenty unlocked verbs no longer fit as large cards. ACTIONS therefore uses one search-first browser
with compact two-column rows. Each row remains one full button and carries name, readiness, energy,
time, distribution shape and expected output. Plain text plus `in:`, `out:`, `type:`/`kind:`,
`state:`/`status:` and `is:` qualifiers search all 20 actions; comma alternatives, leading `-` and
`*` use the same grammar as BUILD. ACTIONS does not sort: verbs read in authored order. Every act
uses the same ACTIONS pane (`actions_section`); only its content differs (which verbs, the
subtitle, and Act I's eating policy at the foot of the grid).

The action collection—not the whole play surface—scrolls on desktop. Eating Policy is not a verb,
so it remains fixed below that collection. It is a `0..100` slider, not a set of named
rations: the rate is `0.5 × 4^(value/100)`, so the ends are half and double the normal
appetite and `50` is normal, and the slider's word (`meager`, `lean`, `modest`, `normal`,
`hearty`, `generous`, `lavish`) steps every sixteen points. The panel reads
`{word} · {rate}×` and projects coverage (how long the larder lasts) and recovery (days to
full vigor) from the same arithmetic the metabolism loop runs; the simulation stores only
the resulting bounded multiplier. A count-only summary reports `<visible> of 20 actions
shown`; query and sort state use `actionq`, `actionsort`, `actiondir` and `actionsortopen=1`.

## BUILD — the shop

A list of **rows**, six fixed columns, sorted so the top is always the next thing.

```
Root cellar     10m 4e   0.5d   food keeps twice as long        Build →
Hatchet         48m 2e   4.2d   you can split wood        ▁▁▁  31/48m
Garden bed      12m 4e   0.7d   grows food on its own      ▓▓▁  0.3d left  ×
Work gloves     24m 1e   2.1d   splitting wood costs less  needs Split wood
```

*name · cost · time · what it changes · state · corner.* The last two carry everything the
grey used to hide: `Build →`, a reach meter against the limiting stock, time remaining, or
the verb a blocked good is waiting on.

**A build in progress keeps its row.** It does not become a bar on a dim box — it stays in
place, pinned to the top under every sort, and its corner is how you abandon it. A long
build with an emptying larder needs a visible way out.

**Search first; sort on demand.** A larger catalog makes fixed groups less useful, not more.
BUILD remains one list behind one search field. Plain text searches names, effects and costs;
`in:<resource>` and `out:<resource>` inspect recipe edges; `type:<kind>` covers generator,
tool, comfort, storage, transport and material; `state:<state>`/`is:<value>` inspect current
state or kind. Tokens are ANDed, comma values are alternatives, a leading `-` excludes, and
`*` exposes the complete catalog. `/` focuses the field and Escape clears it.

A blank query shows the act's complete shelf — owned, distant, prerequisite-short and
research-gated recipes included, disabled rather than hidden — and typing only narrows it. Every
act uses the same BUILD pane (`build_section`); only its content differs: which records are the
act's recipes, the subtitle, and the milestone card. That removes the need for visible FILTER,
SHOW, built, preset, or syntax-help rows while keeping every recipe reachable.

**Sort from the column headers.** RECIPE (name), COST (order size), TIME and STATE (reach) are
sortable: clicking one sorts on it in its natural direction — STATE nearest first, the others
cheapest, quickest, A–Z — and clicking it again flips the direction. Only the column in force
wears an arrow (`↑`/`↓`) and reads in `fg`. The header row is one Tab stop; arrows rove across its
columns and Enter/Space sorts. The default is STATE ↓.

The summary is count-only (`{shown} of {total} recipes shown`); balances already live in the header. A build
in progress remains visible regardless of query and linked research updates recipe state without
rebuilding the list. The removed explanatory footnote is not replaced: the browser and goal card
must explain themselves.

Defaults are the whole design: most players never touch the controls, so the default view keeps
every currently eligible recipe reachable without typing. ACTIONS and BUILD use one shared catalog
scroll element and the same global scrollbar treatment; the current nine-recipe BUILD default
naturally overflows it. The six-column heading remains sticky, while even broad 50-row queries leave
search, Exchange and the event log fixed.

**The log is part of ACTIONS, BUILD, and GENERATORS.** One four-line live event log occupies the terminal footer
on both panes and keeps its place while their result collections scroll. Lines read newest
first, each stamped with the game day and time it happened (`D19 11:45`); the newest is painted
at full tone while older lines dim a step; a gain
reads in the `good` tone. The feed keeps up to 64 lines; the footer is a four-row scroll region,
so it rests on the newest four and the wheel or scrollbar reaches older ones. STRUCTURE alone hides it to
recover board height. Below 760 px the fixed-height workspace is released: ACTIONS, BUILD, and
GENERATORS return to normal document scrolling, narrow BUILD drops lower-priority columns, and the log remains at the
end of the document rather than creating nested touch scrollers.

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
Researched. The prototype recipe costs 80 Biomass, 40 Minerals and 24 Metal and takes 18
days. Raising it pays those inputs, replaces the temporary passerby-descended merchant row
with a permanent Exchange, and opens Act III. A compact Exchange bar remains fixed below the
recipe scroller and outside filtering; its Details disclosure shrinks the list rather than growing
the pane. Locked, unfunded, ready and standing facts remain available in the disclosed body.

## GENERATORS — collectable passive capital

Act I's third work view lists only owned generators as the same compact, action-like tiles used
for labor. A tile's underbar fills from authoritative simulation progress; while charging it is
not collectable, at completion it changes to `ready — collect`, and collection pays the displayed
small Vigor/upkeep price and realizes the complete cycle immediately. Collection never creates or
interrupts `Busy`, so a trap round, food bed, or medicinal herb bed can be collected while the body
is already working.

Every generator carries an independent lower-left `ON`/`OFF` checkbox. Turning it off freezes its
current progress and consumes nothing; turning it on resumes from that exact point. Garden bed and
Wire snares realize their authored per-day resource rates over their cycle duration. Medicinal herb
bed restores direct Vigor without raising its ceiling. No generator transfers resources every frame.

## HOLDINGS — the readout

A panel, never opened, because its value peaks while you are looking at something else. It
lives in the left rail, which collapses to a 36 px strip carrying a chevron and the label set
vertically; ACTIONS and BUILD each remember their own collapse, and entering STRUCTURE forces
the rail closed without touching those memories.

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

`MENU` sits at the far right, after the speed stepper. It opens a top-layer modal through the
same focus trap, outside-click boundary, Escape dismissal, and opener restoration as trade. Opening
temporarily pauses simulation and remembers whether it was already paused: Escape, ×, or an outside
click restores that prior state, while `RESUME` explicitly unpauses. The menu exposes only speed,
reduced motion, resume, and quit. Settings are session-only; raw tuning configuration and destructive
run reset are absent until save persistence and confirmation have a product policy.

## The market strip and the trade dialog

One strip and one dialog serve every counterparty the game will have; an identity map supplies
the glyph and wording (`● PASSERBY`, `● MERCHANT`, `◆ EXCHANGE`), the kicker and title, the
give-label for each direction, the call to action and the footer note. The strip reports who
is here and offers one action; the dialog is a modal with BUY/SELL tabs over three columns —
the offers, a preview of what you give and receive, and your live holdings — and a footer
that confirms.

**An offer is a quote, and a quote can be refused.** Each row has finite stock and, when it
cannot be taken, says why — sold out, no longer affordable, or the counterparty has changed
or left — in place of pretending to be available. A sell shows what the *next* unit would
fetch before you confirm, because repeated units fetch less. Confirming is atomic: the trade
happens whole or not at all, and the header, HOLDINGS and the log reflect it in the same
frame. Switching tabs keeps each direction's selection; closing the dialog returns focus to
the control that opened it.

In Act I the counterparty is the passerby, who arrives on the simulation's clock, lingers
with a small satchel, and leaves; the strip reads that state and never infers it from the
day count. While absent the strip is dim and disabled and its `TRADE →` link is hidden. While
present the link returns and opens the dialog.

## STRUCTURE — the board

*Designed, not built.* A production structure rather than a tech tree, which changes its
topology: videogame trees fan **out**, one item unlocking three, but capital goods are
complementary — a recipe converges on its output, so the graph fans **in**.

**Materials and capital only.** Consumption is deliberately off the board, named once at
the rim. That single decision is what lets the radius mean one thing: **centre is the body
and the gifts of nature, rim is where goods meet the mouth**, raw to finished. The radius
is then the *length of production* — how many stages stand between raw stone and dinner —
and growth radiates outward.

Hex geometry supplies both axes for nothing: a ring at distance *n* holds exactly *6n*
tiles, so **ring is the stage** and **sextant is the specialization**. A tile on a seam
between two wedges belongs to both trades, which falls out of the grid rather than being
authored.

**The chords are the economics.** An edge running radially is deepening your own trade; an
edge running as a chord across the board is needing what somebody else makes. The density
of chords is the degree of division of labour, drawn. Selecting a good lights everything
upstream of it, and the reach of what lights up is what you cannot do alone.

**Say stages, not orders.** Menger numbers inward from consumption — first-order is the
loaf — so on a board with nature at the centre, "higher order outward" inverts him.
Böhm-Bawerk's stages run raw to finished, which is the direction drawn.

**Structure is displayed and costed, never enforced.** A prerequisite is a hard refusal, and
an impossible good has no price to compare against — the merchant would become a key rather
than a counterparty. Building across specializations stays possible at a penalty, because
the lesson is comparative advantage: trade must pay even when you could make it yourself.

Read-only. The board is the map, BUILD is the shop.

## Constraints that shape the work

Real limits, discovered by hitting them. Their *fixes* are in
[`roadmap.md`](roadmap.md); what they mean for a screen is here.

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
  by Tab or a roving group, shows a visible focus ring, and states its condition by copy and
  shape as well as hue; the semantic tree is built but no platform exposes it.
- **Verification is by eye.** No synthetic input reaches the platform, so a screen is
  confirmed with a screenshot and, for a state that is hard to reach, a temporarily seeded
  world — never by a test that clicks.
