-- Room occurrence, Overview, encounter, and Doors native contacts.
local overview = type(import) == "function" and import("mods/native_overview.lua")
    or require("mods/native_overview")
local hooks = {}

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

local function orderedDoors(value)
    if type(_G.CollapseTableOrdered) == "function" then
        return _G.CollapseTableOrdered(value or {})
    end
    local result = {}
    for _, door in ipairs(value or {}) do result[#result + 1] = door end
    if #result == 0 then
        for _, door in pairs(value or {}) do result[#result + 1] = door end
    end
    return result
end

local function chooseForcedEncounter(base, currentRun, nativeRoom, args, declaration)
    if type(currentRun) ~= "table" or declaration == nil then return nil end
    local priorRunForce = currentRun.ForceNextEncounterData
    local priorGlobalForce = _G.ForceNextEncounter
    currentRun.ForceNextEncounterData = declaration
    _G.ForceNextEncounter = nil
    local ok, result = pcall(base, currentRun, nativeRoom, args)
    currentRun.ForceNextEncounterData = priorRunForce
    _G.ForceNextEncounter = priorGlobalForce
    if not ok then error(result, 0) end
    return result
end

function hooks.attach(module, session, getState, report, ensureStarted)
    local secretScope
    local pendingAdditional
    local encounterIndex
    local doorScope
    local rewardChoiceScope

    local function occurrenceForRoom(state, room)
        local id = type(room) == "table" and room.__runPlannerExecutionRoomId or nil
        return id and state.plan and state.plan.occurrencesById[id] or nil
    end

    module.hooks.wrap("ChooseStartingRoom", "execution-v10-starting-room", function(_, runtime, base, currentRun, args)
        local state = getState(runtime)
        if state.state == "inactive" and ensureStarted ~= nil then ensureStarted(runtime, state) end
        if state.loadoutClosed ~= true or state.state ~= "synchronized" then
            report(runtime)
            return base(currentRun, args)
        end
        local gameValue = _G.game or game
        local data = session.realizeStartingRoom(state, gameValue)
        local createRoom = gameValue and (gameValue.CreateRoom or _G.CreateRoom)
        if type(data) == "table" and type(createRoom) == "function" then
            local value = createRoom(data, args)
            report(runtime)
            return value
        end
        report(runtime)
        return base(currentRun, args)
    end)

    module.hooks.wrap("CreateRoom", "execution-v10-create-room", function(_, runtime, base, roomData, args)
        local state = getState(runtime)
        if state.state ~= "synchronized" then return base(roomData, args) end
        local id = type(roomData) == "table" and roomData.__runPlannerExecutionRoomId or nil
        local additional = pendingAdditional
        local additionalOwner = additional and additional.owner
            or type(roomData) == "table" and roomData.__runPlannerExecutionAdditionalOwner
        local additionalKind = additional and additional.kind
            or type(roomData) == "table" and roomData.__runPlannerExecutionAdditionalKind
        if pendingAdditional ~= nil and roomName(roomData) == "C_Boss01" then
            id = pendingAdditional.room.id
        end
        if id ~= nil then
            local realized = session.realizeOccurrence(state, id, _G.game or game, roomData)
            if type(realized) == "table" then roomData = realized end
        end
        local result = base(roomData, args)
        if id ~= nil and type(result) == "table" then
            local occurrence = state.plan and state.plan.occurrencesById[id]
            overview.applyResources(occurrence, result)
        end
        if type(result) == "table" and id ~= nil then
            result.__runPlannerExecutionRoomId = id
            if additionalOwner ~= nil then
                result.__runPlannerExecutionAdditionalOwner = additionalOwner
                result.__runPlannerExecutionAdditionalKind = additionalKind
            end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AssignRoomToExitDoor", "execution-v10-additional-exit-binding", function(_, runtime, base,
        door, room)
        if getState(runtime).state ~= "synchronized" then return base(door, room) end
        local additionalOwner = type(room) == "table" and room.__runPlannerExecutionAdditionalOwner
            or pendingAdditional and pendingAdditional.owner
        local additionalKind = type(room) == "table" and room.__runPlannerExecutionAdditionalKind
            or pendingAdditional and pendingAdditional.kind
        local result = base(door, room)
        if type(door) == "table" and additionalOwner ~= nil then
            door.__runPlannerExecutionAdditionalOwner = additionalOwner
            door.__runPlannerExecutionAdditionalKind = additionalKind
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("StartRoom", "execution-v10-room-entry", function(_, runtime, base, currentRun, nativeRoom)
        local state = getState(runtime)
        local expected = session.expectedOccurrence(state)
        local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
        if id == nil and expected and roomName(nativeRoom) == expected.gameName then id = expected.id end
        session.enter(state, id, roomName(nativeRoom))
        report(runtime)
        local result = base(currentRun, nativeRoom)
        session.proveOverview(state, nativeRoom, {
            activeObstacles = _G.MapState and _G.MapState.ActiveObstacles,
            offeredExitDoors = _G.MapState and _G.MapState.OfferedExitDoors,
            hasObject = function(key)
                if type(_G.GetIdsByType) ~= "function" then return false end
                local ids = _G.GetIdsByType({ Name = key })
                return type(ids) == "table" and next(ids) ~= nil
            end,
        })
        report(runtime)
        return result
    end)

    module.hooks.wrap("HandleSecretSpawns", "execution-v10-room-features", function(_, runtime, base, currentRun)
        local state = getState(runtime)
        if state.state ~= "synchronized" then return base(currentRun) end
        secretScope = session.additionalRoom(state, "chaos", _G.game or game) ~= nil
        local ok, result = pcall(base, currentRun)
        secretScope = nil
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("IsSecretDoorEligible", "execution-v10-chaos-eligibility", function(_, runtime, base, currentRun,
        currentRoom)
        if getState(runtime).state ~= "synchronized" then return base(currentRun, currentRoom) end
        if secretScope ~= nil then return secretScope end
        return base(currentRun, currentRoom)
    end)

    module.hooks.wrap("IsSellTraitShopEligible", "execution-v10-purging-pool-presence", function(_, runtime, base,
        currentRoom)
        local state = getState(runtime)
        if session.current(state) ~= nil then return session.feature(state, "purgingPool") ~= nil end
        return base(currentRoom)
    end)

    module.hooks.wrap("IsWellShopEligible", "execution-v10-well-presence", function(_, runtime, base, currentRun,
        currentRoom)
        local state = getState(runtime)
        if session.current(state) ~= nil then return session.feature(state, "stygianWell") ~= nil end
        return base(currentRun, currentRoom)
    end)

    module.hooks.wrap("SpawnZagContract", "execution-v10-zagreus-contract", function(_, runtime, base, room, args)
        local state = getState(runtime)
        if state.state ~= "synchronized" then return base(room, args) end
        local _, additional = session.additionalRoom(state, "zagreusContract", _G.game or game)
        pendingAdditional = additional
        if type(room) == "table" then room.ZagreusContractSuccess = additional ~= nil end
        local ok, result = pcall(base, room, args)
        pendingAdditional = nil
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SetupRoomMultipleEncountersData", "execution-v10-encounter-assembly", function(_, runtime,
        base, nativeRoom, args)
        if getState(runtime).state ~= "synchronized" then return base(nativeRoom, args) end
        encounterIndex = 0
        local ok, result = pcall(base, nativeRoom, args)
        encounterIndex = nil
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("ChooseEncounter", "execution-v10-encounter-choice", function(_, runtime, base, currentRun,
        nativeRoom, args)
        if getState(runtime).state ~= "synchronized" then return base(currentRun, nativeRoom, args) end
        local declaration
        if encounterIndex ~= nil then
            encounterIndex = encounterIndex + 1
            local current = session.current(getState(runtime))
            local phase = current and current.occurrence.overview.encounterPhases[encounterIndex]
            declaration = phase and (_G.game or game).EncounterData[phase.encounterKey]
        end
        if declaration == nil then
            local state = getState(runtime)
            local occurrence = occurrenceForRoom(state, nativeRoom)
            local phases = occurrence and occurrence.overview.encounterPhases or {}
            if #phases == 1 then
                declaration = (_G.game or game).EncounterData[phases[1].encounterKey]
            end
        end
        if declaration ~= nil then
            return chooseForcedEncounter(base, currentRun, nativeRoom, args, declaration)
        end
        return base(currentRun, nativeRoom, args)
    end)

    module.hooks.wrap("EndEncounterEffects", "execution-v10-encounter-end", function(_, runtime, base, currentRun,
        nativeRoom, encounter)
        local state = getState(runtime)
        local active = session.current(state)
        local observedName = type(encounter) == "table" and (encounter.Name or encounter.EncounterName)
        local phaseKey
        for _, phase in ipairs(active and active.occurrence.overview.encounterPhases or {}) do
            if phase.encounterKey == observedName then phaseKey = phase.slotKey; break end
        end
        if phaseKey then session.window(state, "encounterEnd:" .. phaseKey) end
        local result = base(currentRun, nativeRoom, encounter)
        session.window(state, "afterCombat")
        report(runtime)
        return result
    end)

    module.hooks.wrap("ChooseNextRoomData", "execution-v10-door-room", function(_, runtime, base, currentRun, args,
        otherDoors)
        local state = getState(runtime)
        if state.state ~= "synchronized" then return base(currentRun, args, otherDoors) end
        local gameValue = _G.game or game
        if type(args) == "table" and args.ForceNextRoomSet == "Chaos" then
            local data = session.additionalRoom(state, "chaos", gameValue)
            if data ~= nil then return data end
        end
        if doorScope ~= nil and doorScope.rows[doorScope.index] ~= nil then
            local row = doorScope.rows[doorScope.index]
            doorScope.index = doorScope.index + 1
            return row.Room
        end
        local nativeIndex = type(args) == "table" and args.RunPlannerExitIndex or nil
        local data = session.nextDoorRoom(state, gameValue, nativeIndex)
        if data ~= nil then return data end
        return base(currentRun, args, otherDoors)
    end)

    module.hooks.wrap("IsRoomRewardEligible", "execution-v10-room-reward-eligibility", function(_, runtime, base, run,
        room, reward, previouslyChosen, args)
        if getState(runtime).state ~= "synchronized" then
            return base(run, room, reward, previouslyChosen, args)
        end
        local scope = rewardChoiceScope
        if scope ~= nil and type(reward) == "table" then
            return reward.Name == scope.rewardType
        end
        return base(run, room, reward, previouslyChosen, args)
    end)

    module.hooks.wrap("ChooseRoomReward", "execution-v10-room-reward", function(_, runtime, base, run, room,
        rewardStore, chosen, args)
        -- Native ChooseRoomReward can refill a depleted store recursively.
        -- The outer call owns the published selection and its scoped random
        -- choice; a recursive call must remain native implementation detail.
        if rewardChoiceScope ~= nil then return base(run, room, rewardStore, chosen, args) end
        local state = getState(runtime)
        if state.state ~= "synchronized" then return base(run, room, rewardStore, chosen, args) end
        local pending = session.takeRewardSelection(state)
        local occurrence = occurrenceForRoom(state, room)
        if occurrence == nil and pending == nil then return base(run, room, rewardStore, chosen, args) end
        local expected = pending and pending.node and pending.node.reward
            or occurrence and occurrence.overview.incomingReward
        if expected == nil then
            if occurrence and occurrence.overview.effectNeutralRequiredReward == true then
                return base(run, room, rewardStore, chosen, args)
            end
            room.ForceLootName = nil
            return nil
        end
        if overview.isLogicalRoomAcquisition(expected) then
            return base(run, room, rewardStore, chosen, args)
        end
        local resolvedStore = expected.resolvedStoreKey or rewardStore
        room.RewardStoreName = resolvedStore
        local prior = rewardChoiceScope
        rewardChoiceScope = {
            run = run,
            rewardStoreName = resolvedStore,
            rewardType = expected.rewardType,
        }
        local ok, result = pcall(base, run, room, resolvedStore, chosen, args)
        rewardChoiceScope = prior
        local observed = type(result) == "table" and result.Name or result
        if not ok then error(result, 0) end
        if observed ~= expected.rewardType then
            session.mismatch(state, "room-reward", expected.rewardType, observed)
        end
        if expected.source ~= nil then room.ForceLootName = expected.source end
        report(runtime)
        return result
    end)

    module.hooks.wrap("DoUnlockRoomExits", "execution-v10-doors", function(_, runtime, base, currentRun, nativeRoom)
        local state = getState(runtime)
        local current = session.current(state)
        local expected = current and current.occurrence.doors
        local additionalIds, additionalOwners = {}, {}
        for _, additional in ipairs(current and current.occurrence.overview
            and current.occurrence.overview.additional or {}) do
            additionalIds[additional.room.id] = true
            additionalOwners[additional.owner] = true
        end
        local function normalDoors()
            local normal = {}
            for _, door in ipairs(orderedDoors(_G.MapState and _G.MapState.OfferedExitDoors or {})) do
                local generated = door.Room or door.RoomData
                local generatedId = type(generated) == "table" and generated.__runPlannerExecutionRoomId
                local owner = door.__runPlannerExecutionAdditionalOwner
                    or type(generated) == "table" and generated.__runPlannerExecutionAdditionalOwner
                local isAdditional = generatedId ~= nil and additionalIds[generatedId]
                    or generatedId == nil and owner ~= nil and additionalOwners[owner]
                if not isAdditional then normal[#normal + 1] = door end
            end
            return normal
        end
        if expected and expected.resolvedSharedRewardStoreKey then
            currentRun.NextRewardStoreName = expected.resolvedSharedRewardStoreKey
        end
        local rows = expected and session.realizeDoors(state, normalDoors(), _G.game or game) or nil
        if rows ~= nil and expected and expected.kind ~= "terminal" then
            doorScope = { rows = rows, index = 1 }
        end
        local ok, result = pcall(base, currentRun, nativeRoom)
        doorScope = nil
        if not ok then error(result, 0) end
        local normal = normalDoors()
        if expected and expected.resolvedSharedRewardStoreKey then
            normal.sharedRewardStoreKey = currentRun.NextRewardStoreName
        end
        session.proveDoors(state, normal)
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseExitDoor", "execution-v10-exit-usable", function(_, runtime, base, door, args)
        local state = getState(runtime)
        if session.checkpoint(state, "exitUsable") == nil then
            report(runtime)
            return base(door, args)
        end
        return base(door, args)
    end)

    module.hooks.wrap("LeaveRoom", "execution-v10-room-exit", function(_, runtime, base, currentRun, door)
        local state = getState(runtime)
        if session.exit(state, currentRun, _G.GameState) == nil then
            report(runtime)
            return base(currentRun, door)
        end
        local result = base(currentRun, door)
        report(runtime)
        return result
    end)
end

return hooks
