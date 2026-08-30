-- Gate-B execution session.
--
-- The planner owns the frozen, occurrence-addressed program. This module is a
-- thin compiler/observer: it realizes room copies and physical door peers at
-- their vanilla seams, then records the first mismatch without repairing the
-- run or finding a replacement instruction.

local session = {}
session.CACHE_NAME = "ExecutionSession"
session.BIOME_ROUTE = { F = "Underworld", G = "Underworld" }

local function newState()
    return {
        initialized = false, state = "inactive", reason = "not-started",
        plan = nil, roomsById = {}, currentRoomId = nil, generation = nil,
        firstMismatch = nil, roomObserved = false, rewardObserved = false,
        diagnostics = {}, pendingExit = nil,
    }
end

local function bounded(value)
    local text = value == nil and "none" or tostring(value)
    return #text > 128 and text:sub(1, 125) .. "..." or text
end

local function roomName(room)
    return type(room) == "table" and (room.GenusName or room.Name) or nil
end

local function mismatch(state, checkpoint, expected, observed, beforeApply, disposition, triggeringAgency)
    if state.firstMismatch ~= nil then return end
    state.firstMismatch = {
        checkpoint = checkpoint, expected = expected, observed = observed,
        beforeApply = beforeApply ~= false,
        disposition = disposition or "conformanceDiscrepancy",
        triggeringAgency = triggeringAgency or "game",
    }
    state.state, state.reason = "desynchronized", "first-mismatch"
end

local function expectedRoom(state)
    return state.currentRoomId and state.roomsById[state.currentRoomId] or nil
end

local function copyRoomData(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

local function copyArray(values)
    local copy = {}
    for index, value in ipairs(values or {}) do copy[index] = value end
    return copy
end

local function restoreArray(values, copy)
    for index in pairs(values) do values[index] = nil end
    for index, value in ipairs(copy) do values[index] = value end
end

local function rewardName(value)
    return type(value) == "table" and (value.Name or value.RewardType) or value
end

local function sourceExists(game, source)
    if type(source) ~= "string" then return true end
    return type(game) == "table" and type(game.LootData) == "table" and game.LootData[source] ~= nil
end

local function indexPlan(state, plan)
    state.roomsById = {}
    for _, room in ipairs(plan.rooms or {}) do state.roomsById[room.id] = room end
    state.currentRoomId = plan.rooms[1] and plan.rooms[1].id or nil
end

local function roomIsExpected(state, room)
    local expected = expectedRoom(state)
    if expected == nil then return false end
    local marker = type(room) == "table" and room.__runPlannerExecutionRoomId or nil
    return marker == expected.id and roomName(room) == expected.gameName
end

local function markedRoomData(game, state, expected, metadata)
    if type(game) ~= "table" or type(game.RoomData) ~= "table" then return nil end
    local declaration = game.RoomData[expected.gameName]
    if type(declaration) ~= "table" then return nil end
    local copy = copyRoomData(declaration)
    copy.__runPlannerExecutionRoomId = expected.id
    copy.__runPlannerExecutionPlanFingerprint = state.plan.planFingerprint
    copy.__runPlannerExecutionOwner = expected.owner
    copy.__runPlannerExecutionKind = expected.kind
    if metadata then for key, value in pairs(metadata) do copy[key] = value end end
    if expected.contents then
        copy.__runPlannerExecutionEncounterPhases = expected.contents.encounterPhases
        copy.__runPlannerExecutionRequiredObjects = expected.contents.requiredObjects
        local encounters = {}
        for _, phase in ipairs(expected.contents.encounterPhases or {}) do
            encounters[#encounters + 1] = phase.encounterKey
        end
        if #encounters > 0 then copy.LegalEncounters = encounters end
    end
    return copy
end

function session.newState() return newState() end

function session.startNewRun(state, dependencies)
    if state.initialized then return end
    state.initialized = true
    local currentRun, args = dependencies.currentRun, dependencies.args or {}
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
    if planOrCode.routeKey ~= routeKey or planOrCode.extent.biomeKeys[1] ~= "F" then
        state.reason = "unsupported-extent"; return
    end
    if biomeKey ~= "F" then state.reason = "unsupported-starting-biome"; return end
    state.plan = planOrCode
    indexPlan(state, planOrCode)
    if state.currentRoomId == nil then state.reason = "unsupported-plan"; return end
    state.state, state.reason = "synchronized", "plan-frozen"
end

function session.chooseStartingRoom(state, _currentRun, args, game)
    if state.state ~= "synchronized" then return nil end
    local expected = expectedRoom(state)
    if expected == nil then
        mismatch(state, "starting-room", { kind = "room", key = nil }, { kind = "room", key = nil })
        return nil
    end
    local data = markedRoomData(game, state, expected, { __runPlannerExecutionStartingRoom = true })
    if data == nil then
        mismatch(state, "starting-room", { kind = "room", key = expected.gameName }, { kind = "room", key = nil })
        return nil
    end
    local createRoom = game.CreateRoom or _G.CreateRoom
    if type(createRoom) ~= "function" then
        mismatch(state, "starting-room", { kind = "CreateRoom", key = expected.gameName }, { kind = "CreateRoom", key = nil })
        return nil
    end
    return createRoom(data, args)
end

local function selectedTarget(outgoing)
    if outgoing.kind ~= "batch" then return nil end
    for _, target in ipairs(outgoing.targets) do if target.picked then return target end end
    return nil
end

local function generatedAll(state, outgoing)
    if state.generation == nil or state.generation.owner ~= outgoing.owner then return false end
    for _, target in ipairs(outgoing.targets) do
        if not state.generation.generated[target.index] then return false end
    end
    return true
end

local function generatedTargetContact(state, room)
    local expected = expectedRoom(state)
    if expected == nil or expected.outgoing.kind ~= "batch" or state.generation == nil then return nil end
    if state.generation.owner ~= expected.outgoing.owner then return nil end
    local marker = type(room) == "table" and room.__runPlannerExecutionRoomId or nil
    if marker == nil then return nil end
    for _, target in ipairs(expected.outgoing.targets) do
        if target.room.id == marker and state.generation.generated[target.index] then
            if roomName(room) == target.room.gameName then
                return state.roomsById[target.room.id]
            end
            return nil
        end
    end
    return nil
end

local function currentRoomContact(state, currentRun, room)
    local expected = expectedRoom(state)
    local observed = room or (currentRun and currentRun.CurrentRoom)
    if expected == nil then return false, nil, observed end
    local generated = room ~= nil and generatedTargetContact(state, room) or nil
    if generated ~= nil then return true, generated, observed end
    if type(observed) == "table" and observed.__runPlannerExecutionRoomId ~= nil
        and observed.__runPlannerExecutionRoomId ~= expected.id then
        return false, expected, observed
    end
    return roomIsExpected(state, observed), expected, observed
end

function session.chooseNextRoomData(state, currentRun, _args, otherDoors, game)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local matched, expected, observed = currentRoomContact(state, currentRun)
    if not matched then
        mismatch(state, "outgoing-generation", { kind = "room", key = expected and expected.id },
            { kind = "room", key = roomName(observed) })
        return { kind = "failed" }
    end
    local outgoing = expected.outgoing
    if outgoing.kind ~= "batch" then
        if outgoing.kind ~= "fixed" then return { kind = "passThrough" } end
        local target = state.roomsById[outgoing.target.id]
        local data = target and markedRoomData(game, state, target, { __runPlannerExecutionFixedSuccessor = true }) or nil
        if data == nil then
            mismatch(state, "fixed-generation", { kind = "room", key = outgoing.target.id }, { kind = "room", key = nil })
            return { kind = "failed" }
        end
        return { kind = "handled", roomData = data }
    end
    if type(otherDoors) ~= "table" then
        mismatch(state, "door-generation", { kind = "targets", key = #outgoing.targets }, { kind = "targets", key = nil })
        return { kind = "failed" }
    end
    state.generation = state.generation or { owner = outgoing.owner, generated = {} }
    if state.generation.owner ~= outgoing.owner then
        mismatch(state, "door-generation", { kind = "batch", key = outgoing.owner },
            { kind = "batch", key = state.generation.owner })
        return { kind = "failed" }
    end
    local targetToGenerate
    for _, target in ipairs(outgoing.targets) do
        local door = otherDoors[target.index]
        if door == nil then
            mismatch(state, "door-generation", { kind = "door", key = target.index }, { kind = "door", key = nil })
            return { kind = "failed" }
        end
        if not state.generation.generated[target.index] then
            if target.type ~= "" and door.Name ~= nil and door.Name ~= target.type then
                mismatch(state, "door-generation", { kind = "door", key = target.type }, { kind = "door", key = door.Name })
                return { kind = "failed" }
            end
            targetToGenerate = target
            break
        end
    end
    if targetToGenerate == nil then return { kind = "passThrough" } end
    local targetRoom = state.roomsById[targetToGenerate.room.id]
    local data = targetRoom and markedRoomData(game, state, targetRoom, {
        __runPlannerExecutionBatchOwner = outgoing.owner,
        __runPlannerExecutionExitKey = targetToGenerate.exitKey,
        __runPlannerExecutionExitIndex = targetToGenerate.index,
        __runPlannerExecutionExitType = targetToGenerate.type,
        __runPlannerExecutionPicked = targetToGenerate.picked,
    }) or nil
    if data == nil then
        mismatch(state, "door-generation", { kind = "room", key = targetToGenerate.room.id }, { kind = "room", key = nil })
        return { kind = "failed" }
    end
    state.generation.generated[targetToGenerate.index] = true
    return { kind = "handled", roomData = data }
end

function session.prepareBatchRewardStore(state, currentRun)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local matched, expected, observed = currentRoomContact(state, currentRun)
    if not matched then
        mismatch(state, "reward-store", { kind = "room", key = expected and expected.id },
            { kind = "room", key = roomName(observed) })
        return { kind = "failed" }
    end
    if expected.outgoing.kind ~= "batch" or expected.outgoing.resolvedSharedRewardStoreKey == nil then
        return { kind = "passThrough" }
    end
    currentRun.NextRewardStoreName = expected.outgoing.resolvedSharedRewardStoreKey
    return { kind = "handled" }
end

local function expectedReward(room)
    return room and room.contents and room.contents.incomingReward or nil
end

function session.chooseRoomReward(state, currentRun, room, game, base, rewardStoreName, previouslyChosenRewards, args)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "reward", { kind = "room", key = expected and expected.id }, { kind = "room", key = roomName(observed) })
        return { kind = "failed" }
    end
    local reward = expectedReward(expected)
    if reward == nil then return { kind = "passThrough" } end
    for _, source in ipairs({ reward.source, reward.spurnedSource }) do
        if source ~= nil and not sourceExists(game, source) then
            mismatch(state, "reward-source", { kind = "loot", key = source }, { kind = "loot", key = nil })
            return { kind = "failed" }
        end
    end
    if reward.resolvedStoreKey ~= nil and rewardStoreName ~= reward.resolvedStoreKey then
        mismatch(state, "reward-store", { kind = "rewardStore", key = reward.resolvedStoreKey }, { kind = "rewardStore", key = rewardStoreName })
        return { kind = "failed" }
    end
    local priorities = currentRun and currentRun.RewardPriorities
    local prior = type(priorities) == "table" and copyArray(priorities) or nil
    if prior ~= nil then table.insert(priorities, 1, reward.rewardType) end
    local ok, actual = pcall(base, currentRun, room, rewardStoreName, previouslyChosenRewards, args)
    if prior ~= nil then restoreArray(priorities, prior) end
    if not ok then error(actual, 0) end
    if rewardName(actual) ~= reward.rewardType then
        mismatch(state, "reward-selected", { kind = "reward", key = reward.rewardType }, { kind = "reward", key = rewardName(actual) }, false)
        return { kind = "failed", value = actual }
    end
    if reward.source ~= nil and type(room) == "table" then room.ForceLootName = reward.source end
    if reward.spurnedSource ~= nil and type(room) == "table" and type(room.Encounter) == "table" then
        room.Encounter.LootAName, room.Encounter.LootBName = reward.source, reward.spurnedSource
    end
    state.rewardObserved = true
    return { kind = "handled", value = actual }
end

-- Source selection is a property of the resolved incoming reward, not a
-- second planner decision. Apply it at the game's reward setup seam so the
-- normal Boon/Devotion setup path receives the frozen source pair.
function session.prepareRewardSource(state, currentRun, room)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "reward-source", { kind = "room", key = expected and expected.id },
            { kind = "room", key = roomName(observed) })
        return { kind = "failed" }
    end
    local reward = expectedReward(expected)
    if reward == nil or reward.source == nil then return { kind = "passThrough" } end
    if type(room) == "table" then
        if reward.spurnedSource ~= nil and type(room.Encounter) == "table" then
            room.Encounter.LootAName, room.Encounter.LootBName = reward.source, reward.spurnedSource
        else
            room.ForceLootName = reward.source
        end
    end
    return { kind = "handled" }
end

local function countInRange(value, count)
    if type(value) ~= "table" or type(count) ~= "number" then return false end
    if value.kind == "exact" then return count == value.count end
    return value.kind == "range" and count >= value.min and count <= value.max
end

local function liveCounter(currentRun, field)
    if type(currentRun) ~= "table" then return nil end
    if field == "roomHistoryOrdinal" then
        if type(currentRun.RoomHistory) ~= "table" then return nil end
        return #currentRun.RoomHistory
    end
    local gameFields = {
        biomeDepthCache = "BiomeDepthCache",
        routeEncounterDepth = "EncounterDepth",
    }
    if field == "biomeEncounterDepth" then
        -- StartEncounter treats an absent cache as the baseline depth one.
        return currentRun.BiomeEncounterDepth or 1
    end
    local gameField = gameFields[field]
    return gameField == nil and nil or currentRun[gameField]
end

local function liveBag(currentRun, storeKey)
    if type(currentRun) ~= "table" then return nil end
    if type(currentRun.RewardStores) ~= "table" then return nil end
    local store = currentRun.RewardStores[storeKey]
    if type(store) ~= "table" then return nil end
    return #store
end

function session.observeRunState(state, currentRun, checkpoint)
    if state.state ~= "synchronized" then return false end
    local expected = expectedRoom(state)
    if expected == nil then return false end
    for _, step in ipairs(expected.trace or {}) do
        if step.checkpoint == checkpoint and step.runState ~= nil then
            local diagnostic = step.runState
            for field, expectedValue in pairs(diagnostic.counters) do
                local observed = liveCounter(currentRun, field)
                if observed == nil or observed ~= expectedValue then
                    mismatch(state, checkpoint, { kind = field, key = expectedValue }, { kind = field, key = observed }, false)
                    return false
                end
            end
            for _, bag in ipairs(diagnostic.bags or {}) do
                local observed = liveBag(currentRun, bag.storeKey)
                if observed == nil or not countInRange(bag.remaining, observed) then
                    mismatch(state, checkpoint, { kind = "bag", key = bag.storeKey }, { kind = "bag", key = observed }, false)
                    return false
                end
            end
            state.diagnostics[checkpoint] = true
            return true
        end
    end
    return false
end

function session.observeRoom(state, currentRun, room)
    if state.state ~= "synchronized" then return end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "room-entered", { kind = "room", key = expected and expected.id }, { kind = "room", key = roomName(observed) })
        return
    end
    state.roomObserved, state.rewardObserved, state.generation = true, false, nil
    state.reason = "room-entry-observed"
    session.observeRunState(state, currentRun, "roomEntered")
end

function session.observeBeforeRoomExit(state, currentRun)
    if state.state ~= "synchronized" or state.pendingExit == nil then return false end
    return session.observeRunState(state, currentRun, "beforeRoomExit")
end

function session.observeExit(state, currentRun, door)
    if state.state ~= "synchronized" then return end
    local matched, expected, observed = currentRoomContact(state, currentRun)
    if not matched then
        mismatch(state, "selected-exit", { kind = "room", key = expected and expected.id }, { kind = "room", key = roomName(observed) })
        return
    end
    local outgoing = expected.outgoing
    if outgoing.kind == "terminal" then
        state.pendingExit = { sourceId = expected.id, completed = true }
        return
    end
    local room = type(door) == "table" and door.Room or nil
    local marker = type(room) == "table" and room.__runPlannerExecutionRoomId or nil
    local destination, target
    if outgoing.kind == "batch" then
        target = selectedTarget(outgoing)
        local alternate = nil
        for _, candidate in ipairs(outgoing.targets) do
            if candidate.room.id == marker then alternate = candidate; break end
        end
        local validSelected = target ~= nil and marker == target.room.id
            and generatedAll(state, outgoing)
            and type(room) == "table" and room.__runPlannerExecutionBatchOwner == outgoing.owner
            and (door == nil or door.Name == nil or target.type == "" or door.Name == target.type)
        if not validSelected then
            local disposition = alternate ~= nil and alternate ~= target
                and "playerDivergence" or "conformanceDiscrepancy"
            local agency = alternate ~= nil and alternate ~= target and "player" or "game"
            mismatch(state, "selected-exit", { kind = "exit", key = target and target.exitKey },
                { kind = "exit", key = type(room) == "table" and room.__runPlannerExecutionExitKey or nil }, true, disposition, agency)
            return
        end
        destination = state.roomsById[target.room.id]
    else
        if marker ~= outgoing.target.id then
            mismatch(state, "selected-exit", { kind = "room", key = outgoing.target.id },
                { kind = "room", key = marker or roomName(room) })
            return
        end
        destination = state.roomsById[outgoing.target.id]
    end
    if destination == nil then mismatch(state, "selected-exit", { kind = "room", key = nil }, { kind = "room", key = nil }); return end
    state.pendingExit = { sourceId = expected.id, destinationId = destination.id }
end

function session.commitExit(state)
    if state.state ~= "synchronized" or state.pendingExit == nil then return end
    local pending = state.pendingExit
    state.pendingExit = nil
    if pending.completed then
        state.state, state.reason = "completed", "extent-complete"
        return
    end
    state.currentRoomId = pending.destinationId
    state.generation, state.roomObserved, state.rewardObserved = nil, false, false
end

function session.status(state)
    local mismatchState = state.firstMismatch
    return {
        state = state.state, reason = state.reason, route = state.routeKey or "none",
        planFingerprint = state.plan and state.plan.planFingerprint or "none",
        checkpoint = mismatchState and mismatchState.checkpoint or "none",
        expected = mismatchState and mismatchState.expected or "none",
        observed = mismatchState and mismatchState.observed or "none",
        disposition = mismatchState and mismatchState.disposition or "none",
        triggeringAgency = mismatchState and mismatchState.triggeringAgency or "none",
    }
end

function session.defineCache(moduleRef)
    moduleRef.cache.define({ [session.CACHE_NAME] = { domain = "currentRun", key = "execution-session", factory = newState } })
end

function session.get(runtime)
    return runtime.data.cache.currentRun.get(session.CACHE_NAME)
end

return session
