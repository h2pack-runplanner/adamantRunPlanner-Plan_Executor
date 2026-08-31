# Plan Executor

Plan Executor is the thin Hades II consumer of the standalone Run Planner's
execution-only JSON. It does not plan, simulate, or reinterpret a project.

The module reads the fixed `active.runplanner.json` slot under the
ReturnOfModding configuration, strictly decodes the bounded v6 Underworld F or
F/G execution contract, and freezes it only when a new run starts. It realizes
occurrence-marked rooms, ordered door peers, fixed links, rewards, room-object
inventories, and compiled acquisition outcomes only at their normal vanilla
seams. It observes the ordered trace, player interactions, selected exits and
acquisitions, and the complete published Run State checkpoint surface. The
first mismatch records field-level evidence and blocks the remaining plan
suffix; it never searches, selects a fallback, or repairs the run.

The supported F/G surface includes ordinary and fixed room links, typed reward
generation, selected trait offers and actions, objects, Anomaly, Narcissus,
Nemesis, Zagreus Contract, and Chaos/Ixion. A Chaos additional exit carries all
three displayed curse options, the selected curse/blessing pair, its
acquisition, and the compiled fixed return. Run State comparison is a bounded
diagnostic at published lifecycle checkpoints, never a source of runtime route
selection or repair. A player taking a different authored choice is recorded as
player divergence; a mismatched realized fact is a conformance discrepancy.

The checked-in fixtures are compiler products and session-contract evidence.
They do not replace live Hades II probes; until a host is available, native
seam status is explicitly unexecuted rather than inferred from Lua tests.

The checked-in execution fixtures mirror RunPlanner-main's compiler fixtures
byte for byte.

Use the desktop Run Planner's **Publish to Game** action. The browser build
cannot publish directly. The archived `archive/phase9-prototype/` directory is
historical evidence from the earlier bundle prototype and is not imported or
executed by the active module.
