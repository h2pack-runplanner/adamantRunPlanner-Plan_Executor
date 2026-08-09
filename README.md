# Plan Executor

Plan Executor is the thin Hades II consumer for resolved execution bundles
exported by the standalone Run Planner application. It does not plan routes,
simulate rooms, or reinterpret the authored project.

## What It Does

The module reads only `active.runplanner.json` in its own ReturnOfModding
configuration directory, within a 1,048,576-byte binary limit, and validates
the versioned execution protocol. **Read Published Plan** is an explicit
diagnostic action. A loaded project-only bundle is reported as having no
executable plan.

The module trusts resolved execution instructions. Runtime adapters added in
later Phase 9 slices will consume the frozen plan and report loss of contact
instead of inventing a fallback route.

## How To Use

Use **Publish to Game** in the standalone Run Planner application. It writes
the resolved bundle to this module's fixed `active.runplanner.json` slot. Open
the Run Planner menu and press **Read Published Plan** to inspect its status.
A newly read plan applies to a later run; this slice does not watch files or
reload an active run.

## More Information

- [Run Planner modpack](https://github.com/h2pack-runplanner/run-planner-modpack)
- [Run Planner integration boundary](https://github.com/h2pack-runplanner/RunPlanner/blob/main/docs/design/GAME_INTEGRATION_BOUNDARY.md)
