# Plan Executor

Plan Executor is the thin Hades II consumer of the standalone Run Planner's
execution-only JSON. It does not plan, simulate, or reinterpret a project.

The module reads the fixed `active.runplanner.json` slot under the
ReturnOfModding configuration, strictly decodes the bounded v12 Underworld F
or F/G execution contract, and freezes it only when a new run starts. It
follows the selected Room Occurrence cursor and reconciles Overview,
consequential owners, lifecycle obligations, sparse room-exit state, and
Doors. Diagnostic Run State frames are expanded once while decoding and remain
nonblocking. The first mismatch records evidence and blocks the remaining
configured prefix; it never searches for a replacement action.

The supported F/G surface includes ordinary and fixed room links, typed reward
generation, selected trait offers and actions, objects, Anomaly, Arachne, Narcissus,
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

The sole outer cursor lives in `src/mods/route/`; one volatile occurrence
session lives in `src/mods/room/`. `src/mods/navigation/` is stateless and owns
only destination Doors, their rewards, native Door bindings, and reporting the
selected destination to the route session. Room identity, encounters, feature
presence, lifecycle windows, and Timeline obligations remain inside the room
envelope or their owning adapters. Within it, `room/features/` owns structural
feature spawning and native inventories, `room/conformance/` owns room-exit
readers and proof, and `room/timeline/` owns interactions with already-realized
features. A `navigation/biomes/` subdirectory is added only when a biome
contributes genuinely exceptional transition structure.

Use the desktop Run Planner's **Publish to Game** action. The browser build
cannot publish directly. The archived `archive/phase9-prototype/` directory is
historical evidence from the earlier bundle prototype and is not imported or
executed by the active module.
