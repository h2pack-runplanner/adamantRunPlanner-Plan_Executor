-- Stateless native contacts for destination Doors and their rewards.
local doors = type(import) == "function" and import("mods/navigation/doors.lua")
    or require("mods.navigation.doors")
local rewards = type(import) == "function" and import("mods/navigation/rewards.lua")
    or require("mods.navigation.rewards")
local hooks = {}

local function orderedDoors(value)
    if type(_G.CollapseTableOrdered) == "function" then return _G.CollapseTableOrdered(value or {}) end
    local result = {}
    for _, door in ipairs(value or {}) do result[#result + 1] = door end
    if #result == 0 then
        for _, door in pairs(value or {}) do result[#result + 1] = door end
    end
    return result
end

local function occurrenceForRoom(state, nativeRoom)
    local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
    return id and state and state.plan and state.plan.occurrencesById[id] or nil
end

local function destinationId(door)
    if type(door) ~= "table" then return nil end
    local nativeRoom = door.Room or door.RoomData
    return door.__runPlannerExecutionDoorTarget
        or type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId
end

function hooks.reportSelection(session, state, routeSession, door)
    local id = destinationId(door)
    if id == nil then return true end
    local ok, errorValue = routeSession.reportDestination(state.route, id)
    if not ok then return session.mismatch(state, errorValue) end
    return true
end

function hooks.attach(module, session, getState, report, routeSession, room, transformationScope)
    local doorScope
    local rewardChoiceScope

    module.hooks.wrap("SetupRoomReward", "execution-v10-reward-source", function(_, runtime, base, currentRun,
        nativeRoom, prior, args)
        local state = getState(runtime)
        local occurrence = occurrenceForRoom(state, nativeRoom)
        local reward = occurrence and occurrence.overview.incomingReward
        local result = base(currentRun, nativeRoom, prior, args)
        if reward and type(nativeRoom) == "table" then
            if reward.source ~= nil then nativeRoom.ForceLootName = reward.source end
            if reward.spurnedSource and type(nativeRoom.Encounter) == "table" then
                nativeRoom.Encounter.LootAName = reward.source
                nativeRoom.Encounter.LootBName = reward.spurnedSource
            end
        end
        return result
    end)

    module.hooks.wrap("IsRoomRewardEligible", "execution-v10-room-reward-eligibility", function(_, runtime, base,
        run, nativeRoom, reward, previouslyChosen, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then
            return base(run, nativeRoom, reward, previouslyChosen, args)
        end
        if rewardChoiceScope ~= nil and type(reward) == "table" then
            return reward.Name == rewardChoiceScope.rewardType
        end
        return base(run, nativeRoom, reward, previouslyChosen, args)
    end)

    module.hooks.wrap("ChooseRoomReward", "execution-v10-room-reward", function(_, runtime, base, run, nativeRoom,
        rewardStore, chosen, args)
        if rewardChoiceScope ~= nil then return base(run, nativeRoom, rewardStore, chosen, args) end
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then
            return base(run, nativeRoom, rewardStore, chosen, args)
        end
        local pending = transformationScope and transformationScope.consumeRewardSelection(
            run, nativeRoom, rewardStore, chosen, args)
        local occurrence = occurrenceForRoom(state, nativeRoom)
        if occurrence == nil and pending == nil then return base(run, nativeRoom, rewardStore, chosen, args) end
        local expected = pending and pending.transaction and pending.transaction.reward
            or occurrence and occurrence.overview.incomingReward
        if expected == nil then
            if occurrence and occurrence.overview.effectNeutralRequiredReward == true then
                return base(run, nativeRoom, rewardStore, chosen, args)
            end
            if type(nativeRoom) == "table" then nativeRoom.ForceLootName = nil end
            return nil
        end
        if rewards.isLogicalRoomAcquisition(expected) then
            return base(run, nativeRoom, rewardStore, chosen, args)
        end
        local resolvedStore = expected.resolvedStoreKey or rewardStore
        if type(nativeRoom) == "table" then nativeRoom.RewardStoreName = resolvedStore end
        rewardChoiceScope = { rewardStoreName = resolvedStore, rewardType = expected.rewardType }
        local ok, result = pcall(base, run, nativeRoom, resolvedStore, chosen, args)
        rewardChoiceScope = nil
        if not ok then error(result, 0) end
        if expected.source ~= nil and type(nativeRoom) == "table" then nativeRoom.ForceLootName = expected.source end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AssignRoomToExitDoor", "execution-v10-additional-exit-binding", function(_, runtime, base,
        door, nativeRoom)
        local result = base(door, nativeRoom)
        if type(door) == "table" and type(nativeRoom) == "table" then
            doors.bindAdditional(door, {
                owner = nativeRoom.__runPlannerExecutionAdditionalOwner,
                kind = nativeRoom.__runPlannerExecutionAdditionalKind,
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("ChooseNextRoomData", "execution-v10-door-room", function(_, runtime, base, currentRun, args,
        otherDoors)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, args, otherDoors) end
        local gameValue = _G.game or game
        if type(args) == "table" and args.ForceNextRoomSet == "Chaos" then
            local additional, occurrence = room.additional(state, "chaos")
            local data = doors.additional(additional, occurrence, gameValue)
            if data ~= nil then return rewards.realize(occurrence, data) end
        end
        if doorScope ~= nil and doorScope.rows[doorScope.index] ~= nil then
            local row = doorScope.rows[doorScope.index]
            doorScope.index = doorScope.index + 1
            return row.Room
        end
        local occurrence = routeSession.current(state.route)
        local expected = occurrence and occurrence.doors
        if expected == nil then return base(currentRun, args, otherDoors) end
        local index = type(args) == "table" and args.RunPlannerExitIndex or nil
        if expected.kind == "fixed" then return doors.chooseNext(occurrence, gameValue, 1) end
        if expected.kind ~= "batch" then return base(currentRun, args, otherDoors) end
        if index == nil then return base(currentRun, args, otherDoors) end
        return doors.chooseNext(occurrence, gameValue, index)
    end)

    module.hooks.wrap("DoUnlockRoomExits", "execution-v10-doors", function(_, runtime, base, currentRun, nativeRoom)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, nativeRoom) end
        local occurrence = routeSession.current(state.route)
        local expected = occurrence and occurrence.doors
        if expected == nil then return base(currentRun, nativeRoom) end
        local function offeredDoors()
            return orderedDoors(_G.MapState and _G.MapState.OfferedExitDoors or {})
        end
        if expected and expected.resolvedSharedRewardStoreKey then
            currentRun.NextRewardStoreName = expected.resolvedSharedRewardStoreKey
        end
        local normal = doors.partition(occurrence, offeredDoors())
        local rows = doors.realize(occurrence, normal, _G.game or game,
            state.plan.occurrencesById) or nil
        if rows ~= nil and expected and expected.kind ~= "terminal" then doorScope = { rows = rows, index = 1 } end
        local ok, result = pcall(base, currentRun, nativeRoom)
        doorScope = nil
        if not ok then error(result, 0) end
        local additional
        normal, additional = doors.partition(occurrence, offeredDoors())
        if expected and expected.resolvedSharedRewardStoreKey then
            normal.sharedRewardStoreKey = currentRun.NextRewardStoreName
        end
        local proved, errorValue = doors.prove(occurrence, normal, state.plan.occurrencesById)
        if proved then proved, errorValue = doors.proveAdditional(occurrence, additional) end
        if not proved then session.mismatch(state, errorValue) else
            room.checkpoint(state, "outgoingGeneration")
            room.window(state, "postOutgoing")
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseExitDoor", "execution-v10-exit-usable", function(_, runtime, base, door, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(door, args) end
        room.checkpoint(state, "exitUsable")
        if state.state == "synchronized" then hooks.reportSelection(session, state, routeSession, door) end
        report(runtime)
        return base(door, args)
    end)

    return {
        bindAdditionalRoom = doors.bindAdditional,
        realizeIncomingReward = rewards.realize,
        proveIncomingReward = rewards.prove,
    }
end

return hooks
