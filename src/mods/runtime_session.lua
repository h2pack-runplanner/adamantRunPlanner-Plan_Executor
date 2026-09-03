-- Thin coordinator for protocol-v12 route and room sessions. Semantic
-- comparison stays in the native fact adapters; this module only propagates
-- their exact owner proofs and the first mismatch that disables enforcement.
local route = type(import) == "function" and import("mods/route/session.lua")
    or require("mods.route.session")
local room = type(import) == "function" and import("mods/room/coordinator.lua")
    or require("mods.room.coordinator")
local timeline = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods/native_timeline_adapters")
local conformance = type(import) == "function" and import("mods/room/conformance/readers.lua")
    or require("mods.room.conformance.readers")

local runtime = { CACHE_NAME = "ExecutionRoomSession" }

local function fail(state, errorValue, expected, observed)
    if state.firstMismatch == nil then
        state.firstMismatch = type(errorValue) == "table" and errorValue or {
            checkpoint = errorValue, expected = expected, observed = observed,
        }
    end
    state.state, state.reason = "desynchronized", "first-mismatch"
    local routeState = state.route
    if routeState and routeState.firstMismatch == nil then routeState.firstMismatch = state.firstMismatch end
    return nil, state.firstMismatch
end

function runtime.defineCache(module)
    module.cache.define({
        [runtime.CACHE_NAME] = {
            domain = "currentRun", key = "execution-room-session",
            factory = function()
                return {
                    initialized = false, state = "inactive", reason = "not-started",
                    diagnostics = {},
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

function runtime.start(state, inbox, phase)
    state.initialized = true
    local loaded, plan = inbox.load()
    if not loaded or type(plan) ~= "table" or plan.kind ~= "ready" then
        local inboxStatus = inbox.status and inbox.status() or nil
        local observed = inboxStatus and inboxStatus.error or plan
        return fail(state, "run-start", "ready protocol-v12 plan", observed)
    end
    for _, occurrence in ipairs(plan.occurrences) do
        for _, fact in ipairs((occurrence.roomExitConformance or {}).facts or {}) do
            if not conformance.supports(fact.kind) then
                return fail(state, "room-exit-conformance", "reachable F/G reader", fact.kind)
            end
        end
    end
    state.plan = plan
    state.route = route.new(plan)
    state.room = room.new(plan, function(errorValue, expected, observed)
        return fail(state, errorValue, expected, observed)
    end, {
        timelineIndex = timeline.index,
        readConformance = function(kind, currentRun, gameState, expected)
            return conformance.read(kind, currentRun, gameState, expected)
        end,
    })
    state.state, state.reason = phase == "starting" and "starting" or "synchronized", "ready"
    return true
end

function runtime.complete(state, row, verified, expected, observed)
    local current = room.current(state)
    if current == nil then return nil end
    if row == nil then return room.incidental(state) end
    if not verified then return fail(state, "transaction-outcome", expected or row.node, observed) end
    return room.completeOwner(state, row.node.owner)
end

function runtime.resolveFallback(state, row, contact, fallback, available, native)
    local current = room.current(state)
    if current == nil then return nil end
    local key, rowOrError = timeline.resolveFallback(
        current.bindings, row, contact, fallback, available, native
    )
    if key == nil then return fail(state, rowOrError) end
    return key, rowOrError
end

function runtime.automatic(state, effect, phaseKey, observed)
    local current = room.current(state)
    if current == nil then return nil end
    local row = timeline.automatic(current.bindings, effect, phaseKey)
    if row == nil then return room.incidental(state) end
    return runtime.complete(state, row, timeline.verifyAutomatic(row, observed), row.node, observed)
end

function runtime.diagnostic(state, checkpoint, observed)
    local current = room.current(state)
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

return runtime
