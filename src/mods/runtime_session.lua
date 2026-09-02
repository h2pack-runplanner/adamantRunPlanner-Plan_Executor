-- Thin coordinator for protocol-v10 route and occurrence sessions. Semantic
-- comparison stays in the native fact adapters; this module only propagates
-- their exact owner proofs and the first blocking mismatch.
local route = type(import) == "function" and import("mods/route_session.lua")
    or require("mods/route_session")
local room = type(import) == "function" and import("mods/room_session.lua")
    or require("mods/room_session")
local overview = type(import) == "function" and import("mods/native_overview.lua")
    or require("mods/native_overview")
local doors = type(import) == "function" and import("mods/native_doors.lua")
    or require("mods/native_doors")
local timeline = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods/native_timeline_adapters")
local conformance = type(import) == "function" and import("mods/native_conformance.lua")
    or require("mods/native_conformance")

local runtime = { CACHE_NAME = "ExecutionRoomSession" }
local supportedConformance = {
    steadyGrowth = true, chaos = true, keepsakeEffects = true,
    rewardPriorities = true, pathOfStars = true, forfeit = true, stygianWell = true,
}

local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not same(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function fail(state, errorValue, expected, observed)
    if state.firstMismatch == nil then
        state.firstMismatch = type(errorValue) == "table" and errorValue or {
            checkpoint = errorValue, expected = expected, observed = observed,
        }
    end
    state.state, state.reason = "desynchronized", "first-mismatch"
    if state.route and state.route.firstMismatch == nil then state.route.firstMismatch = state.firstMismatch end
    return nil, state.firstMismatch
end

function runtime.defineCache(module)
    module.cache.define({
        [runtime.CACHE_NAME] = {
            domain = "currentRun", key = "execution-room-session",
            factory = function()
                return {
                    initialized = false, state = "inactive", reason = "not-started",
                    diagnostics = {}, startingKeepsake = { active = false, results = {} },
                }
            end,
        },
    })
end

function runtime.get(host) return host.data.cache.currentRun.get(runtime.CACHE_NAME) end

function runtime.status(state)
    return {
        state = state.state, reason = state.reason,
        checkpoint = state.firstMismatch and state.firstMismatch.checkpoint,
    }
end

function runtime.mismatch(state, checkpoint, expected, observed)
    return fail(state, checkpoint, expected, observed)
end

function runtime.start(state, inbox)
    state.initialized = true
    local loaded, plan = inbox.load()
    if not loaded or type(plan) ~= "table" or plan.kind ~= "ready" then
        return fail(state, "run-start", "ready protocol-v10 plan", plan)
    end
    for _, occurrence in ipairs(plan.occurrences) do
        for _, fact in ipairs((occurrence.roomExitConformance or {}).facts or {}) do
            if not supportedConformance[fact.kind] then
                return fail(state, "room-exit-conformance", "reachable F/G reader", fact.kind)
            end
        end
    end
    state.plan, state.route = plan, route.new(plan)
    state.state, state.reason = "synchronized", "ready"
    return true
end

function runtime.expectedOccurrence(state)
    local routeState = state.route
    local id = routeState and routeState.plan.selectedOccurrenceIds[routeState.index]
    return id and routeState.plan.occurrencesById[id] or nil
end

function runtime.realizeStartingRoom(state, game, nativeRoom)
    local occurrence = runtime.expectedOccurrence(state)
    if occurrence == nil then return nil end
    local realized, errorValue = overview.realize(occurrence, game, nativeRoom)
    if realized == nil then return fail(state, errorValue) end
    return realized
end

function runtime.realizeOccurrence(state, occurrenceId, game, nativeRoom)
    local occurrence = state.plan and state.plan.occurrencesById[occurrenceId]
    if occurrence == nil then return fail(state, "room-realization", "published occurrence", occurrenceId) end
    local realized, errorValue = overview.realize(occurrence, game, nativeRoom)
    if realized == nil then return fail(state, errorValue) end
    return realized
end

function runtime.beginStartingKeepsake(state, key)
    local expected = state.plan and state.plan.startingKeepsake
    if expected == nil then return nil end
    if key ~= expected.keepsakeKey then return fail(state, "starting-keepsake", expected.keepsakeKey, key) end
    state.startingKeepsake = { active = true, expected = expected, results = {} }
    return expected
end

function runtime.recordStartingKeepsakeResult(state, kind, value)
    local pending = state.startingKeepsake
    if not pending or not pending.active then return true end
    pending.results[kind] = value
    return true
end

function runtime.finishStartingKeepsake(state)
    local pending = state.startingKeepsake
    if not pending or not pending.active then return true end
    local expected = pending.expected.equipResults or {}
    for kind, value in pairs(expected) do
        local observed = pending.results[kind]
        local equivalent = observed ~= nil and same(value, observed)
        if not equivalent and kind == "jeweledPom" and type(value.runtimeFallbacks) == "table" then
            for _, fallback in ipairs(value.runtimeFallbacks) do
                if observed and (observed.traitKey == fallback.preferredKey
                    or observed.traitKey == fallback.fallbackKey) then equivalent = true end
            end
        end
        if not equivalent then
            return fail(state, "starting-keepsake:" .. kind, value, observed)
        end
    end
    pending.active = false
    return true
end

function runtime.enter(state, occurrenceId, gameName, nativeRoom)
    if state.state ~= "synchronized" then return nil end
    local current, errorValue = route.enter(state.route, occurrenceId, gameName)
    if current == true then return true end
    if current == nil then return fail(state, errorValue) end
    local bindings, bindingError = timeline.index(current.occurrence)
    if bindings == nil then return fail(state, bindingError) end
    current.bindings = bindings
    current.generatedDoorIndexes = {}
    current.overviewBindings = overview.bind(current.occurrence, nativeRoom)
    if nativeRoom ~= nil then
        local ok, observed = overview.prove(current.occurrence, nativeRoom)
        if not ok then return fail(state, observed) end
        local proved, proofError = room.prove(current, "overview", true, true)
        if not proved then return fail(state, proofError) end
    end
    return current
end

function runtime.current(state) return state.route and state.route.current or nil end

function runtime.realizeOverview(state, game, nativeRoom)
    local occurrence = runtime.expectedOccurrence(state)
    if occurrence == nil then return nativeRoom end
    local realized, errorValue = overview.realize(occurrence, game, nativeRoom)
    if realized == nil then return fail(state, errorValue) end
    return realized
end

function runtime.chooseEncounter(state, slotKey)
    local current = runtime.current(state)
    return current and overview.chooseEncounter(current.occurrence, slotKey) or nil
end

function runtime.realizeDoors(state, nativeDoors, game)
    local current = runtime.current(state)
    if current == nil then return nativeDoors end
    return doors.realize(current.occurrence, nativeDoors, game)
end

function runtime.proveDoors(state, nativeDoors)
    local current = runtime.current(state)
    if current == nil then return nil end
    local ok, observed = doors.prove(current.occurrence, nativeDoors)
    if not ok then return fail(state, observed) end
    local closed, errorValue = room.checkpoint(current, "outgoingGeneration")
    if not closed then return fail(state, errorValue) end
    local opened, windowError = room.openWindow(current, "postOutgoing")
    if not opened then return fail(state, windowError) end
    current.doorBindings = doors.bind(current.occurrence, nativeDoors)
    return true
end

function runtime.chooseNextRoom(state, game, index)
    local current = runtime.current(state)
    return current and doors.chooseNext(current.occurrence, game, index) or nil
end

function runtime.nextDoorRoom(state, game, nativeIndex)
    local current = runtime.current(state)
    if current == nil then return nil end
    local expected = current.occurrence.doors
    if expected.kind == "fixed" then return doors.chooseNext(current.occurrence, game, 1) end
    if expected.kind ~= "batch" then return nil end
    local index = nativeIndex
    if index == nil then
        for candidate = 1, #expected.targets do
            if not current.generatedDoorIndexes[candidate] then index = candidate; break end
        end
    end
    if index == nil then return nil end
    current.generatedDoorIndexes[index] = true
    return doors.chooseNext(current.occurrence, game, index)
end

function runtime.additionalRoom(state, kind, game)
    local current = runtime.current(state)
    if current == nil then return nil end
    for _, additional in ipairs(current.occurrence.overview.additional or {}) do
        if additional.kind == kind then
            local result = runtime.realizeOccurrence(state, additional.room.id, game)
            if type(result) == "table" then
                result.__runPlannerExecutionAdditionalOwner = additional.owner
                result.__runPlannerExecutionAdditionalKind = kind
            end
            return result, additional
        end
    end
    return nil
end

function runtime.feature(state, key)
    local current = runtime.current(state)
    return current and current.occurrence.overview[key] or nil
end

function runtime.window(state, window)
    local current = runtime.current(state)
    if current == nil then return nil end
    local ok, errorValue = room.openWindow(current, window)
    if not ok then return fail(state, errorValue) end
    return true
end

function runtime.checkpoint(state, checkpoint)
    local current = runtime.current(state)
    if current == nil then return nil end
    local ok, errorValue = room.checkpoint(current, checkpoint)
    if not ok then return fail(state, errorValue) end
    return true
end

function runtime.lookup(state, namespace, key, native)
    local current = runtime.current(state)
    if current == nil then return nil end
    return timeline.bind(current.bindings, timeline.lookup(current.bindings, namespace, key), native)
end

function runtime.role(state, lifecyclePoint, gameName, native)
    local current = runtime.current(state)
    return current and timeline.role(current.bindings, lifecyclePoint, gameName, native) or nil
end

function runtime.bound(state, native)
    local current = runtime.current(state)
    return current and timeline.bound(current.bindings, native) or nil
end

function runtime.complete(state, row, verified, expected, observed)
    local current = runtime.current(state)
    if current == nil then return nil end
    if row == nil then return room.incidental(current) end
    if not verified then return fail(state, "transaction-outcome", expected or row.node, observed) end
    local ok, errorValue = room.complete(current, row.node.owner)
    if not ok then return fail(state, errorValue) end
    return true
end

function runtime.resolveFallback(state, row, contact, fallback, available, native)
    local current = runtime.current(state)
    if current == nil then return nil end
    local key, rowOrError = timeline.resolveFallback(
        current.bindings, row, contact, fallback, available, native
    )
    if key == nil then return fail(state, rowOrError) end
    return key, rowOrError
end

function runtime.automatic(state, effect, phaseKey, observed)
    local current = runtime.current(state)
    if current == nil then return nil end
    local row = timeline.automatic(current.bindings, effect, phaseKey)
    if row == nil then return room.incidental(current) end
    return runtime.complete(state, row, timeline.verifyAutomatic(row, observed), row.node, observed)
end

function runtime.diagnostic(state, checkpoint, observed)
    local current = runtime.current(state)
    if current == nil then return true end
    local expected = current.occurrence.diagnostics and current.occurrence.diagnostics[checkpoint]
    state.diagnostics[#state.diagnostics + 1] = {
        occurrenceId = current.occurrence.id, checkpoint = checkpoint,
        expected = expected, observed = observed,
    }
    return true
end

function runtime.readConformance(kind, currentRun, gameState, expected)
    return conformance.read(kind, currentRun, gameState, expected)
end

function runtime.exit(state, currentRun, gameState)
    if state.state ~= "synchronized" then return nil end
    local current = runtime.current(state)
    if current == nil then return nil end
    local ok, errorValue = route.exit(state.route, function(kind)
        return conformance.read(kind, currentRun, gameState, current.occurrence.conformanceExpected[kind])
    end)
    if not ok then return fail(state, errorValue) end
    if runtime.expectedOccurrence(state) == nil then state.reason = "configured-prefix-complete" end
    return true
end

return runtime
