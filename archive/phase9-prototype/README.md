# Archived Plan Executor Prototype

This directory preserves the earlier Plan Executor prototype at checkpoint
commit `b7c3b774b64ffcf420102299c81d6d962406c94c` (`b7c3b77`). It is historical
evidence, not an active implementation or compatibility contract. The active
module is the bounded execution-plan consumer under `src/`; nothing in this
archive is imported, packaged, or executed by it.

## Evidence preserved

The checkpoint recorded successful live probes for the fixed publication/receipt
path, F starting-room realization, and the initial room-reward contact. Its
broader lifecycle behavior—physical door targets, reward forcing, encounter
and detour handling, and the multi-route bundle shape—was unit-tested prototype
behavior only; it was not established as live game behavior by this checkpoint.

## Obsolete assumptions

The prototype used execution *bundles* that could carry project-oriented and
multi-route state, refreshed or searched for fallback instructions, and owned a
larger lifecycle model than the current contract. Those assumptions are
retained here only to explain why the files moved. They must not be restored by
copying code into the active module.

The archive is intentionally excluded from active imports, package output, and
the current test fixture path. Use it to recover historical evidence only; the
current producer protocol and its strict decoder are the sole supported seam.
