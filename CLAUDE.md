# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## Build

```bash
zig build run     # build and run
zig build test    # unit tests (whole library)
zig build test-ui # just the UI layer (engine + host binding, no game content)
zig build         # build only
```

`test-ui` compiles `src/ui/` + `src/ui_client/` in isolation — a faster loop that skips
`main.zig`, `systems.zig` and `src/pages/`. All three targets are expected green; if one is
not, say so rather than working around it.

Requires Zig 0.15.2+. SDL3 and SDL3_TTF are fetched via `build.zig.zon`.

## What this is

**Human Action** is a Zig/SDL3 **agent-based praxeology simulation** — emergent economic
behavior from a population of purposeful agents acting under scarcity, named after Ludwig von
Mises. Its shape is an incremental/accumulator game: start alone, cold and starving; end with
a city.

It runs on two things built here rather than imported: an immediate-mode UI layout engine, and
a Bevy-style sparse-set ECS. Those two are the project — the scope rule is **UI and AI,
nothing else**.

Today it plays the first slice: a lone actor under scarcity, no exchange, no money.

## Where the knowledge lives

Read the one that covers what you are about to touch. Each describes what exists, not how it
got there — git holds the history.

| Question | Document |
|---|---|
| What is the sim? ECS, components, systems, actions, capital, the frame loop | [`src/README.md`](src/README.md) |
| How does the UI engine work? nodes, the key-cache, interaction, layout | [`src/ui/README.md`](src/ui/README.md) |
| How do I build a screen? elements, `El`, the style fold, paint features, the theme | [`src/ui_client/README.md`](src/ui_client/README.md) |
| What is the game *for*? the vision, the acts, the locked decisions | [`docs/design.md`](docs/design.md) |
| What is next, what is broken, what is deliberately not built? | [`docs/roadmap.md`](docs/roadmap.md) |

## Layers

Each may only reach downward.

```
src/pages/          screens + the template shelf     game content
src/ui_client/      host binding: elements, style, features, the render walk
src/ui/             the UI engine — imports nothing from the game
```

`src/ui/` is meant to be extractable into its own project. Nothing in it may name the game,
the theme's values, or `Resources`' contents. `src/ui_client/` binds it to this program;
`src/pages/` is the only tier that knows what a vigor bar is.

The sim (`world.zig`, `ecs.zig`, `systems.zig`, `actions.zig`, `capital.zig`) sits beside all
of this and knows nothing about the UI.

## Conventions

**One document holds the future.** [`docs/roadmap.md`](docs/roadmap.md) is the only place
that discusses what isn't built — gaps, limitations, intentions, arguments about future
features. Every other document, and every code comment, describes what *is*. A `TODO` in the
code is a roadmap entry that escaped; put the content in the roadmap and leave at most a
pointer where it matters.

**Writing docs and comments.** Describe what a thing *is*, in the present tense. A date inside
a description is a smell — it means the sentence is about a change rather than about the
thing, and git already records that. History earns its place in exactly two shapes: a live
constraint whose reason is not visible from the code (write it as rule + because-clause, no
date), and a road already tried and rejected that someone would otherwise re-propose (one
line). A fact lives in exactly one document; the others link to it.

**Commits.** Split a batch into logical commits, staging straddling files at intermediate
states so every snapshot compiles. Never commit a tree that does not build. Commit on the
current branch — do not create a branch unless asked.

**Keeping docs in sync.** A change to the UI layer updates the matching README in the same
pass, not later.

**Components and tags.** `components.zig` and `tags.zig` may contain *only*
`pub const <Name> = struct {…}` type declarations — `World` enumerates them at comptime, and a
stray public decl generates a storage for it. A shared shape that is not a component belongs
in a non-public decl.

**Verifying UI changes.** There is no synthetic-input path into SDL. Confirm visual work with
a screenshot (PrintWindow) and, where a state is hard to reach, a temporarily flipped flag —
see the `project_dev_workflow` memory.
