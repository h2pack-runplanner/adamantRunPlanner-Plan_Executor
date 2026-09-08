-- Thin coordinator for the current route and room execution protocol. Semantic
-- comparison stays in the native fact adapters; this module only propagates
-- their exact owner contacts and the first mismatch that disables enforcement.
local route = type(import) == "function" and import("mods/route/session.lua")
    or require("mods.route.session")
local room = type(import) == "function" and import("mods/room/coordinator.lua")
    or require("mods.room.coordinator")
local conformance = type(import) == "function" and import("mods/room/conformance/readers.lua")
    or require("mods.room.conformance.readers")
local admission = type(import) == "function" and import("mods/room/conformance/admission.lua")
    or require("mods.room.conformance.admission")

local runtime = { CACHE_NAME = "ExecutionRoomSession" }
-- Cache values live on CurrentRun and can be restored from a save.  This
-- process-local identity set is therefore the admission guard; it is never
-- serialized with the execution session.
local processAdmissions = setmetatable({}, { __mode = "k" })

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
    if state.state ~= "desynchronized" and state.room ~= nil then room.dispose(state) end
    return fail(state, checkpoint, expected, observed)
end

function runtime.canAttemptPostbossAdmission(state)
    return type(state) == "table" and processAdmissions[state] ~= true
end

local function discardTransient(state)
    if state.room ~= nil then room.dispose(state) end
    state.plan = nil
    state.route = nil
    state.room = nil
    state.firstMismatch = nil
    state.loggedMismatch = nil
    state.diagnostics = {}
    state.reason = "not-started"
end

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

local function selectedPostboss(plan, gameName)
    local selected = plan and plan.selectedOccurrenceIds or {}
    local matches, matchIndex
    for index, id in ipairs(selected) do
        local occurrence = plan.occurrencesById and plan.occurrencesById[id]
        if occurrence and occurrence.resumeBoundary == "postbossEntry"
            and occurrence.gameName == gameName then
            matches = (matches or 0) + 1
            matchIndex = index
        end
    end
    if matches == 1 then
        return plan.occurrencesById[selected[matchIndex]], matchIndex
    end
    return nil, matches or 0
end

-- One fresh-process admission.  The caller supplies the native-room
-- realization bridge so incoming reward realization remains navigation-owned.
-- A state is marked initialized before any read so every result, including a
-- rejected plan or room, is final for this loaded process.
function runtime.attemptPostbossAdmission(state, inbox, activeSlot, nativeRoom, realizeRoom)
    if not runtime.canAttemptPostbossAdmission(state) then return nil end
    processAdmissions[state] = true
    discardTransient(state)
    state.initialized = true

    local loaded, plan = inbox.load(activeSlot)
    if not loaded or type(plan) ~= "table" or plan.kind ~= "ready" then
        local inboxStatus = inbox.status and inbox.status() or nil
        local observed = inboxStatus and inboxStatus.error or plan
        return runtime.mismatch(state, "postboss-admission:active-plan",
            "ready execution plan", observed)
    end

    local current = nativeRoom or (_G.CurrentRun and _G.CurrentRun.CurrentRoom)
    local gameName = roomName(current)
    local occurrence, indexOrCount = selectedPostboss(plan, gameName)
    if occurrence == nil then
        return runtime.mismatch(state, "postboss-admission:room",
            "exactly one selected Postboss entry", {
                gameName = gameName, matches = indexOrCount,
            })
    end

    local verified, mismatch = admission.verify(occurrence, plan.startingLoadout)
    if not verified then
        return runtime.mismatch(state, type(mismatch) == "table" and mismatch
            or "postboss-admission:state", "matching Postboss entry state", mismatch)
    end

    local routeState, routeError = route.newAt(plan, indexOrCount)
    if routeState == nil then
        return runtime.mismatch(state, routeError)
    end
    state.plan = plan
    state.route = routeState
    state.room = room.new(plan, function(errorValue, expected, observed)
        return runtime.mismatch(state, errorValue, expected, observed)
    end, {
        readConformance = function(kind, currentRun, gameState, expected)
            return conformance.read(kind, currentRun, gameState, expected)
        end,
    })
    state.state, state.reason = "synchronized", "ready"

    if room.prepare(state, occurrence) == nil then return nil end
    local realized = type(realizeRoom) == "function"
        and realizeRoom(occurrence, current)
        or room.realize(state, occurrence, _G.game or game, current)
    if realized == nil then
        if state.state == "synchronized" then
            return runtime.mismatch(state, "postboss-admission:room-realization",
                "realized Postboss room", nil)
        end
        return nil
    end
    return { occurrence = occurrence, index = indexOrCount, nativeRoom = realized }
end

function runtime.start(state, inbox, phase, activeSlot)
    processAdmissions[state] = true
    if state.room ~= nil then room.dispose(state) end
    state.initialized = true
    local loaded, plan = inbox.load(activeSlot)
    if not loaded or type(plan) ~= "table" or plan.kind ~= "ready" then
        local inboxStatus = inbox.status and inbox.status() or nil
        local observed = inboxStatus and inboxStatus.error or plan
        return fail(state, "run-start", "ready execution plan", observed)
    end
    for _, occurrence in ipairs(plan.occurrences) do
        for _, fact in ipairs((occurrence.roomExitConformance or {}).facts or {}) do
            if not conformance.supports(fact.kind) then
                return fail(state, "room-exit-conformance", "reachable conformance reader", fact.kind)
            end
        end
    end
    state.plan = plan
    state.route = route.new(plan)
    state.room = room.new(plan, function(errorValue, expected, observed)
        return runtime.mismatch(state, errorValue, expected, observed)
    end, {
        readConformance = function(kind, currentRun, gameState, expected)
            return conformance.read(kind, currentRun, gameState, expected)
        end,
    })
    state.state, state.reason = phase == "starting" and "starting" or "synchronized", "ready"
    return true
end

function runtime.complete(state, handle)
    return room.complete(state, handle)
end

function runtime.automatic(state, effect, phaseKey)
    local current = room.current(state)
    if current == nil then return nil end
    local handle = room.resolve(state, current, { kind = "automatic", effect = effect, phaseKey = phaseKey })
    if handle == nil then return room.incidental(state) end
    local payload = room.begin(state, handle)
    if payload == nil then return nil end
    return runtime.complete(state, handle)
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
