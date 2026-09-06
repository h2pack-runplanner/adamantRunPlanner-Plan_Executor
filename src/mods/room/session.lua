-- The inner room envelope owns its Timeline session directly. Timeline
-- ordering stays local; Overview and conformance remain coordinated by room/.
local timeline = type(import) == "function" and import("mods/room/timeline/session.lua")
    or require("mods.room.timeline.session")

local room = {}

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

function room.new(occurrence, bindings)
    local inner = timeline.new(occurrence, bindings)
    local outer = {
        occurrence = occurrence,
        _timeline = inner,
        proofs = {},
        firstMismatch = nil,
        closed = false,
    }
    return outer
end

local function innerFor(session) return session and session._timeline or nil end

local function delegate(session, method, ...)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local inner = innerFor(session)
    if inner == nil then return mismatch(session, "room-session", "active timeline", "missing") end
    local ok, errorValue = timeline[method](inner, ...)
    if not ok then return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed) end
    return true
end

function room.openWindow(session, window) return delegate(session, "open", window) end
function room.startEncounter(session) return delegate(session, "startEncounter") end
function room.resolve(session, resolver, contact, source)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local inner = innerFor(session)
    if inner == nil then return mismatch(session, "room-session", "active timeline", "missing") end
    local handle, errorValue = timeline.resolve(inner, resolver, contact, source)
    if handle == nil and errorValue ~= nil then
        return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
    return handle
end
function room.bind(session, handle, native)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local inner = innerFor(session)
    if inner == nil then return mismatch(session, "room-session", "active timeline", "missing") end
    local bound, errorValue = timeline.bind(inner, handle, native)
    if bound == nil and errorValue ~= nil then
        return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
    return bound
end
function room.bound(session, native)
    local inner = innerFor(session)
    return inner and timeline.bound(inner, native) or nil
end
function room.releaseCompletedBinding(session, handle, native)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local inner = innerFor(session)
    if inner == nil then return mismatch(session, "room-session", "active timeline", "missing") end
    local ok, errorValue = timeline.releaseCompletedBinding(inner, handle, native)
    if ok == nil and errorValue ~= nil then
        return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
    return ok
end
function room.sourceRole(session, handle, gameName)
    local inner = innerFor(session)
    return inner and timeline.sourceRole(inner, handle, gameName) or nil
end
function room.begin(session, handle)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local payload, errorValue = timeline.begin(innerFor(session), handle)
    if errorValue == "completed" then return nil, "completed" end
    if payload == nil then return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed) end
    return payload
end
function room.peek(session, handle)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local inner = innerFor(session)
    if inner == nil then return mismatch(session, "room-session", "active timeline", "missing") end
    local payload, errorValue = timeline.peek(inner, handle)
    if payload == nil and errorValue ~= nil then
        return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
    return payload
end
function room.claimReady(session, contact, native, compatible)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    local handle, payload, errorValue = timeline.claimReady(
        innerFor(session), contact, native, compatible)
    if handle == nil and errorValue ~= nil then
        return mismatch(session, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
    return handle, payload
end
function room.complete(session, handle)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    return delegate(session, "complete", handle)
end
function room.incidental(session) return delegate(session, "incidental") end
function room.checkpoint(session, checkpoint) return delegate(session, "checkpoint", checkpoint) end
function room.activePhase(session, kind) return timeline.activePhase(innerFor(session), kind) end

function room.dispose(session)
    if session == nil then return end
    session._timeline = nil
    session.closed = true
end

function room.prove(session, checkpoint, expected, observed)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    if session.firstMismatch ~= nil then return nil, session.firstMismatch end
    if not equal(expected, observed) then return mismatch(session, checkpoint, expected, observed) end
    session.proofs[checkpoint] = true
    return true
end

function room.close(session, proveConformance)
    if session.closed then return mismatch(session, "room-session", "open session", "closed") end
    local ok, errorValue = room.checkpoint(session, "roomExit")
    if not ok then return nil, errorValue end
    if proveConformance ~= nil then
        local conformed, conformanceError = proveConformance()
        if not conformed then
            return mismatch(session, conformanceError.checkpoint,
                conformanceError.expected, conformanceError.observed)
        end
    end
    local inner = innerFor(session)
    local closed, closeError = timeline.close(inner)
    if not closed then return mismatch(session, closeError.checkpoint, closeError.expected, closeError.observed) end
    session.closed = true
    session._timeline = nil
    return true
end

return room
