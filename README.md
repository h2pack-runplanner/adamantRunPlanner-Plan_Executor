# Plan Executor

Plan Executor is the thin Hades II consumer for resolved execution bundles
exported by the standalone Run Planner application. It does not plan routes,
simulate rooms, or reinterpret the authored project.

## What It Does

The module reads only `active.runplanner.json` in its own ReturnOfModding
configuration directory, within a 1,048,576-byte binary limit, and validates
the versioned execution protocol. The fixed filename is
`active.runplanner.json`; **Inspect Published Plan (Future Run)** is an
explicit diagnostic action. A loaded project-only bundle is reported as having
no executable plan.

At each new run, the module freezes one decoded route in a ModpackLib
current-run cache, verifies referenced live identifiers, and applies exact
compiled starting rooms, physical normal-door targets, and generated reward
types and Boon/Devotion sources through narrow vanilla contacts. Disabled,
dream, unknown, unavailable, and unconfigured routes remain vanilla/inactive.
A contact failure is recorded once and never triggers a fallback. Encounter
selection, Shop and wheel inventories, local-room topology, and detours remain
later Phase 9 slices.

## How To Use

Use **Publish to Game** in the standalone Run Planner application. It writes
the resolved bundle to this module's fixed `active.runplanner.json` slot. Open
the Run Planner menu and press **Inspect Published Plan (Future Run)** to
inspect its status. A newly read plan applies to a later run; this slice does
not watch files or reload an active run. On a module hot reload, the transient
file-inspection state truthfully starts as not inspected while the frozen
current-run session is re-published from its cache. It does not claim anything
about current file contents until inspected. Replacing the slot after the run
starts cannot alter its frozen program.

## More Information

- [Run Planner modpack](https://github.com/h2pack-runplanner/run-planner-modpack)
- [Run Planner integration boundary](https://github.com/h2pack-runplanner/RunPlanner/blob/main/docs/design/GAME_INTEGRATION_BOUNDARY.md)
