# The UI script

**A draft specification.** This is the language screens are written in once composition leaves
Zig: what a script can say, how the host evaluates it, and how it reaches the game. It describes
the intended shape the way [`design.md`](design.md) and [`ui_design.md`](ui_design.md) do; the
order in which it gets built is [`roadmap.md`](roadmap.md)'s. The language has no name yet; this
document calls it *the script*.

The script exists for two reasons. Composition at the client level, pages placing nodes and
composing the template shelf, should be written in a language whose every token is a thing the
element API already does, with nothing of Zig's ceremony around it. And a page should be editable
while the program runs, so a screen is iterated by saving a file, not by a rebuild.

What it is not: a general language, a stylesheet of its own, a way to mutate the world during a
build, or a replacement for the engine. The script drives [`../src/ui_client/README.md`](../src/ui_client/README.md)'s
element API one call per statement; the engine never sees it.

## The model

**The script is the build function.** A page is evaluated from the top every frame, exactly as a
Zig page is: it reads the world and the resources, places nodes, reads interaction off them, and
returns its roots. Nothing is retained between frames except what the pools keep, keyed by the
same structural node keys Zig pages get. So `if` and `for` are ordinary parts of the language, and
a script that runs in 60 microseconds a frame is the expected shape.

**Two tiers, the same two as Zig's.** A `page` places nodes and composes templates. A `template`
paints: it is the only tier that styles a node, places text, or makes a control. The rule is
grammatical, so a page that paints is a load error rather than a boundary-check finding. Script
pages over the Zig shelf come first; script templates follow, through the same grammar, and a Zig
page calls them as it calls the shelf, so pages and templates move to script independently.

**Data is read, never bound.** The script reads `res` and `world`, the two roots every Zig page
reads, through a descriptor the host generates from their types at compile time. No page declares
what it needs and no Zig code is written per page. Functions that compute derived facts are
exported once, library-wide, in two lists: pure ones the script calls inline, and mutating ones it
can only `emit`, which defers the call until the page has finished building.

**State is Zig's.** Pooled state kinds are the ones `UiState` declares, exported by name with the
fields each marks as scriptable. A script names the owner node and the kind; it never holds a
pointer.

**Refusal is visible.** A script that fails to load keeps the previous one on screen and says why.
A script that fails mid-frame paints one error root for that page and says why, once.

## Files

A script file holds one or more file-scope declarations: `page`, `template`, `style`, `look`.
The shipped scripts are embedded at build time; a `pages/` directory in the working directory,
beside `data/`, overrides them file by file and is watched the way `data/` is (`src/reload.zig`),
so a saved file reloads within half a second.

All script files form one namespace. A file-scope name is visible from every file; two
declarations of one name, or a script name that collides with a Zig export, is a load error.

A script file's extension is `.ui`.

## Lexical structure

- **Comments** run from `//` to the end of the line.
- **Identifiers** are `[a-z_][a-z0-9_]*`. Node ids, variables, parameters, declarations and field
  names all use them.
- **Numbers** are decimal literals: `12`, `0.5`, `-4`. A literal with a decimal point is a `num`;
  without one it is an `int`. `50%` is a percentage, legal only as a size.
- **Strings** are double-quoted, UTF-8, with `\"`, `\\`, `\n`, `\u{…}` escapes and
  interpolation: `"{days:.1} DAYS LEFT"`. Inside `{…}` is an expression; after `:` is a format,
  one of `.N` (fixed decimals), `d` (integer), or nothing (default). A `{` that is not an
  interpolation is written `{{`.
- **Enum literals** are `.name`, as in Zig. Their type comes from context: a style role
  (`.dim`), a flow direction (`.row`), a reflected enum (`.food`).
- **Booleans** are `true` and `false`; the absent optional is `none`.
- **Node references** are `@id`; the node a clause belongs to is `@self`.
- **Keywords**: `page template style look let var if else switch for in return roots emit
  consume on early state control and or not orelse then`, plus the node kinds and the placement
  words listed below. Keywords cannot be ids.

A statement ends at a newline. It continues across a newline while a `(`, `[` or `{` is open,
and after a trailing `,`.

## Declarations

```
page <name> { <statements> roots <expr>, … }
template <name>(<params>) [-> { <field>: <type>, … }] { <statements> [return { … }] }
style <name> = [ <fragments> ]
look <name>(<Enum>) { .<tag> => [ <fragments> ], … }
```

- **`page`** is a screen. It takes no parameters; it reads `res` and `world`. It must end with a
  `roots` statement naming its root trees in draw order, later ones on top, each a root handle, a
  template result that is a root or a `Trees` value, or `none`.
- **`template`** is a composition. Its parameters are typed. The id in the call's id position is
  the id of the node the template builds as `self`. Its parent is the node whose block it is called
  from. It may return a record whose fields are handles, values or interaction facts.
- **`style`** names a reusable fragment list, the same shape a bracketed style list has.
- **`look`** is a table from a reflected enum to a fragment list, every tag covered or an `else`
  arm; several tags may share an arm. `name[expr]` uses it as a fragment. Look tables and named styles are how the shelf's
  state-to-look tables become script: a file of them is the stylesheet, in the same language.

## The node statement

Every node, primitive or template, is one statement of one shape, and the shape is the order the
host evaluates it in:

```
<kind> <id> <placement…> control(<options>) [<style…>] { <children> } on <flag> { … }
```

Read it as: what it is, where it sits, what it does, how it looks, what is inside, what happens.
Every clause after the id is optional. The host evaluates the clauses in the order written, which
is why `control` precedes the style list: a style rule reads the control's published state, and a
child's rule finds this node as its owner.

### Kinds

| Kind | Builds | Allowed in a page |
|---|---|---|
| `box` | a container | yes |
| `leaf` | a childless box never touched again | yes |
| `spacer` | an empty fixed box, never hittable | yes |
| `root` | an independent root tree, fullscreen | yes |
| `label` | a text node never touched again | no |
| `text` | a text node read or placed afterwards | no |
| `svg`, `image` | a vector or raster leaf | no |
| a template name | that composition | yes |

`label` and `text` take the string as a second positional: `label title "BUILD"`. `svg` takes a
path and a size: `svg icon "assets/svg/forage.svg" 16`. `image` takes a reflected texture.

### Ids and keys

The id is a bare word or a string. Every pooled slot, interaction slot and focus target of the node
is addressed by the key the engine derives from the parent's key and this id, so a node's identity
is where it sits in the tree, not what frame it was built on.

A node built inside `for` must carry a key in brackets, `row[lot.id]`, and the key must be stable
across frames: a record's id for data rows, and the position only for a list that is never
re-sorted or filtered, such as a fixed set of tab labels. The host folds it into the node key the
way `El.item` folds an index, so a row keeps its selection, focus and scroll anchor through a
re-sort or a filter. A `for` body whose node has no bracket is a load error; whether the key is
stable is the author's, as it is in Zig. This is the repeated-rows rule of `CLAUDE.md`, as
grammar.

### Placement

Bare words and `key=value`, each one `Props` field, in logical pixels:

| Written | Means |
|---|---|
| `row`, `col` | flow direction |
| `wrap`, `reverse` | flow flags |
| `main=.center` | main-axis distribution: `.start .center .end .space_between .space_around .space_evenly` |
| `cross=.center` | cross-axis alignment: `.start .center .end .baseline .stretch` |
| `w=fit`, `h=fit` | size to children |
| `w=grow` | take the remainder; `grow=2` sets the weight |
| `w=fill` | the parent's content box, `pct_of_parent = 1` |
| `w=50%` | a fraction of the parent |
| `w=120` | fixed |
| `w=content` | the measured content |
| `min=(w,h)`, `max=(w,h)` | content-box bounds; `none` leaves an axis |
| `less=(w,h)` | pixels a percentage leaves out |
| `margin=(before,after)` | main-axis margins |
| `gap=6` | between flowed children |
| `shrink=1` | opt-in shrink factor |
| `overflow=.clip` | crop the subtree |
| `anchor=.center` | the node's own anchor; `.relative` is the default |
| `offset=(x,y)` | a displacement after placement |
| `opacity=0.5` | the subtree's visual opacity |
| `tracks=<set>` | this node owns a track set |
| `in=<set>` | lay this row's children out by a set |
| `at=(col,span)` | this cell's track and span; `at=(none,2)` takes the next track |
| `pass` | out of hit testing |

A track set is a value: `let set = tracks([fr(1), px(92), px(151)], gap=9)`, with `min=`,
`max=`, `shrink=` and `hidden=` on a track and `row_gap=` on the set.

Text nodes take their fit as placement words: `wrap=200`, `fill`, `cell=(.ellipsis, 120)`,
`cell_fill=.clip`, `vertical`. Exactly one, as `TextFit` allows one.

### Control

`control(…)` runs the one control lifecycle on this node and makes it the owner a style rule
reads. Its options are `control.Options` by name: `name`, `role`, `enabled`, `selected`,
`checked`, `expanded`, `value`, `roving` (a node reference, the group), `focusable`, `cursor`,
`live`, `ring`, `controls` (a list of node references). `name` and `role` are required.

A control is a template's. A `control` clause in a page is a load error.

### Style

A bracketed list, folded left to right, last non-null wins, exactly the tuple fold `style.resolve`
runs. A fragment is one of:

| Fragment | Example | Is |
|---|---|---|
| a named style | `body`, `eyebrow`, `muted`, or a file-scope `style` | a fragment list by name |
| a parametrized one | `pad(8,4)`, `pad_each(2,4,2,4)`, `ink(.dim)` | a foundation helper |
| a field | `ink=.dim`, `fill=.panel`, `outline=.line`, `outline_w=2`, `font=11`, `tracking=0.07`, `transform=.upper`, `pad=12`, `gap=8` | one `Style` field |
| a rule | `on hot ink=.acc outline=.acc` | inks that apply while the owner is in that state |
| a look-up | `tile[state]` | the arm of a `look` table |
| a verdict | `verdict=.over`, `verdict=if short then .low else none` | glyph ink by meaning, through the view's verdicts table |
| a concrete color | `fill=rgb(0x55,0x5b,0x63)` | for the few inks outside the theme |

Colors are theme roles unless written with `rgb`. A verdict is glyph ink by what the value
means, one of `met`, `unmet`, `gain`, `spent`, `better`, `worse`, `flat`, `absent`,
`inactive`, `refused`, `over`, `low` and `attention`, mapped to a role by `res.view.verdicts`
as a role is mapped to a color by the theme. `none` leaves the resting ink, so
`ink=.fg verdict=if over then .over else none` paints `fg` unless over, and an active rule's
ink replaces a verdict. The foundation's helpers that return one, `trade(after, before)` and
`margin(live, base, .higher)`, are pure and callable there.

A rule's condition is one of `hot`, `hover_focus`, `hovering`, `held`, `focused`,
`focus_visible`, `disabled`, `selected` and `checked`; the pointer conditions are false on a
disabled owner, so a disabled control never lights. Rules append in fragment order and a later
rule wins per field, as CSS source order does. The owner is this node if it has a `control`
clause, else the nearest ancestor that has one; a rule with no owner is a load error.

The names available are the foundation's `Style` constants and helpers, exported by reflection,
plus every file-scope `style` and `look`.

### Children

The braces hold the node's children, in order. Nesting is parenthood: a child never names its
parent. A template called inside the braces builds under this node.

### Handlers

`on <flag> { … }` after the block runs if the node's interaction carries that flag this frame.
The flag is any transient field of `Interaction`: `clicked`, `pressed`, `released`, `hovering`,
`held`, `dragging`, `wheel`, `dismissed`, the `scroll_*` and `nav_*` flags. Handlers run after the
children, so a child's `consume` has already run, and the flag the handler sees is the one left
after it. A handler reads the node's interaction fresh; it never acts on a copy taken earlier.

`on <flag> early { … }` runs right after the node is created, before `control`. It is for the one
case a selection must be current on the click frame, as a tab strip's active chip is: the early
handler writes the state the `control` clause then publishes as `selected`.

Inside a handler, `consume <flag>` clears the flag on this node and its stamped ancestors while
leaving hover alone, so a corner can act without its row acting too.

### Handles

After its statement, a node is `@id` for the rest of the enclosing block. A handle reads
interaction, `@row.clicked`; consumes it, `@corner.consume(.clicked)`; names a state slot,
`@surface.ScrollState`; and names a group or a related control, `roving=@strip`. A template's
result record may carry handles, reached by field: `ws.market_action.clicked`.

## Expressions

Operators, loosest first: `or`; `and`; `not`; `== != < <= > >=`; `orelse`; `+ -`; `* / %`; unary
`-`; then field access `a.b`, indexing `a[i]`, and calls `f(x, y=z)`. `if c then a else b` is
an expression, and so is `switch act { .act_one => "ALONE", .act_two, .act_three => "TOGETHER",
else => "" }`, whose arms are values. Parentheses group.

`switch` has one form, and the position decides its arms, as in Zig: as a statement every arm is
a block; in expression position every arm is a value, and a block arm there is a load error.
Several tags may share an arm. A switch over an enum covers every tag or carries `else`; over an
`int` or a `str` it carries `else`.

Types are inferred and checked at load: `num`, `int`, `bool`, `str`, an enum, a record, a list, an
optional, a handle, a state. A `num` is an `f32`, the engine's unit, so a reflected `f64` narrows
when read. An `int` widens to `num`; `int(x)` truncates. Where a type is written, in a template's
parameters and result, the names are `num`, `int`, `bool`, `str`, `handle`, `list(T)`, `?T`,
`state Kind`, and a reflected enum or record by its Zig name, `ButtonVariant` or
`roster.Resource`. Equality is by value for scalars and enums and by identity for handles. There
is no implicit truthiness: a condition is a `bool`.

An optional is unwrapped by `orelse` or by a capture: `if world.get(e, .Vigor) |vigor| { … }`.

Calls take positional arguments first, then named ones. A call into Zig, a template, a method or
an exported function, is checked against the reflected signature.

## Statements

```
let x = <expr>                 immutable, per frame
var x = <expr>                 mutable, per frame
x = <expr>                     assign a var, or a scriptable field of a state
if <cond> { … } else if … else { … }
if <optional> |v| { … } else { … }
switch <expr> { .a => { … }, .b, .c => { … }, else => { … } }   every arm a block
for item in <list> { … }        the body's node carries item's key in brackets
for item, i in <list> { … }     i is the position; a key only for a static list
return { … }                   a template's result
roots <expr>, …                a page's roots, in draw order; in an `orelse` block it ends the page early
emit <fn>(<args>)              a deferred call into a mutating export
```

There is no loop over frames, no recursion, no closure, no allocation the author sees. Strings
built by interpolation live in the frame arena and die with it, which is fine because a text node
copies what it is given, as it does for Zig.

## Reading the game: `res` and `world`

`res` is the host's `Resources`, and `world` the ECS world, exposed through descriptors the host
generates from their Zig types at compile time. A descriptor walks a type and records every field
it can represent:

| Zig | Script |
|---|---|
| `f32`, `f64` | `num`; an `f64` narrows |
| integers | `int` |
| `bool` | `bool` |
| `[]const u8`, bounded text with a `slice()` | `str` |
| `enum` | enum, with `.tag` literals and the enum's public methods |
| `struct` | record, with its public methods |
| slice, array, bounded list with `slice()` | list |
| `?T` | optional |
| `union(enum)` | a record with `.tag` and the active field |

A field it cannot represent is hidden, not refused: anything behind a pointer, an SDL handle, a
function pointer, an allocator. So `res.platform` and `res.environ` do not exist to the script
and nothing has to say so. A public method is callable when every parameter is representable; a
method taking the world or the resources has them supplied.

The world is read through three forms, generated over the component namespace `World`
already enumerates at compile time:

```
world.with(.Player)                a list of entities carrying the tag or component
world.first(.Player)               the first such entity, or none
world.get(e, .Vigor)               the component record, or none
world.has(e, .Dead)                a bool
```

A component record is read like any record. Writes go through `emit`.

## Calling the library: exports

Derived facts the game computes, a ledger balance, a catalog filter, a quote, are Zig functions.
Zig cannot tell a script which are safe, so one declaration in the game lists them, once,
library-wide:

```zig
// src/script_api.zig
pub const pure = .{ ledger.balance, roster.Resource.wordIn, market.sell_quote, query.filter, … };
pub const mutating = .{ barter.resolve, capital.begin, capital.cancel_build, capital.collect_generator, actions.begin, … };
```

The host reflects each signature into a thunk. In the script they are reached as
`ha.<module>.<fn>`, with any `*World` or `*Resources` parameter supplied, so a call reads
`ha.ledger.balance(e, .food)`. A pure export is an expression. A mutating export is legal only
behind `emit`; calling one inline is a load error.

The export lists are the one binding step the language has, and they are per library, not per
page. The same lists serve every page and, later, every script template.

## Mutation: `emit`

```
emit ha.barter.resolve(e, quote, lots)
```

`emit` marshals the arguments now, into the frame arena, and queues the call. The queue runs once
the page has finished evaluating, in emit order, before layout. So nothing a script does changes
the world while the tree is being built, and the effect of an emit shows on the next frame's
build. That is one frame of latency, the same the engine already accepts for hit testing, and it
keeps the page from being evaluated twice on an event frame, which would register every focus
target and semantic node twice.

A mutating export that returns an error has its error logged against the emit's source line; the
page is not refused.

## State

The pooled state kinds are `UiState`'s declarations, exported by name: `ScrollState`,
`TabsState`, `DisclosureState`, `CatalogState`, `TradeState`, `SliderState`, `RailState`, and the
rest. A kind is visible only if it declares which fields a script may touch:

```zig
pub const TabsState = struct {
    active: usize = 0,
    pub const scripted = [_][]const u8{"active"};
};
```

The declaration is the same shape `Interaction.transient` uses. A kind with no `scripted` list
is private: the text, svg and geometry states, which own textures and meshes, never appear.

A node owns a state by declaring it as a clause, `state ScrollState`, and the slot lives while the
node is built, pruned with it, as a Zig node's `state(T)` slot is. Another node reaches it as
`@id.ScrollState`. A template parameter typed `state ScrollState` accepts either a reference or
nothing, in which case the template declares the slot on its own node; that is the Zig shelf's
optional-pointer convention, with the owner named instead of pointed to.

Reading a state field is an expression; writing one is an assignment, legal only on `scripted`
fields. Every access resolves the owner key and the kind through the pool at that moment, so the
script never holds a slot address and the pool is free to move.

A view that is only sometimes built keeps its state on a node that is always built and passes it
down, exactly as [`../src/ui_client/README.md`](../src/ui_client/README.md) *Who owns a
template's state* describes.

## Templates

```
template button(label: str, enabled: bool = true, variant: ButtonVariant = .primary) -> { el: handle } {
    box self row w=fit h=fit
        control(name=label, role=.button, enabled=enabled, ring=false)
        [button_chrome[variant], on hot outline=.acc, on disabled outline=.dim]
    {
        label lbl label [body, pad(8,4), button_ink[variant], on hot ink=.acc, on disabled ink=.dim]
    }
    return { el: @self }
}

look button_chrome(ButtonVariant) {
    .primary => [outline=.fg],
    .secondary, .back => [outline=.line2],
    .danger => [outline=.danger],
}
```

- The node written as `self` is the template's own node: it takes the id from the call's id
  position, and `@self` refers to it once built. A template builds exactly one `self`.
- Parameters are typed, may default, and may be `state <Kind>` or `handle`.
- The template's parent is the node whose block the call sits in. A template that builds a
  `root` has no parent and can only be called at a page's top level.
- `return` gives the result record. Its fields are read by the caller by name. A template with no
  `return` returns its node as `el`.

A script template calls Zig templates and other script templates alike. A Zig template is
callable when its parameters reflect: a leading `El` parent is supplied, a leading `*UiCtx`
marks it root-level, an options struct takes named arguments, and a result struct is a record. The
value a reflected field hands over is already the Zig type a Zig template takes, so
`trade_dialog trade book=view.book` passes the book through untouched.

The other direction is one host function. A Zig page or template calls a script template by name
and id, with the arguments as an anonymous struct whose field names are the template's parameters
and the result record's shape as a struct type:

```zig
const buy = try script.call(parent, "button", "buy",
    .{ .label = "BUY", .enabled = can_buy },
    struct { el: El, clicked: bool });
```

The arguments are reflected into script values by the table that reflects `res`; a `state Kind`
parameter takes the owner's `El`, or is left out so the template owns the slot; a template that
builds a `root` takes the `*UiCtx` in the parent's place. The result is marshalled into the named
struct field by field. A template that does not exist, an argument that does not fit, or a result
field that is missing is an error returned at the call, handled as any template error is. The
template evaluates at once, inside the caller's build and under the parent's key, so its nodes,
state and interaction are the ones a script page would give it, and it reloads while the Zig page
that calls it keeps running.

A tab strip, ported from `pages/templates/tabs.zig`:

```
template tabs(labels: list(str), active: state TabsState, name: str = "tabs") -> { active: int } {
    box self row gap=10 {
        for label, i in labels {
            box tab[i]
                control(name=label, role=.radio, selected=active.active == i, roving=@self)
                [on selected outline=.fg, on hover_focus outline=.acc]
            {
                label l label [body, pad(6,2), ink=.dim, on selected ink=.fg, on hover_focus ink=.acc]
            }
            on clicked early { active.active = i }
        }
    }
    return { active: active.active }
}
```

Here `i` keys the chip because a label is not a stable value; a shelf row would key by its
record's id.

## Pages

```
page act_one {
    let e = world.first(.Player) orelse { roots none }
    let act = ha.migration.actOf(e)
    let vigor = world.get(e, .Vigor) orelse { roots none }
    let food = world.get(e, .InventoryFood) orelse { roots none }

    let page = act_page play act=.act_one
    let ws = act_one_workspace page.regions.body e=e
        holdings=ha.act_one.holdings(e)
        market_available=res.sim.encounter.dealable()

    let ts = ws.market_action.TradeState
    if ws.market_action.consume(.clicked) and res.sim.encounter.dealable() { ts.open = true }

    var overlay = none
    if ts.open {
        let dialog = trade_dialog trade kind=.passerby
            meta="{res.sim.encounter.remaining / res.config.secs_per_day:.1} DAYS LEFT"
            book=ha.market.passerby_book(e) state=ts
        if dialog.settle |s| { emit ha.barter.resolve(e, s.quote, s.lots) }
        if dialog.dismissed or not res.sim.encounter.dealable() { ts.open = false }
        if ts.open { overlay = dialog.root }
    }

    roots page.finish(stocks=[vigor_stock("VI", vigor), stock(.food, food.v, act)], act_label="Act I", overlay=overlay)
}
```

The `ha.act_one.holdings`, `ha.market.passerby_book`, `vigor_stock` and `stock` calls are the
page's current inline builders as they would read once exported or shelved; they illustrate the
shape, not an existing API.

A page reads, composes, reads interaction off what the shelf returns, and emits. It cannot style,
place text or make a control, by grammar. `roots` is its last statement.

The host decides which page runs: `pages/root.zig` keeps its routing and calls a script page by
name where it called a Zig page before, so Zig and script pages coexist during the migration and
the fixture harness seeds either.

## Evaluation

### One node

The clauses of a node statement evaluate in the order written, which is the order the element API
needs:

```
1  create + attach         the key is final: hash(parent.key, id [, bracket key])
2  content                 a text node measures at its fit; svg and image attach
3  early handlers          read the node's interaction, write state
4  placement               Props onto Layout/Size
5  control                 the lifecycle; the node becomes a rule owner
6  style                   the fragment fold; rules read this node's or an ancestor's control
7  children                each child runs 1–8
8  handlers                read the node's interaction after the children consumed
```

This is the ordering the Zig README documents as convention, with each rule made structural:
keyed data after the key, control before any lifted child, children before the parent acts,
declaration order as precedence. The one Zig rule with no equivalent is the state pointer's
validity, which does not exist here because the script never holds one.

### One frame

The script runs inside `frame.Driver.step`, in the build slot:

```
route · beginFrame · registries open · arena reset
build:   evaluate the routed page, script or Zig  →  roots, emit queue
         run the emit queue
layout · stamp · draw · present · endFrame · registries publish
```

The emit queue runs after evaluation and before layout, so every mutation lands before the
simulation's next tick and the next build reads it. It runs whoever queued it: a script page, or a
script template a Zig page called.

### What each construct becomes

| Script | Host call |
|---|---|
| `box id …` | `El.box(id, props, spec)`; `boxi` under a bracket key |
| `leaf`, `spacer`, `label`, `text`, `svg`, `image`, `root` | the element of that name |
| placement words | fields of `Props` |
| `[…]` | a runtime fragment slice folded by `style.resolve` |
| `control(…)` | `El.control(Options)` |
| `on flag { }` | `node.query()` after the children, then the block |
| `consume flag` | `El.consume(flag)` |
| `state Kind`, `@id.Kind` | `ctx.cache(key, Kind)` through the reflection table |
| `for item in list { x[item.id] … }` | `El.item`/`boxi` keyed by the item's value |
| a template name | the Zig template through its reflected signature, or the script template |
| `res`, `world` | the descriptor over `Resources` and `World` |
| `ha.m.f(…)` | the export's thunk |
| `emit …` | marshal into the arena, queue, run after build |
| `roots …` | the page's `Trees` |

The engine is untouched by any of this. The evaluator, the descriptors, the export thunks and the
error root live in the host binding, `src/ui_client/script/`, because they bind the element API
and the state kinds, which are the host's.

## Errors

A script is refused rather than guessed at, in the spirit of the editor's and the text cache's
whole-refusal rule.

**At load**, the parser and the checker refuse a file for: a syntax error; an unknown name, field,
state kind, flag, role, condition or placement word; a type mismatch against a reflected
signature; a `for` body node without a bracket key; a page that styles, places text or makes a
control; a mutating export called inline; a style rule with no owner; a `switch` that misses a tag
or has a block arm where a value is needed; a duplicate declaration; a collision with a Zig
export. The message carries the file, line and column. The previous script
stays on screen, the console gets the full message, and the event log gets one line, as a data
reload does.

**At run**, a page's evaluation is aborted for the frame by: an index out of range; a `none`
unwrapped by a capture-less access; an `int()` of a non-finite number; an emit whose arguments
fail to marshal. The page's roots are replaced by one error root naming the file, line and
message, the console gets the message once per distinct error, and the next frame tries again.
State in the pools is untouched, so fixing the script resumes where the screen was.

A Zig template that returns an error, or a mutating export that does, is logged against the
script line that called it; the frame is not aborted. A script template called from Zig that
fails at run returns the error to its caller instead of painting the error root; the console gets
the message once.

## The tier rule, as grammar

| In a `page` | In a `template` |
|---|---|
| `box`, `leaf`, `spacer`, `root`, template calls | everything |
| placement words | placement words |
| handles, `consume`, `on` handlers, `emit`, `roots` | the same, plus `return` |
| no `[…]`, no `label`/`text`/`svg`/`image`, no `control` | |

This is "pages lay out; templates paint" from `CLAUDE.md`, enforced where the sentence is parsed
instead of by `tools/boundary_check.sh`'s spellings. The shelf's other hard rules fall out of the
grammar too: an id cannot be formatted per iteration because a loop node keys by a bracketed
value, and no construct reaches the lifecycle calls a control runs.

## Open

- The language's name.
