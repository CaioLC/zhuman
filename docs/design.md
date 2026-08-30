# Human Action — Game Design

What the game is and the rules it plays by. The code that implements it is
[`../src/README.md`](../src/README.md); what's next is [`roadmap.md`](roadmap.md).

## Vision

A terminal-styled **accumulator** that dramatizes Mises' *Human Action*: the arc from
**autistic exchange** (Robinson Crusoe, acting alone) → **interpersonal exchange** (barter,
then money) → the market economy.

The player survives the hardships of being alone (arc one). As they do, more people appear,
allowing specialization, greater capital accumulation and better fulfillment (arc two). As the
small population grows into a city, it connects into a vibrant "global economy" of goods,
letting the city itself specialize (arc three).

A survival game, evolved into a bartering game, evolved into a city sim. All in a terminal.
The progression spine is **accumulated capital → better life → more humans → more accumulated
capital**. In all arcs, you play as a single human.

## Scope: two pillars

**UI and AI, nothing else.** No world, no space, no graphics beyond the terminal HUD —
everything the player sees and does is UI, and everything the world *does* is autonomous
agents. Anything that isn't one of those two pillars is out of scope by default.

## The core challenge

**Designing the *needs* of an infinitely growing, autonomous population.** What each agent
demands, how those demands are ranked under scarcity, and how the model still holds from pop 1
to billions. Needs are what drive every agent's `decide → act`, and what make specialization,
exchange, and markets *emerge* rather than be scripted.

The crux is **autonomy vs. scale**: 10⁹ full deciders is intractable, so the model must degrade
gracefully from individual agents to aggregate demand while keeping preferences subjective and
ordinal — never a global utility function.

## Locked decisions

1. **No rest action.** Vigor refills only through the metabolism loop; the player's lever on it
   is the ration rate, not a rest button.
2. **Population grows on a carrying-capacity model.** Shelter sets capacity, sustained food
   surplus fills it, starvation empties it — so it self-regulates, and a food collapse costs you
   people. Population is a link in the spine, not an abstract tech score.
3. **An ever-expanding catalog, gated by Acts.** Hand-authored, no procedural formulas; each
   Act's slice stays bounded and legible. What each Act adds is under *Act structure* below.
4. **Text-forward UI.** The challenge is to keep the terminal text-centric while giving the
   player the visual perception of evolution between arcs.
5. **Richer risk yields.** Yields are sampled from distributions (normal / poisson / uniform /
   exponential); the p10–p90 band shows as a mini curve. The spread *is* the risk — there is no
   separate success roll.
6. **Terminal identity.** Monospace; compact; distribution curves; panes and tabs to accommodate
   an ever-growing player inventory and capital roster.
7. **A second human is an autonomous agent** — an AI decider ranking the same action catalog,
   not a labor multiplier. The north-star sim; arrives in Act II.
8. **Act II is barter.** The player and every agent hold their own inventories and have demands
   for food and materials. Specialization and comparative advantage make "x wood for y food"
   beat gathering both alone — gains from trade emerge, and with them, typed materials.

## Act structure

- **Act I — Robinson Crusoe (pop 1).** Assets divide into *food* and *materials*. Crude labor
  and the few capital goods a single individual can build (crude spear, rudimentary sandals,
  leaf bed). A merchant passerby offers the first barter — simple goods (a fish net, a hand axe)
  for the food and raw materials the player holds.
  *Win condition:* a sustained food surplus plus shelter capacity for a second person → cross to
  pop 2.
- **Act II — First exchange (pop 2 → band).** An autonomous second agent arrives. Generic
  materials expand into a dozen typed goods; a broader capital roster can be built, stored and
  sold. Demand-driven barter with emergent exchange ratios and specialization by comparative
  advantage. Money arises to ease transactions.
- **Act III+ — village → town → city.** Materials expand further and the player gains access to
  a global source of capital goods, letting the city specialize. Firms, deeper division of labor,
  the long climb to billions.

## Open design questions (Act II)

The first is **the project's core challenge** above — open because a demand model can't be
designed before agents exist, not because it's minor. Record these; don't litigate them yet.

- How agents form **demands** — subjective, ordinal preferences over food vs. materials; needs
  and thresholds; and how it degrades from per-agent deciders to aggregate demand at scale.
- How an **exchange ratio** forms — posted price, bilateral bargaining, or double auction.
- What **specialization** is — per-agent skills, comparative advantage from differing
  yields/vigor, or learning-by-doing.
- **Per-agent inventories** vs. a shared stockpile (barter requires individual holdings).
- **Autonomous decider policy** — how an AI agent ranks the catalog under scarcity.
