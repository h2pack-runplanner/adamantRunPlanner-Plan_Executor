-- A frozen Gate-A execution session. The session consumes resolved plan
-- facts, applies only the opening-room contacts, and records the first
-- observed mismatch without searching for a replacement instruction.

local session = {}
session.CACHE_NAME = "ExecutionSession"
session.BIOME_ROUTE = { F = "Underworld" }

local function newState()
    return {
        initialized = false,
        state = "inactive",
        reason = "not-started",
        plan = nil,
        room = nil,
        firstMismatch = nil,
    }
end

local function bounded(value)
    local text = value == nil and "none" or tostring(value)
    return #text > 128 and text:sub(1, 125) .. "..." or text
end

local function roomName(room)
    return type(room) == "table" and (room.GenusName or room.Name) or nil
end

local function mismatch(
    state,
    checkpoint,
    expected,
    observed,
    beforeApply,
    disposition,
    triggeringAgency
)
    if state.firstMismatch ~= nil then return end
    state.firstMismatch = {
        checkpoint = checkpoint,
        expected = expected,
        observed = observed,
        beforeApply = beforeApply ~= false,
        disposition = disposition or "conformanceDiscrepancy",
        triggeringAgency = triggeringAgency or "game",
    }
    state.state = "desynchronized"
    state.reason = "first-mismatch"
end

local function expectedRoom(state)
    return state.plan and state.plan.rooms and state.plan.rooms[1] or nil
end

local function sameRoom(state, currentRun, room, expected)
    expected = expected or expectedRoom(state)
    local current = room or (currentRun and currentRun.CurrentRoom)
    return expected ~= nil
        and roomName(current) == expected.gameName
        and (type(current) ~= "table"
            or current.RoomSetName == nil
            or current.RoomSetName == expected.biomeKey)
end

local function copyRoomData(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

local function rewardName(value)
    return type(value) == "table" and (value.Name or value.RewardType) or value
end

local function sourceExists(game, source)
    return type(source) ~= "string"
        or (type(game) == "table" and type(game.LootData) == "table" and game.LootData[source] ~= nil)
end

local function copyArray(values)
    local copy = {}
    for index, value in ipairs(values) do copy[index] = value end
    return copy
end

local function restoreArray(values, copy)
    for index in pairs(values) do values[index] = nil end
    for index, value in ipairs(copy) do values[index] = value end
end

function session.newState()
    return newState()
end

function session.startNewRun(state, dependencies)
    if state.initialized then return end
    state.initialized = true
    local currentRun = dependencies.currentRun
    local args = dependencies.args or {}
    if dependencies.enabled == false then state.reason = "module-disabled"; return end
    if currentRun and currentRun.IsDreamRun then state.reason = "dream-run"; return end
    local biomeKey = args.StartingBiome
        or (currentRun and currentRun.CurrentRoom and currentRun.CurrentRoom.RoomSetName)
    local routeKey = session.BIOME_ROUTE[biomeKey]
    if routeKey == nil then state.reason = "unsupported-route"; return end
    state.routeKey = routeKey
    local ok, planOrCode = dependencies.inbox.load()
    if not ok then state.reason = "plan-unavailable:" .. bounded(planOrCode); return end
    if type(planOrCode) ~= "table" or planOrCode.kind ~= "ready" then state.reason = "unsupported-plan"; return end
    if planOrCode.routeKey ~= routeKey or planOrCode.extent.biomeKeys[1] ~= biomeKey then
        state.reason = "unsupported-extent"; return
    end
    state.plan = planOrCode -- never replaced or refreshed during this run
    state.state = "synchronized"
    state.reason = "plan-frozen"
end

function session.observeRoom(state, currentRun, room)
    if state.state ~= "synchronized" then return end
    local expected = state.room == nil and expectedRoom(state) or nil
    if state.room ~= nil then
        if state.rewardObserved ~= true then
            mismatch(
                state,
                "opening-reward",
                { kind = "rewardObserved", key = true },
                { kind = "rewardObserved", key = false }
            )
            return
        end
        local opening = expectedRoom(state)
        local outgoing = opening and opening.outgoing
        local selected = outgoing and outgoing.selectedExitKey
        local target
        if type(outgoing) == "table" and type(outgoing.targets) == "table" then
            for _, candidate in ipairs(outgoing.targets) do
                if candidate.exitKey == selected then
                    target = candidate
                    break
                end
            end
        end
        expected = target and target.room or nil
        if expected == nil then
            mismatch(
                state,
                "next-room",
                { kind = "selectedTarget", key = selected },
                { kind = "room", key = roomName(room) }
            )
            return
        end
        if sameRoom(state, currentRun, room, expected) then
            state.room = room
            state.state = "completed"
            state.reason = "extent-complete"
            return
        end
        mismatch(
            state,
            "next-room",
            { kind = "room", key = expected.gameName },
            { kind = "room", key = roomName(room) },
            true,
            "playerDivergence",
            "player"
        )
        return
    end
    if expected == nil then
        mismatch(state, "room-entered", { kind = "room", key = nil }, { kind = "room", key = roomName(room) })
        return
    end
    if sameRoom(state, currentRun, room) then
        state.room = room
        state.reason = "room-entry-observed"
        return
    end
    mismatch(state, "room-entered", { kind = "room", key = expected.gameName }, { kind = "room", key = roomName(room) })
end

function session.chooseStartingRoom(state, _currentRun, args, game)
    if state.state ~= "synchronized" then return nil end
    local expected = expectedRoom(state)
    if expected == nil or type(game) ~= "table" or type(game.RoomData) ~= "table" then
        mismatch(
            state, "starting-room", { kind = "room", key = expected and expected.gameName },
            { kind = "room", key = nil })
        return nil
    end
    local declaration = game.RoomData[expected.gameName]
    if type(declaration) ~= "table" then
        mismatch(state, "starting-room", { kind = "room", key = expected.gameName }, { kind = "room", key = nil })
        return nil
    end
    local roomData = copyRoomData(declaration)
    roomData.__runPlannerExecutionRoomId = expected.id
    roomData.__runPlannerExecutionPlanFingerprint = state.plan.planFingerprint
    local createRoom = game.CreateRoom or _G.CreateRoom
    if type(createRoom) ~= "function" then
        mismatch(
            state, "starting-room", { kind = "CreateRoom", key = expected.gameName },
            { kind = "CreateRoom", key = nil })
        return nil
    end
    return createRoom(roomData, args)
end

local function expectedReward(state)
    local room = expectedRoom(state)
    return room and room.contents and room.contents.incomingReward or nil
end

function session.chooseRoomReward(
    state,
    currentRun,
    room,
    game,
    base,
    rewardStoreName,
    previouslyChosenRewards,
    args
)
    if state.state ~= "synchronized" or not sameRoom(state, currentRun, room) then
        return { kind = "passThrough" }
    end
    local expected = expectedReward(state)
    if expected == nil then return { kind = "passThrough" } end
    if type(expected.source) == "string" and not sourceExists(game, expected.source) then
        -- A missing live source is a contact mismatch, not a planner fallback.
        mismatch(state, "reward-source", { kind = "loot", key = expected.source }, { kind = "loot", key = nil })
        return { kind = "failed" }
    end
    if type(expected.resolvedStoreKey) == "string" and rewardStoreName ~= expected.resolvedStoreKey then
        mismatch(
            state,
            "reward-store",
            { kind = "rewardStore", key = expected.resolvedStoreKey },
            { kind = "rewardStore", key = rewardStoreName }
        )
        return { kind = "failed" }
    end
    local priorities = type(currentRun) == "table" and currentRun.RewardPriorities or nil
    local priorPriorities = type(priorities) == "table" and copyArray(priorities) or nil
    if priorPriorities ~= nil then table.insert(priorities, 1, expected.rewardType) end
    local ok, actual = pcall(base, currentRun, room, rewardStoreName, previouslyChosenRewards, args)
    if priorPriorities ~= nil then restoreArray(priorities, priorPriorities) end
    if not ok then error(actual, 0) end
    if rewardName(actual) ~= expected.rewardType then
        mismatch(
            state, "reward-selected", { kind = "reward", key = expected.rewardType },
            { kind = "reward", key = rewardName(actual) }, false)
        return { kind = "failed", value = actual }
    end
    if type(expected.source) == "string" and type(room) == "table" then
        room.ForceLootName = expected.source
    end
    state.rewardObserved = true
    return { kind = "handled", value = actual }
end

function session.status(state)
    local mismatchState = state.firstMismatch
    return {
        state = state.state,
        reason = state.reason,
        route = state.routeKey or "none",
        planFingerprint = state.plan and state.plan.planFingerprint or "none",
        checkpoint = mismatchState and mismatchState.checkpoint or "none",
        expected = mismatchState and mismatchState.expected or "none",
        observed = mismatchState and mismatchState.observed or "none",
        disposition = mismatchState and mismatchState.disposition or "none",
        triggeringAgency = mismatchState and mismatchState.triggeringAgency or "none",
    }
end

function session.defineCache(moduleRef)
    moduleRef.cache.define({
        [session.CACHE_NAME] = { domain = "currentRun", key = "execution-session", factory = newState },
    })
end

function session.get(runtime)
    return runtime.data.cache.currentRun.get(session.CACHE_NAME)
end

return session
