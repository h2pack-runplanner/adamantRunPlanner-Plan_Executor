-- Occurrence-local reconciliation.  This module intentionally has no native
-- API knowledge: hooks bind an opaque published owner and report one proof.
local roomSession = {}

local function equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function mismatch(session, checkpoint, expected, observed)
    if session.firstMismatch == nil then
        session.firstMismatch = { checkpoint = checkpoint, expected = expected, observed = observed }
    end
    return nil, session.firstMismatch
end

function roomSession.new(occurrence)
    local prerequisites, obligations = {}, {}
    for _, edge in ipairs(occurrence.timeline.dependencies) do
        prerequisites[edge.owner] = prerequisites[edge.owner] or {}
        prerequisites[edge.owner][edge.afterOwner] = true
    end
    for _, obligation in ipairs(occurrence.timeline.obligations) do
        obligations[obligation.checkpoint] = obligations[obligation.checkpoint] or {}
        obligations[obligation.checkpoint][obligation.owner] = true
    end
    return {
        occurrence = occurrence, window = "roomEntered", completedOwners = {},
        outgoingGenerated = false,
        prerequisites = prerequisites, obligations = obligations, proofs = {},
        firstMismatch = nil, closed = false,
    }
end

function roomSession.openWindow(session, window)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local allowed = {
        roomEntered = true, afterCombat = true, postOutgoing = true,
    }
    -- Phase windows are deliberately opaque to the session, but their prefix
    -- is not: accepting an arbitrary string here would turn a misspelled
    -- adapter lifecycle contact into an incidental callback.
    if type(window) ~= "string" or not (allowed[window]
        or window:match("^encounterEnd:.+") or window:match("^bossDefeated:.+")) then
        return mismatch(session, "lifecycle-window", "published lifecycle window", window)
    end
    -- Outgoing generation is a milestone, not an exclusive phase. Native
    -- rooms may generate their doors while an after-combat pickup remains
    -- pending, so it must not replace the active combat lifecycle window.
    if window == "postOutgoing" then
        session.outgoingGenerated = true
        return true
    end
    session.window = window
    return true
end

function roomSession.complete(session, owner, _outcome)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local transaction = session.occurrence.transactionsByOwner[owner]
    -- A completed proof is adapter-bound.  Treating an unknown owner as an
    -- incidental callback here would hide a misspelled or stale binding.
    if transaction == nil then return mismatch(session, "transaction-owner", "published owner", owner) end
    local expectedWindow = transaction.window
    if expectedWindow then
        if expectedWindow.kind == "postOutgoing" then
            if not session.outgoingGenerated then
                return mismatch(session, "transaction-window", "postOutgoing", session.window)
            end
        else
            local expected = expectedWindow.kind == "standard"
                and (expectedWindow.phase == "beforeCombat" and "roomEntered" or "afterCombat")
                or expectedWindow.kind == "encounterEnd" and ("encounterEnd:" .. expectedWindow.phaseKey)
                or "bossDefeated:" .. expectedWindow.phaseKey
            if session.window ~= expected then
                return mismatch(session, "transaction-window", expected, session.window)
            end
        end
    end
    for prerequisite in pairs(session.prerequisites[owner] or {}) do
        if not session.completedOwners[prerequisite] then
            return mismatch(session, "transaction-prerequisite", prerequisite, owner)
        end
    end
    -- The adapter verifies its own published outcome before reporting this
    -- owner.  This session owns only atomic owner/window/dependency state.
    session.completedOwners[owner] = true
    return true
end

-- Hooks call this deliberately for contacts they know were omitted from the
-- blocking product.  It cannot accidentally complete or mismatch an owner.
function roomSession.incidental(session)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    return true
end

function roomSession.prove(session, checkpoint, expected, observed)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if not equal(expected, observed) then return mismatch(session, checkpoint, expected, observed) end
    session.proofs[checkpoint] = true
    return true
end

function roomSession.checkpoint(session, checkpoint)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if not ({ roomEntered=true, outgoingGeneration=true, exitUsable=true, roomExit=true })[checkpoint] then
        return mismatch(session, "checkpoint", "published checkpoint", checkpoint)
    end
    for owner in pairs(session.obligations[checkpoint] or {}) do
        if not session.completedOwners[owner] then
            return mismatch(session, "obligation:" .. checkpoint, owner, "incomplete")
        end
    end
    return true
end

function roomSession.close(session, readConformance)
    local ok, errorValue = roomSession.checkpoint(session, "roomExit")
    if not ok then return nil, errorValue end
    for _, fact in ipairs((session.occurrence.roomExitConformance or {}).facts or {}) do
        local expected = session.occurrence.conformanceExpected and session.occurrence.conformanceExpected[fact.kind]
        local observed = readConformance and readConformance(fact.kind) or nil
        if expected == nil or observed == nil or not equal(expected, observed) then
            return mismatch(session, "room-exit-conformance:" .. fact.kind, expected, observed)
        end
    end
    session.closed = true
    session.completedOwners = {} -- never leaks into another occurrence
    return true
end

return roomSession
