# Run Planner Plan Executor

Plan Executor is the Hades II mod that carries out plans created by
[Run Planner](https://github.com/maybe-adamant/RunPlanner).

Run Planner owns authoring, simulation, and validation. Its desktop app
publishes a game-ready execution plan to one of six fixed slots; Plan Executor
loads the selected active slot when a new run begins and steers the
corresponding rooms, rewards, offers, and other modeled outcomes in Hades II.
If the game and plan diverge, the executor records the discrepancy and stops
steering the remaining plan without blocking normal gameplay.

## How it connects to Run Planner

1. Create and validate a run in the Run Planner desktop app.
2. Use **Publish to Game** to choose a compatible game profile and one of the
   six plan slots.
3. In Plan Executor's in-game settings, choose that slot as the active plan.
4. Start a new Hades II run. Plan Executor loads the selected slot at run
   startup. Changing the active slot later does not change that live session.

The browser version of Run Planner cannot publish directly to the game. Plan
Executor consumes the published execution plan only; it does not read or
reinterpret an editable Run Planner project.

## Repository layout

- `src/` — the active Hades II module.
- `fixtures/` — execution plans shared with Run Planner for compatibility
  testing.
- `tests/` — Lua unit and integration tests.

Within `src/mods/`, code is grouped by its runtime responsibility: host and
protocol integration, route navigation, room behavior, timeline interactions,
and modeled traits or keepsakes.

## Development

Run the Lua test suite from the repository root:

```sh
lua tests/all.lua
```

Check the active module with Luacheck:

```sh
luacheck src/
```
