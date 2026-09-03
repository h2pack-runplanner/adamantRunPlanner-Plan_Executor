-- Occurrence-local Timeline DAG: readiness, completion, and obligation
-- deadlines. Native adapters own actual effects and their proofs.
local lifecycle = type(import) == "function" and import("mods/room/timeline/lifecycle.lua")
    or require("mods.room.timeline.lifecycle")
local bindings = type(import) == "function" and import("mods/room/timeline/bindings.lua")
    or require("mods.room.timeline.bindings")

local timeline = {}

local function mismatch(session, checkpoint, expected, observed)
    if session.firstMismatch == nil then
        session.firstMismatch = { checkpoint = checkpoint, expected = expected, observed = observed }
    end
    return nil, session.firstMismatch
end

function timeline.new(occurrence, index)
    if index == nil or index.owner == nil then index = assert(bindings.index(occurrence)) end
    local prerequisites, obligations = {}, {}
    for _, edge in ipairs(occurrence.timeline.dependencies or {}) do
        prerequisites[edge.owner] = prerequisites[edge.owner] or {}
        prerequisites[edge.owner][edge.afterOwner] = true
    end
    for _, obligation in ipairs(occurrence.timeline.obligations or {}) do
        obligations[obligation.checkpoint] = obligations[obligation.checkpoint] or {}
        obligations[obligation.checkpoint][obligation.owner] = true
    end
    local session = {
        occurrence = occurrence,
        bindings = index,
        prerequisites = prerequisites,
        obligations = obligations,
        completedOwners = {},
        capabilities = lifecycle.new(),
        firstMismatch = nil,
        closed = false,
        handles = {},
        nativeHandles = {},
        handleNatives = {},
    }
    return session
end

local function rowFor(session, handle)
    local row = type(handle) == "table" and session.handles[handle] or nil
    if row == nil then
        local _, errorValue = mismatch(session, "timeline-handle", "handle from this occurrence", "unknown")
        return nil, errorValue
    end
    return row
end

local function handleFor(session, row)
    if row == nil then return nil end
    session.handles = session.handles or {}
    for handle, existing in pairs(session.handles) do
        if existing == row then return handle end
    end
    local handle = {}
    session.handles[handle] = row
    return handle
end

function timeline.resolve(session, resolver, contact, sourceHandle)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local source
    if sourceHandle ~= nil then
        source = rowFor(session, sourceHandle)
        if source == nil then return nil, session.firstMismatch end
    end
    local row, errorValue = resolver(session.bindings, contact, source)
    if errorValue ~= nil then
        return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
    return handleFor(session, row)
end

function timeline.bind(session, handle, native)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    local row, errorValue = rowFor(session, handle)
    if row == nil then return nil, errorValue end
    if native == nil then return handle end
    local priorHandle = session.nativeHandles[native]
    local priorNative = session.handleNatives[handle]
    if (priorHandle ~= nil and priorHandle ~= handle) or (priorNative ~= nil and priorNative ~= native) then
        return mismatch(session, "timeline-binding", "one native carrier per exact handle", "different binding")
    end
    session.nativeHandles[native], session.handleNatives[handle] = handle, native
    return handle
end

function timeline.bound(session, native)
    if session.closed or session.firstMismatch ~= nil then return nil end
    return session.nativeHandles[native]
end

function timeline.sourceRole(session, handle, gameName)
    local row = rowFor(session, handle)
    return row and bindings.sourceRole(row, gameName) or nil
end

function timeline.realize(session, handle, key)
    local row, errorValue = rowFor(session, handle)
    if row == nil then return nil, errorValue end
    bindings.realize(row, key)
    return true
end

function timeline.open(session, window)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local ok, errorValue = lifecycle.open(session.capabilities, window)
    if not ok then return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed) end
    return true
end

local function beginOwner(session, owner)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local transaction = session.occurrence.transactionsByOwner[owner]
    if transaction == nil then return mismatch(session, "transaction-owner", "published owner", owner) end
    local open, expected = lifecycle.accepts(session.capabilities, transaction.window)
    if not open then return mismatch(session, "transaction-window", expected, "closed") end
    for prerequisite in pairs(session.prerequisites[owner] or {}) do
        if not session.completedOwners[prerequisite] then
            return mismatch(session, "transaction-prerequisite", prerequisite, owner)
        end
    end
    return true
end

function timeline.begin(session, handle)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local row, errorValue = rowFor(session, handle)
    if row == nil then return nil, errorValue end
    if session.completedOwners[row.transaction.owner] then return nil, "completed" end
    local ok, beginError = beginOwner(session, row.transaction.owner)
    if not ok then return nil, beginError end
    return bindings.payload(row)
end

function timeline.activePhase(session, kind)
    if session.closed or session.firstMismatch ~= nil then return nil end
    return lifecycle.activePhase(session.capabilities, kind)
end

function timeline.complete(session, handle, _proof)
    local row, rowError = rowFor(session, handle)
    if row == nil then return nil, rowError end
    if session.completedOwners[row.transaction.owner] then return true end
    local payload, errorValue = timeline.begin(session, handle)
    if payload == nil then return nil, errorValue end
    session.completedOwners[payload.transaction.owner] = true
    return true
end

function timeline.incidental(session)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    return true
end

function timeline.checkpoint(session, checkpoint)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if not lifecycle.isCheckpoint(checkpoint) then
        return mismatch(session, "checkpoint", "published checkpoint", checkpoint)
    end
    for owner in pairs(session.obligations[checkpoint] or {}) do
        if not session.completedOwners[owner] then
            return mismatch(session, "obligation:" .. checkpoint, owner, "incomplete")
        end
    end
    return true
end

function timeline.close(session)
    local ok, errorValue = timeline.checkpoint(session, "roomExit")
    if not ok then return nil, errorValue end
    session.closed = true
    session.completedOwners = {}
    session.capabilities = {}
    session.bindings = nil
    session.handles = {}
    session.nativeHandles, session.handleNatives = {}, {}
    return true
end

return timeline
