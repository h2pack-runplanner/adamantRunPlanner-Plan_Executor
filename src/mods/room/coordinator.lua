-- Inner-room coordinator. It owns exactly one active occurrence session and
-- aggregates room identity, encounter, feature, Timeline, and conformance
-- responsibilities. Incoming transition rewards remain navigation-owned.
local session = type(import) == "function" and import("mods/room/session.lua")
    or require("mods.room.session")
local overview = type(import) == "function" and import("mods/room/overview.lua")
    or require("mods.room.overview")
local encounters = type(import) == "function" and import("mods/room/encounters.lua")
    or require("mods.room.encounters")
local features = type(import) == "function" and import("mods/room/features/structure.lua")
    or require("mods.room.features.structure")
local conformance = type(import) == "function" and import("mods/room/conformance/proof.lua")
    or require("mods.room.conformance.proof")

local coordinator = {}

local function stateOf(state) return state and state.room end

local function fail(state, errorValue, expected, observed)
    local roomState = stateOf(state)
    if roomState and type(roomState.onMismatch) == "function" then
        return roomState.onMismatch(errorValue, expected, observed)
    end
    return nil, errorValue
end

function coordinator.new(plan, onMismatch, capabilities)
    capabilities = capabilities or {}
    return {
        plan = plan, current = nil, prepared = nil,
        timelineIndex = capabilities.timelineIndex,
        readConformance = capabilities.readConformance,
        onMismatch = onMismatch,
    }
end

function coordinator.current(state)
    if state == nil or state.state ~= "synchronized" then return nil end
    local roomState = stateOf(state)
    return roomState and roomState.current or nil
end

function coordinator.prepare(state, occurrence)
    local roomState = stateOf(state)
    local active = coordinator.current(state)
    if active ~= nil and active.occurrence.id == occurrence.id then return active end
    if roomState.prepared ~= nil and roomState.prepared.occurrence.id == occurrence.id then
        return roomState.prepared
    end
    if type(roomState.timelineIndex) ~= "function" then
        return fail(state, "room timeline index capability is required")
    end
    local bindings, errorValue = roomState.timelineIndex(occurrence)
    if bindings == nil then return fail(state, errorValue) end
    roomState.prepared = { occurrence = occurrence, bindings = bindings }
    return roomState.prepared
end

function coordinator.realize(state, occurrence, game, nativeRoom)
    local realized, errorValue = overview.realize(occurrence, game, nativeRoom)
    if realized == nil then return fail(state, errorValue) end
    coordinator.realizeFeatures(occurrence, realized)
    return realized
end

function coordinator.realizeFeatures(occurrence, nativeRoom)
    return features.realize(occurrence, nativeRoom)
end

function coordinator.enter(state, occurrence, nativeRoom)
    if state.state ~= "synchronized" then return nil end
    local roomState = stateOf(state)
    if roomState.current ~= nil then
        return fail(state, "room-entry", "current room must exit", occurrence.id)
    end
    local prepared = roomState.prepared
    local active = session.new(occurrence)
    if prepared ~= nil and prepared.occurrence.id == occurrence.id then
        active.bindings = prepared.bindings
    else
        if type(roomState.timelineIndex) ~= "function" then
            return fail(state, "room timeline index capability is required")
        end
        local bindings, errorValue = roomState.timelineIndex(occurrence)
        if bindings == nil then return fail(state, errorValue) end
        active.bindings = bindings
    end
    roomState.prepared = nil
    roomState.current = active
    if nativeRoom ~= nil then return coordinator.proveEntry(state, nativeRoom) end
    return active
end

function coordinator.proveEntry(state, nativeRoom, nativeContext)
    local active = coordinator.current(state)
    if active == nil then return nil end
    for _, proof in ipairs({
        function() return overview.prove(active.occurrence, nativeRoom) end,
        function() return encounters.prove(active.occurrence, nativeRoom) end,
        function() return features.prove(active.occurrence, nativeRoom, nativeContext) end,
    }) do
        local ok, errorValue = proof()
        if not ok then return fail(state, errorValue) end
    end
    local ok, errorValue = session.prove(active, "overview", true, true)
    if not ok then return fail(state, errorValue) end
    return active
end

function coordinator.chooseEncounter(state, slotKey)
    local active = coordinator.current(state)
    return active and encounters.choose(active.occurrence, slotKey) or nil
end

function coordinator.additional(state, kind)
    local active = coordinator.current(state)
    if active == nil then return nil end
    for _, additional in ipairs(active.occurrence.overview.additional or {}) do
        if additional.kind == kind then
            local occurrence = state.plan and state.plan.occurrencesById[additional.room.id]
            return additional, occurrence
        end
    end
    return nil
end

function coordinator.feature(state, key)
    local active = coordinator.current(state)
    return active and active.occurrence.overview[key] or nil
end

function coordinator.window(state, window)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.openWindow(active, window)
    if not ok then return fail(state, errorValue) end
    return true
end

function coordinator.checkpoint(state, checkpoint)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.checkpoint(active, checkpoint)
    if not ok then return fail(state, errorValue) end
    return true
end

function coordinator.completeOwner(state, owner)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.complete(active, owner)
    if not ok then return fail(state, errorValue) end
    return true
end

function coordinator.readyOwner(state, owner)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.ready(active, owner)
    if not ok then return fail(state, errorValue) end
    return true
end

function coordinator.incidental(state)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.incidental(active)
    if not ok then return fail(state, errorValue) end
    return true
end

function coordinator.close(state, currentRun, gameState)
    local roomState = stateOf(state)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local reader = roomState.readConformance
    local ok, errorValue = session.close(active, function()
        return conformance.prove(active.occurrence, function(kind, expected)
            return type(reader) == "function" and reader(kind, currentRun, gameState, expected) or nil
        end)
    end)
    if not ok then return fail(state, errorValue) end
    roomState.current = nil
    return true
end

return coordinator
