# Gate-B producer fixtures

`f-opening.execution.json` and `fg.execution.json` are readable wire fixtures
produced by RunPlanner-main at commit
`97001e2faa47e2438891c66abf2ef7709bf5ef94` (`97001e2f`). They use execution
protocol version `2`, and cover F-only and configured F/G execution extents.
They include occurrence-marked rooms, ordered peers, resolved stores, fixed
completion links, and room-entry/pre-exit diagnostics. The fixtures are
intentionally copied as data; tests do not import the planner or its
implementation.
