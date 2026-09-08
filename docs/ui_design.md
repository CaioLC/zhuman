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
`*` use the same grammar as BUILD. The adjacent sort disclosure offers none/ready/time/energy/name
and both directions. None restores authored order and disables Direction.

The action collection—not the whole play surface—scrolls on desktop. Eating Policy is not a verb,
so it remains fixed below that collection. A count-only summary reports `<visible> of 20 actions
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

A blank query shows every eligible in-reach, unowned recipe after ordering; the current prototype
fixture exposes nine. As soon as the player types, the query searches all 50 recipes, including owned
and currently distant goods. That removes the need for visible FILTER, SHOW, built, preset, or
syntax-help rows while keeping every recipe reachable.

The icon immediately beside search toggles one Notion-style second row with the search field's
same width and 30 px height. Native selects choose **Sort by** none/reach/input cost/time/name
and **Direction** ascending/descending. Choosing none restores catalog order, resets and disables
Direction, and persists explicitly as `buildsort=none`. The row closes with the same icon or Escape
and returns focus to the icon. Query, sort, direction and disclosure state are shareable through
`buildq`, `buildsort`, `builddir`, and `buildsortopen=1`.

The summary is count-only (`9 of 50 recipes shown` in the current default); balances already live in the header. A build
in progress remains visible regardless of query and linked research updates recipe state without
rebuilding the list. The removed explanatory footnote is not replaced: the browser and goal card
must explain themselves.

Defaults are the whole design: most players never touch the controls, so the default view keeps
every currently eligible recipe reachable without typing. ACTIONS and BUILD use one shared catalog
scroll element and the same global scrollbar treatment; the current nine-recipe BUILD default
naturally overflows it. The six-column heading remains sticky, while even broad 50-row queries leave
search, Exchange and the event log fixed.

**The log is part of ACTIONS and BUILD.** One four-line live event log occupies the terminal footer
on both panes and keeps its place while their result collections scroll. STRUCTURE alone hides it to
recover board height. Below 760 px the fixed-height workspace is released: ACTIONS and BUILD return
to normal document scrolling, narrow BUILD drops lower-priority columns, and the log remains at the
end of the document rather than creating nested touch scrollers.

**The goal card ends the act but is not filtered with ordinary goods.** In Act I this is the
Shelter. In Act II it is the **Exchange**, a standing trading floor. Its recipe is unlocked
only when population is strictly greater than 500 and at least one ring-4 technology is
Researched. The prototype recipe costs 80 Biomass, 40 Minerals and 24 Metal and takes 18
days. Raising it pays those inputs, replaces the temporary passerby-descended merchant row
with a permanent Exchange, and opens Act III. A compact Exchange bar remains fixed below the
recipe scroller and outside filtering; its Details disclosure shrinks the list rather than growing
the pane. Locked, unfunded, ready and standing facts remain available in the disclosed body.

## HOLDINGS — the readout

A panel, never opened, because its value peaks while you are looking at something else.

Two blocks. The **roster** names each owned kind with its count, since a good is not
one-per-agent: a second pair of sandals is stock, made to trade. Kinds and units are
different numbers and shown as both — four pairs of sandals are never four goods built.

The **margins** block is the reason the panel exists. Three modifiers land on Forage and
nothing else on screen explains why it costs 1.7 energy instead of 2. Every row here is
derived from a live component against its catalog default.

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

- **A text node is one line, and overruns its buffer silently** (the cap is in
  [`../src/ui_client/README.md`](../src/ui_client/README.md)), so a long string loses its
  tail and reads as a layout bug. Long copy splits across nodes.
- **The font is monospace**, so a column's capacity is a character count: roughly 8px per
  character at body size. A fixed-width cell does not clip, so an overlong string bleeds
  into its neighbour.
- **There is no reflow.** Columns are anchored and grow, so a panel needs its space to
  exist at the window's default size — which is why HOLDINGS is not yet beside the resource
  readout.
- **Nothing is keyboard-reachable.** Every affordance is a pointer target.
- **Verification is by eye.** No synthetic input reaches the platform, so a screen is
  confirmed with a screenshot and, for a state that is hard to reach, a temporarily seeded
  world — never by a test that clicks.
