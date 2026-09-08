-- Stateless native contacts for destination Doors and their rewards.
local doors = type(import) == "function" and import("mods/navigation/doors.lua")
    or require("mods.navigation.doors")
local rewards = type(import) == "function" and import("mods/navigation/rewards.lua")
    or require("mods.navigation.rewards")
local ephyra = type(import) == "function" and import("mods/navigation/ephyra.lua")
    or require("mods.navigation.ephyra")
local hooks = {}

local function orderedDoors(value)
    return _G.CollapseTableOrdered(value or {})
end

local function occurrenceForRoom(state, nativeRoom)
    local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
    return id and state and state.plan and state.plan.occurrencesById[id] or nil
end

local function withForcedAnomaly(base, currentRun, args, otherDoors, anomaly)
    local currentRoom = type(currentRun) == "table" and currentRun.CurrentRoom or nil
    if type(currentRoom) ~= "table" then return nil, false end

    local forcedArgs = {}
    for key, value in pairs(type(args) == "table" and args or {}) do forcedArgs[key] = value end
    forcedArgs.ForceNextRoom = anomaly.replacedRoomGameName

    local priorDoAnomalies = currentRoom.DoAnomalies
    currentRoom.DoAnomalies = true
    local ok, result = pcall(base, currentRun, forcedArgs, otherDoors)
    currentRoom.DoAnomalies = priorDoAnomalies
    if not ok then error(result, 0) end
    return result, true
end

function hooks.attach(module, session, getState, report, routeSession, room, transformationScope)
    local doorScope
    local rewardChoiceScope
    local ephyraDoorScope

    module.hooks.wrap("SetupRoomReward", "run-planner-reward-source", function(_, runtime, base, currentRun,
        nativeRoom, prior, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then
            return base(currentRun, nativeRoom, prior, args)
        end
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

    module.hooks.wrap("IsRoomRewardEligible", "run-planner-room-reward-eligibility", function(_, runtime, base,
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

    module.hooks.wrap("ChooseRoomReward", "run-planner-room-reward", function(_, runtime, base, run, nativeRoom,
        rewardStore, chosen, args)
        if rewardChoiceScope ~= nil then return base(run, nativeRoom, rewardStore, chosen, args) end
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then
            return base(run, nativeRoom, rewardStore, chosen, args)
        end
        local physicalDoorId = type(args) == "table" and type(args.Door) == "table"
            and args.Door.ObjectId or nil
        local ephyraSlot = physicalDoorId and ephyraDoorScope
            and ephyraDoorScope.byDoor[physicalDoorId] or nil
        local pending = transformationScope and transformationScope.consumeRewardSelection(
            run, nativeRoom, rewardStore, chosen, args)
        local occurrence = occurrenceForRoom(state, nativeRoom)
        if occurrence == nil and pending == nil and ephyraSlot == nil then
            return base(run, nativeRoom, rewardStore, chosen, args)
        end
        local expected = ephyraSlot and ephyraSlot.reward
            or pending and pending.transaction and pending.transaction.reward
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

    module.hooks.wrap("AssignRoomToExitDoor", "run-planner-additional-exit-binding", function(_, runtime, base,
        door, nativeRoom)
        local ephyraTarget = type(door) == "table" and ephyraDoorScope
            and ephyraDoorScope.byDoor[door.ObjectId] or nil
        if ephyraTarget ~= nil and type(nativeRoom) == "table" then
            nativeRoom.__runPlannerExecutionRoomId = ephyraTarget.room.id
        end
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

    module.hooks.wrap("ChooseNextRoomData", "run-planner-door-room", function(_, runtime, base, currentRun, args,
        otherDoors)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, args, otherDoors) end
        local gameValue = _G.game or game
        local ephyraSide = ephyra.chooseSideRoom(ephyraDoorScope, args, gameValue)
        if ephyraSide ~= nil then return ephyraSide end
        if type(args) == "table" and args.ForceNextRoomSet == "Chaos" then
            local additional, occurrence = room.additional(state, "chaos")
            local data = doors.additional(additional, occurrence, gameValue)
            if data ~= nil then return rewards.realize(occurrence, data) end
        end
        if doorScope ~= nil and doorScope.rows[doorScope.index] ~= nil then
            local row = doorScope.rows[doorScope.index]
            local occurrence = occurrenceForRoom(state, row.Room)
            local selectingNativeAnomaly = type(args) == "table" and args.ForceNextRoomSet == "Anomaly"
            if occurrence and occurrence.anomaly and not selectingNativeAnomaly then
                local result, usedNativeReplacement = withForcedAnomaly(
                    base, currentRun, args, otherDoors, occurrence.anomaly)
                if usedNativeReplacement then return result end
            end
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

    module.hooks.wrap("DoUnlockRoomExits", "run-planner-doors", function(_, runtime, base, currentRun, nativeRoom)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, nativeRoom) end
        local occurrence = routeSession.current(state.route)
        local expected = occurrence and occurrence.doors
        local ephyraScope = ephyra.scope(state.plan, occurrence, nativeRoom)
        if expected == nil and ephyraScope == nil then return base(currentRun, nativeRoom) end
        local function offeredDoors()
            return orderedDoors(_G.MapState and _G.MapState.OfferedExitDoors or {})
        end
        if ephyraScope ~= nil then
            local nativeDoors = offeredDoors()
            ephyra.bindNativeDoors(ephyraScope, nativeDoors)
            ephyraDoorScope = ephyraScope
            local ok, result = pcall(base, currentRun, nativeRoom)
            ephyraDoorScope = nil
            if not ok then error(result, 0) end
            local proved, errorValue = ephyra.prove(ephyraScope, offeredDoors())
            if not proved then session.mismatch(state, errorValue) end
            if occurrence ~= nil and state.state == "synchronized" then
                room.checkpoint(state, "outgoingGeneration")
                room.window(state, "postOutgoing")
            end
            report(runtime)
            return result
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
        room.checkpoint(state, "outgoingGeneration")
        if state.state == "synchronized" then room.window(state, "postOutgoing") end
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseExitDoor", "run-planner-exit-usable", function(_, runtime, base, door, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(door, args) end
        room.checkpoint(state, "exitUsable")
        report(runtime)
        return base(door, args)
    end)

    module.hooks.wrap("ChooseAvailableN_HubDoors", "run-planner-ephyra-hub-board", function(_, runtime, base, nativeRoom, args)
        local state = getState(runtime)
        local result = base(nativeRoom, args)
        if state == nil or state.state ~= "synchronized" then return result end
        local hub = ephyra.hub(state.plan, nativeRoom)
        if hub == nil or type(nativeRoom) ~= "table" then return result end
        nativeRoom.UnavailableDoors = nativeRoom.UnavailableDoors or {}
        local published = {}
        for _, slot in ipairs(hub.slots or {}) do
            published[slot.physicalDoorId] = true
            nativeRoom.UnavailableDoors[slot.physicalDoorId] = nil
        end
        local data = (_G.game or game).RoomData and (_G.game or game).RoomData[nativeRoom.Name]
        for doorId in pairs(data and data.PredeterminedDoorRooms or {}) do
            if not published[doorId] then nativeRoom.UnavailableDoors[doorId] = true end
        end
        return result
    end)

    module.hooks.wrap("CheckN_SubRoomDoorUnavailable", "run-planner-ephyra-side-board", function(_, runtime, base, source, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(source, args) end
        local currentRun = _G.CurrentRun
        local currentRoom = currentRun and currentRun.CurrentRoom
        local occurrence = ephyra.occurrenceForNative(state, routeSession, currentRoom)
        local slots = occurrence and occurrence.overview and occurrence.overview.localSlots
        local selected
        for _, slot in ipairs(slots or {}) do if slot.physicalDoorId == source.ObjectId then selected = slot end end
        if selected == nil then return base(source, args) end
        if type(currentRoom) ~= "table" then return base(source, args) end
        return ephyra.forceSideAvailability(base, currentRun, source, args, selected)
    end)

    return {
        bindAdditionalRoom = doors.bindAdditional,
        realizeIncomingReward = rewards.realize,
        proveIncomingReward = rewards.prove,
        proveOutgoingDoors = function(state, currentRun)
            local occurrence = routeSession.current(state.route)
            if occurrence == nil or occurrence.doors == nil then return true end
            local offered = orderedDoors(_G.MapState and _G.MapState.OfferedExitDoors or {})
            local normal, additional = doors.partition(occurrence, offered)
            local localScope = ephyra.scope(state.plan, occurrence, currentRun and currentRun.CurrentRoom)
            if localScope ~= nil then
                local proved, errorValue = ephyra.prove(localScope, offered)
                if not proved then return nil, errorValue end
                return doors.proveAdditional(occurrence, additional)
            end
            if ephyra.parentForSide(state.plan, occurrence.id) ~= nil then
                return doors.proveAdditional(occurrence, additional)
            end
            if occurrence.doors.resolvedSharedRewardStoreKey then
                normal.sharedRewardStoreKey = currentRun and currentRun.NextRewardStoreName
            end
            local proved, errorValue = doors.prove(
                occurrence, normal, state.plan.occurrencesById)
            if proved then proved, errorValue = doors.proveAdditional(occurrence, additional) end
            return proved, errorValue
        end,
        resolveNativeRoom = function(state, nativeRoomData)
            return ephyra.finalHandoff(state, routeSession, nativeRoomData)
        end,
    }
end

return hooks
