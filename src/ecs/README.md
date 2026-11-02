# ECS Engine

A small **sparse-set entity-component-system** in Zig. The ergonomics are modelled on
[Bevy](https://bevyengine.org): system params, `Query` with `With`/`Without`/`Maybe` filters,
`Single`, and bundle spawning. The storage is comptime Zig rather than archetypes.

## Extraction boundary

`src/ecs/` is a package of its own (`build.zig.zon`, module `ecs`). It imports nothing but
`std` and its own files, and knows no component, no resource and no game: the host supplies
the component and tag namespaces and the resources struct, and the engine is generic over
them. `tools/boundary_check.sh` (tier 3) holds it to that. A host adds the module with
`b.dependency("ecs", …).module("ecs")` and imports it as `@import("ecs")`;
`zig build test` in this folder runs the engine's own tests.

## World

```zig
World(comptime comps: type, comptime tags: type) type
  .init(allocator: std.mem.Allocator) error{OutOfMemory}!World    .deinit()
Entity = u32
MAX_ENTITIES: u32 = 1024
SparseSet(comptime T: type) type
```

`World(comps, tags)` generates one `SparseSet` per public declaration of `comps` and of `tags`.
Every public declaration there must be a type; anything else is a compile error naming it. The
two namespaces differ only in intent: a tag is a zero-sized marker.

The storages live on the heap: `init` allocates the two structs that hold them, one for the
components and one for the tags, and `deinit` frees both. A `SparseSet` holds its arrays inline
for `MAX_ENTITIES`, so a world's footprint is fixed at `init` and `spawn` and `add` cannot fail.
A `World` value is a handle onto its storages, so a copy of it shares them: a world is
initialized once, passed by pointer, and `deinit`ed once. Because the world reaches its
storages through a pointer, a `*const World` does not make them const by itself: every accessor
that takes the world as `anytype` names its return type through `Ref`, and that is what yields
`*const` through `*const World`.

| Method | Does |
|---|---|
| `init(allocator) !World` / `deinit(*World)` | an empty world, its storages allocated / freed |
| `spawn(*World, bundle) Entity` | a tuple of component *instances* and bare *tag types* |
| `add(*World, e, value)` | the value's storage |
| `get(self: anytype, e, T)` | `?*T` through `*World`, `?*const T` through `*const World` |
| `has(self: anytype, e, T) bool` | through either pointer |
| `storageOf(self: anytype, T)` | `*SparseSet(T)` or `*const SparseSet(T)`, by the same rule |
| `remove(*World, e, T)` / `despawn(*World, e)` | one storage / every storage |

Ids are never recycled: `next_id` only climbs, so `MAX_ENTITIES` is a lifetime-spawn cap, not
a live one. Removal is a swap-remove, so a storage's dense order is not spawn order.

## Queries

```zig
Query(comptime WorldPtr: type, comptime params: anytype) type        // .iter(), .Item
Single(comptime WorldPtr: type, comptime params: anytype) type       // .get() → Entry
MaybeSingle(comptime WorldPtr: type, comptime params: anytype) type  // .get() → ?Entry
getMany(world: anytype, e: Entity, comptime params: anytype) Entry(@TypeOf(world), params)
With(T)  Without(T)  Maybe(T)
```

`params` is a tuple of types:

| Item | Meaning |
|---|---|
| a component or tag type | a *fetch*: required, yields a pointer; the first one drives iteration |
| `With(T)` / `Without(T)` | must / must not have `T`; fetches nothing |
| `Maybe(T)` | yields an optional pointer; neither filters nor drives |
| `Entity` | yields the id; does not drive |

An entry is the one item alone when `params` yields one, otherwise a tuple in declaration
order. `Single` panics on no match or several; `MaybeSingle` returns null on none and panics
on several. `getMany` fetches off a known entity: a missing required component panics, and
`With`/`Without` are a compile error there, since there is no set to filter.

**The const rule.** The world pointer type decides what an entry holds: through `*World` a
fetch is `*T` and a `Maybe` is `?*T`; through `*const World` they are `*const T` and
`?*const T`. A write through a const entry is a compile error, so code that holds only a
`*const World` cannot mutate a component. A negative compile test is not possible in Zig; the
signature that takes `*const World` is the proof.

**Annotate a multi-fetch destructure.** An entry tuple is `@Tuple`-constructed, which no
language server evaluates, so `const a, const b = entry;` leaves an editor with nothing to
offer. Writing the types (`const a: *A, const b: *B = entry;`) restores it.

## Events

```zig
Events(comptime ns: type, comptime ReaderId: type) type   // .capacity == 64
  .update()                                               // once, at the top of each tick
  .writer(T) Writer(T)            Writer(T).push(ev) bool
  .reader(T, id) Reader(T, id)    Reader(T, id).next() ?T
  .readerAt(T, *u64) ExternalReader(T)    .next() ?T
  .len(T) usize   .dropped(T) u32
```

`Events(ns, ReaderId)` generates one bounded ring per public struct of `ns`, the way
`World` generates its storages. Every public struct there is an event and must be plain
fixed-size data: a slice or a pointer anywhere inside an event type is a compile error naming it,
so an event owns everything it says. A public type that is not a struct, such as an enum the
events share, is not an event. `ReaderId` is an enum naming every scheduled reader.

**Nothing is silently lost.** Each push takes the store's next monotonic id. A ring holds
`capacity` events; a push into a full ring is refused, returns false and counts in `dropped(T)`.

**The lifetime rule: two ticks.** `update()` expires every event written before the previous
tick began. An event written during tick N, or between N and N+1 where a UI writes, is readable
through tick N+1 and gone at the top of N+2, wherever its writer and its reader sit in the tick.

**The cursor rule.** A reader yields the live events past its cursor in id order and advances
the cursor past each one it yields, so a reader that stops early resumes where it stopped and a
reader that runs every tick sees each event exactly once. `Reader(T, id)` keeps its cursor in
the store, one per event type per `ReaderId`, so one id may read several types. A reader outside
the schedule keeps its own `u64` and reads through `readerAt(T, &cursor)`; a cursor older than
everything live starts at the oldest live event.

## Systems and `run`

```zig
run(world: anytype, res: anytype, comptime sys: anytype) void
```

`run` reads `sys`'s parameter types at comptime, builds each one, and calls it. `world` is a
pointer to a `World`, `res` a pointer to any struct of resources. A parameter may be:

| Param | Bound to |
|---|---|
| `world`'s pointer type, or its `*const` form | the world |
| `*R` / `*const R` | the whole resources struct `R` |
| `*T` / `*const T`, `T` a struct-typed field of `R` | that field: a **resource group** |
| `Query`, `Single`, `MaybeSingle` | built over the world |
| `Events(…).Writer(T)`, `Events(…).Reader(T, id)` | the one group of `R` whose type is that `Events` store |

The groups are derived from `R`'s fields, so a new one is injectable with no edit to the
engine. Two guards keep the type-directed binding honest: only struct-typed fields inject (a
bare `f32` on `R` would make `*f32` bind to it), and two fields sharing a type is a build
error rather than a silent bind to the first. An event param whose store is not a field of `R`
is a compile error naming the store. Any other parameter is a compile error that lists what is
valid.

Naming a group instead of taking the whole `*R` puts a system's reach in its signature, and
`*const` against `*` says whether it reads or writes. Structural changes (`spawn`, `add`,
`remove`, `despawn`) go through the world pointer; mutating a storage while iterating it is
unsafe, so a system collects ids first and applies after.

## States and the schedule

```zig
States(comptime S: type) type          // { current: S = <S's first tag>, next: ?S = null }
  .in(s) bool    .set(s)
Schedule(comptime S: type, comptime sets: anytype) type
  .tick(world, res, states: *States(S), run_update: bool)
  .setOf(comptime s, comptime kind) tuple    .indexOf(comptime s, comptime kind, comptime sys) ?usize
  .sets                                      // the table as declared
SetKind = enum { on_enter, handle, update, on_exit }
sameSystem(comptime a, comptime b) bool
```

`States(S)` is plain data, so it sits as a field of the resources struct and a system takes it
as a resource group: `*const States(S)` to read with `in`, `*States(S)` to request a transition
with `set`. A request waits in `next`; a later request in the same tick replaces it.

`Schedule(S, sets)` is the systems, declared once, per state. `sets` is a struct literal with one
field per state that runs anything, each a struct literal of sets, each a tuple of system
functions (they differ in signature, so not a slice):

```zig
const schedule = Schedule(Phase, .{
    .idle = .{ .handle = .{ start } },
    .play = .{ .on_enter = .{ setup }, .handle = .{ input }, .update = .{ move, collide }, .on_exit = .{ teardown } },
});
```

| Set | Runs |
|---|---|
| `on_exit` | once, when a transition leaves the state |
| `on_enter` | once, when a transition enters it |
| `handle` | every tick the state is current |
| `update` | every tick the state is current and `run_update` is true |

`tick` does, in order: apply the pending transition, if any (clear `next`, run the current
state's `on_exit`, make `next` current, run its `on_enter`); run the current state's `handle`
set; if `run_update`, run its `update` set. Each set runs in declared order through `run`, so a
system there binds its params as anywhere else. A request for the state already current is a
restart and runs both sets the same way. A transition requested during a tick is applied at the
top of the next, so every system of one tick sees one state, and one requested from an
`on_enter` set waits a tick like any other.

A state the table does not name has empty sets. A table field that is not a tag of `S`, a set
named anything but the four, or a set that is not a tuple of functions is a compile error naming
it. `setOf` and `indexOf` read the table at comptime, so a test can assert the order a set
declares; `sameSystem` compares two system functions.
