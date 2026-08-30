# Plan Executor

Plan Executor is the thin Hades II consumer of the standalone Run Planner's
execution-only JSON. It does not plan, simulate, or reinterpret a project.

Gate A reads the fixed `active.runplanner.json` slot under the module's
ReturnOfModding configuration, validates the bounded v1 Underworld/F opening
contract, and freezes that plan only when a new run starts. It realizes the
compiled F opening room and reward through the narrow vanilla contacts and
observes room entry. The first mismatch is retained as a diagnostic and blocks
the remaining session; it never searches for a fallback instruction.

Use the desktop Run Planner's **Publish to Game** action. The browser build
cannot publish directly. The archived `archive/phase9-prototype/` directory is
historical evidence from the earlier bundle prototype and is not imported or
executed by the active module.
