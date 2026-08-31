# Plan Executor

Plan Executor is the thin Hades II consumer of the standalone Run Planner's
execution-only JSON. It does not plan, simulate, or reinterpret a project.

The module reads the fixed `active.runplanner.json` slot under the
ReturnOfModding configuration, strictly decodes the bounded v4 Underworld F or
F/G execution contract, and freezes it only when a new run starts. It realizes
occurrence-marked rooms, ordered door peers, fixed links, rewards, room-object
inventories, and compiled acquisition outcomes only at their normal vanilla
seams. It observes the ordered trace, player interactions, selected exits and
acquisitions, and the complete published Run State checkpoint surface. The
first mismatch records field-level evidence and blocks the remaining plan
suffix; it never searches, selects a fallback, or repairs the run.

The checked-in execution fixtures mirror RunPlanner-main's compiler fixtures
byte for byte.

Use the desktop Run Planner's **Publish to Game** action. The browser build
cannot publish directly. The archived `archive/phase9-prototype/` directory is
historical evidence from the earlier bundle prototype and is not imported or
executed by the active module.
