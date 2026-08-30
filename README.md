# Plan Executor

Plan Executor is the thin Hades II consumer of the standalone Run Planner's
execution-only JSON. It does not plan, simulate, or reinterpret a project.

Gate C reads the fixed `active.runplanner.json` slot under the module's
ReturnOfModding configuration, strictly decodes the bounded v3 Underworld F or
F/G execution contract, and freezes it only when a new run starts. It realizes
occurrence-marked rooms, ordered door peers, fixed links, reward sources, and
the published trait/automatic-outcome contacts only at their normal vanilla
seams. It observes the ordered trace, selected exits and acquisitions, and the
complete published Run State checkpoint surface. The first mismatch records
field-level evidence and blocks the remaining plan suffix; it never searches,
selects a fallback, or repairs the run.

The checked-in Gate C fixtures were produced by RunPlanner-main commit
`ab7031445693fd6f4dba583fa9124e945a41511a`.

Use the desktop Run Planner's **Publish to Game** action. The browser build
cannot publish directly. The archived `archive/phase9-prototype/` directory is
historical evidence from the earlier bundle prototype and is not imported or
executed by the active module.
