# SCAFFOLD_TODO_ModName

> SCAFFOLD_TODO: Short description of what this mod does.

Part of the [SCAFFOLD_TODO_PackTitle modpack](SCAFFOLD_TODO_ShellUrl).

## What It Does

SCAFFOLD_TODO: Explain what this module lets players control.

## Gameplay Impact

SCAFFOLD_TODO: Explain how this module changes a run when enabled.

## How To Use

Install using r2modman. In game, open the SCAFFOLD_TODO_PackTitle menu and configure this module from the shared settings window.

## Development

This template targets the current adamant ModpackLib module contract:

- `main.lua` owns module creation, capability declaration, fallback UI attachment, and activation
- module pieces are imported from `init()` after `modutil.once_loaded.game(...)`
- data objects are returned directly from `mods/data.lua`
- logic/UI modules receive dependencies through explicit `.bind(...)` or `.create(...)` calls
- modules are constructed with `lib.createModule({ ... })`
- `module.activate()` publishes the live host and runs hooks/lifecycle side effects
- custom storage should be returned by `data.buildStorage()`; modules with no custom settings may omit storage
- storage defaults live in `module.data.define(...)`; Lib owns module persistence
- optional draw actions are declared with `module.actions.define(...)` and staged from widgets through `ui.actions.get(...)`
- fallback module UI uses `module.fallbackUi.attachGuiOnce(...)`
- module UI is written as callbacks that receive `(host, ui)` and use `ui.draw`, `ui.data`, and `ui.actions`
- mutation lifecycle is declared before activation with `module.mutation.patch(...)`
- runtime hooks should be declared on `module.hooks` inside `logic.registerHooks(module)`
- hosted modules should use `module.hooks.wrap(...)`, `module.hooks.override(...)`, or `module.hooks.contextWrap(...)`
- module logic that runs outside the draw path should use the `host, runtime` passed to hooks, actions, mutation callbacks, overlays, and commit callbacks

Template files:

- `src/main.lua` for the module entrypoint
- `src/mods/data.lua` for storage, static option lists, and lookup data
- `src/mods/logic.lua` for patch plans, hooks, and runtime game modifications
- `src/mods/ui.lua` for `drawTab` and optional `drawQuickContent`

Scaling rule:

- keep `main.lua`, `mods/data.lua`, `mods/ui.lua`, and `mods/logic.lua` as the top-level contract
- let `mods/ui.lua` import `mods/ui/*.lua` section files when UI grows
- let `mods/logic.lua` import `mods/logic/*.lua` or `mods/behaviors/*.lua` files when game logic grows
- keep storage schema and static data in `mods/data.lua`
- keep module construction and fallback UI attachment in `main.lua`

Canonical docs:

- [ModpackLib GETTING_STARTED.md](https://github.com/h2-modpack/adamant-ModpackLib/blob/main/docs/module-authors/GETTING_STARTED.md)
- [ModpackLib MODULE_AUTHORING.md](https://github.com/h2-modpack/adamant-ModpackLib/blob/main/docs/module-authors/MODULE_AUTHORING.md)
- [ModpackLib HOT_RELOAD_ARCHITECTURE.md](https://github.com/h2-modpack/adamant-ModpackLib/blob/main/docs/lib-contributors/HOT_RELOAD_ARCHITECTURE.md)
- [ModpackLib KNOWN_LIMITATIONS.md](https://github.com/h2-modpack/adamant-ModpackLib/blob/main/docs/references/KNOWN_LIMITATIONS.md)

Module contract notes:

- `lib.createModule(...)` requires the module plugin guid through `pluginGuid`
- `lib.createModule(...)` and `module.activate()` let invalid modules log and skip without taking down sibling modules
- coordinated modules should declare `modpack`, `id`, and `name`; Lib injects `Enabled` and `DebugMode`
- Lib modpack renders one tab per coordinated module

## Local Setup

Prefer creating modules through the shell repo:

```bash
ModpackTools/run ModpackTools/new_module/create.py --package-id SCAFFOLD_TODO_ModName --title "SCAFFOLD_TODO Module Name"
```

For local deploys, run the shell repo deploy entrypoint:

```bash
ModpackTools/run ModpackTools/local_deploy/deploy_all.py --overwrite
```
