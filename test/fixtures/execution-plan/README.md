# Gate-C producer fixtures

`f-opening.execution.json` and `fg.execution.json` are readable wire fixtures
produced by RunPlanner-main at commit
`ab7031445693fd6f4dba583fa9124e945a41511a` (`ab703144`). They use execution
protocol version `3`, and cover F-only and
configured F/G execution extents. They include closed room traces, trait and
level settlements, and expanded Run State diagnostics. Automatic outcomes are
covered by synthetic direct and hook witnesses because these fixture files do
not contain automatic-outcome rows. The fixtures are intentionally copied as data; tests do not
import the planner or its implementation.
