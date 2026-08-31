# Gate-C producer fixtures

`f-opening.execution.json`, `fg.execution.json`, and
`fg-ixion-chaos.execution.json` are readable wire fixtures produced by the
current RunPlanner-main compiler. They use execution protocol version `9` and
cover F-only and configured F/G execution extents, including the route-start
keepsake contract. They include closed room traces, trait and level settlements,
and expanded Run State diagnostics. Automatic outcomes are covered by synthetic
direct and hook witnesses because these fixture files do not contain
automatic-outcome rows. The fixtures are intentionally copied as data; tests do
not import the planner or its implementation.
