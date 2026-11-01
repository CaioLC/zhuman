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
Entity = u32
MAX_ENTITIES: u32 = 1024
SparseSet(comptime T: type) type
```

`World(comps, tags)` generates one `SparseSet` per public declaration of `comps` and of `tags`.
Every public declaration there must be a type; anything else is a compile error naming it. The
two namespaces differ only in intent: a tag is a zero-sized marker.

| Method | Does |
|---|---|
| `init() World` / `deinit(*World)` | an empty world; nothing to free |
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

The groups are derived from `R`'s fields, so a new one is injectable with no edit to the
engine. Two guards keep the type-directed binding honest: only struct-typed fields inject (a
bare `f32` on `R` would make `*f32` bind to it), and two fields sharing a type is a build
error rather than a silent bind to the first. Any other parameter is a compile error that
lists what is valid.

Naming a group instead of taking the whole `*R` puts a system's reach in its signature, and
`*const` against `*` says whether it reads or writes. Structural changes (`spawn`, `add`,
`remove`, `despawn`) go through the world pointer; mutating a storage while iterating it is
unsafe, so a system collects ids first and applies after.
