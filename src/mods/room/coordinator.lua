-- Inner-room coordinator. It owns exactly one active occurrence session and
-- aggregates room identity, encounter, feature, Timeline, and conformance
-- responsibilities. Incoming transition rewards remain navigation-owned.
local session = type(import) == "function" and import("mods/room/session.lua")
    or require("mods.room.session")
local timelineSession = type(import) == "function" and import("mods/room/timeline/session.lua")
    or require("mods.room.timeline.session")
local timelineBindings = type(import) == "function" and import("mods/room/timeline/bindings.lua")
    or require("mods.room.timeline.bindings")
local overview = type(import) == "function" and import("mods/room/overview.lua")
    or require("mods.room.overview")
local encounterPhases = type(import) == "function" and import("mods/room/timeline/encounters/phases.lua")
    or require("mods.room.timeline.encounters.phases")
local features = type(import) == "function" and import("mods/room/features/structure.lua")
    or require("mods.room.features.structure")
local conformance = type(import) == "function" and import("mods/room/conformance/proof.lua")
    or require("mods.room.conformance.proof")

local coordinator = {}
local ports = setmetatable({}, { __mode = "k" })

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
        timelineIndex = capabilities.timelineIndex or timelineBindings.index,
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
    roomState.prepared = { occurrence = occurrence }
    ports[roomState.prepared] = timelineSession.new(occurrence, bindings)
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
    local active
    if prepared ~= nil and prepared.occurrence.id == occurrence.id then
        active = session.new(occurrence, nil, ports[prepared])
        ports[active] = ports[prepared]
        ports[prepared] = nil
    else
        if type(roomState.timelineIndex) ~= "function" then
            return fail(state, "room timeline index capability is required")
        end
        local bindings, errorValue = roomState.timelineIndex(occurrence)
        if bindings == nil then return fail(state, errorValue) end
        local port = timelineSession.new(occurrence, bindings)
        active = session.new(occurrence, bindings, port)
        ports[active] = port
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
        function() return encounterPhases.prove(active.occurrence, nativeRoom) end,
        function() return features.prove(active.occurrence, nativeRoom, nativeContext) end,
    }) do
        local ok, errorValue = proof()
        if not ok then return fail(state, errorValue) end
    end
    local ok, errorValue = session.prove(active, "overview", true, true)
    if not ok then return fail(state, errorValue) end
    ok, errorValue = session.checkpoint(active, "roomEntered")
    if not ok then return fail(state, errorValue) end
    return active
end

function coordinator.chooseEncounter(state, slotKey)
    local active = coordinator.current(state)
    return active and encounterPhases.choose(active.occurrence, slotKey) or nil
end

function coordinator.encounterAt(state, index)
    local active = coordinator.current(state)
    return active and encounterPhases.at(active.occurrence, index) or nil
end

function coordinator.bindEncounter(state, nativeEncounter, slotKey)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local phase, errorValue = encounterPhases.bind(active.occurrence, nativeEncounter, slotKey)
    if phase == nil then return fail(state, errorValue) end
    return phase
end

function coordinator.encounterPhase(state, nativeEncounter)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local binding = encounterPhases.forNative(nativeEncounter)
    if binding == nil or binding.occurrenceId ~= active.occurrence.id then return nil end
    return binding.phase
end

function coordinator.startEncounter(state, nativeEncounter)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local binding = encounterPhases.forNative(nativeEncounter)
    if binding == nil or binding.occurrenceId ~= active.occurrence.id then return nil end
    local ok, errorValue = session.startEncounter(active)
    if not ok then return fail(state, errorValue) end
    return binding.phase
end

function coordinator.encounterIsFinal(state, nativeEncounter)
    local active = coordinator.current(state)
    if active == nil then return false end
    local binding = encounterPhases.forNative(nativeEncounter)
    if binding == nil or binding.occurrenceId ~= active.occurrence.id then return false end
    return encounterPhases.isFinal(active.occurrence, binding.phase)
end

function coordinator.encounterHandle(state, source)
    local active = coordinator.current(state)
    if active == nil then return nil end
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local nativeEncounter = nativeRoom and nativeRoom.Encounter
    local phase = coordinator.encounterPhase(state, nativeEncounter)
    if phase == nil then return nil end
    local handle = coordinator.resolve(state, active, {
        kind = "encounterInteraction", phaseKey = phase.slotKey,
    })
    return coordinator.bind(state, active, handle, source)
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

function coordinator.activePhase(state, kind)
    local active = coordinator.current(state)
    return active and session.activePhase(active, kind) or nil
end

local function bindingContext(state, context)
    local roomState = stateOf(state)
    if roomState == nil then return nil end
    local active = coordinator.current(state)
    if context == nil then return active end
    if context == active or context == roomState.prepared then return context end
    return nil
end

local function portFor(context) return context and ports[context] or nil end

function coordinator.resolve(state, context, contact)
    local owner = bindingContext(state, context)
    if owner == nil then return fail(state, "timeline-handle", "active or prepared occurrence", "unbound") end
    local source = contact and contact.source
    local handle, errorValue = timelineSession.resolve(portFor(owner), timelineBindings.resolve, contact, source)
    if handle == nil and errorValue ~= nil then return fail(state, errorValue) end
    return handle
end

function coordinator.bind(state, context, handle, nativeObject)
    if handle == nil then return nil end
    local owner = bindingContext(state, context)
    if owner == nil then return fail(state, "timeline-binding", "active or prepared occurrence", "unbound") end
    local bound, errorValue = timelineSession.bind(portFor(owner), handle, nativeObject)
    if bound == nil then return fail(state, errorValue) end
    return bound
end

function coordinator.bound(state, context, nativeObject)
    local owner = bindingContext(state, context)
    return owner and timelineSession.bound(portFor(owner), nativeObject) or nil
end

function coordinator.releaseCompletedBinding(state, context, handle, nativeObject)
    local owner = bindingContext(state, context)
    if owner == nil then return nil end
    local ok, errorValue = timelineSession.releaseCompletedBinding(portFor(owner), handle, nativeObject)
    if ok == nil and errorValue ~= nil then return fail(state, errorValue) end
    return ok
end

function coordinator.sourceRole(state, context, handle, gameName)
    local owner = bindingContext(state, context)
    return owner and timelineSession.sourceRole(portFor(owner), handle, gameName) or nil
end

function coordinator.claimReady(state, context, contact, native, compatible)
    local owner = bindingContext(state, context)
    if owner == nil then return fail(state, "timeline-claim", "active or prepared occurrence", "unbound") end
    local handle, payload, errorValue = timelineSession.claimReady(
        portFor(owner), contact, native, compatible)
    if handle == nil and errorValue ~= nil then return fail(state, errorValue) end
    return handle, payload
end

function coordinator.begin(state, handle)
    local active = coordinator.current(state)
    if active == nil then return fail(state, "timeline-handle", "active occurrence", "none") end
    local payload, errorValue = session.begin(active, handle)
    if errorValue == "completed" then return nil, "completed" end
    if payload == nil then return fail(state, errorValue) end
    return payload
end

function coordinator.peek(state, handle)
    local active = coordinator.current(state)
    if active == nil then return fail(state, "timeline-handle", "active occurrence", "none") end
    local payload, errorValue = timelineSession.peek(portFor(active), handle)
    if payload == nil and errorValue ~= nil then return fail(state, errorValue) end
    return payload
end

function coordinator.complete(state, handle)
    if handle == nil then return coordinator.incidental(state) end
    local active = coordinator.current(state)
    if active == nil then return nil end
    local ok, errorValue = session.complete(active, handle)
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
    ports[active] = nil
    return true
end

return coordinator
