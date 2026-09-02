-- Room occurrence, Overview, encounter, and Doors native contacts.
local overview = type(import) == "function" and import("mods/native_overview.lua")
    or require("mods/native_overview")
local hooks = {}

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

function hooks.attach(module, session, getState, report, ensureStarted)
    local secretScope = false
    local pendingAdditional
    local encounterIndex
    local doorScope

    module.hooks.wrap("ChooseStartingRoom", "execution-v10-starting-room", function(_, runtime, base, currentRun, args)
        local state = getState(runtime)
        if state.state == "inactive" and ensureStarted ~= nil then ensureStarted(runtime, state) end
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
        local id = type(roomData) == "table" and roomData.__runPlannerExecutionRoomId or nil
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
        if type(result) == "table" and id ~= nil then result.__runPlannerExecutionRoomId = id end
        report(runtime)
        return result
    end)

    module.hooks.wrap("StartRoomPreLoadBinks", "execution-v10-room-entry", function(_, runtime, base, args)
        local state = getState(runtime)
        local nativeRoom = type(args) == "table" and args.Room or nil
        local expected = session.expectedOccurrence(state)
        local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
        if id == nil and expected and roomName(nativeRoom) == expected.gameName then id = expected.id end
        session.enter(state, id, roomName(nativeRoom), nativeRoom)
        report(runtime)
        return base(args)
    end)

    module.hooks.wrap("HandleSecretSpawns", "execution-v10-room-features", function(_, runtime, base, currentRun)
        local state = getState(runtime)
        secretScope = session.additionalRoom(state, "chaos", _G.game or game) ~= nil
        local ok, result = pcall(base, currentRun)
        secretScope = false
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("IsSecretDoorEligible", "execution-v10-chaos-eligibility", function(_, _, base, currentRun,
        currentRoom)
        if secretScope then return true end
        return base(currentRun, currentRoom)
    end)

    module.hooks.wrap("IsWellShopEligible", "execution-v10-well-presence", function(_, runtime, base, currentRun,
        currentRoom)
        local state = getState(runtime)
        if session.current(state) ~= nil then return session.feature(state, "stygianWell") ~= nil end
        return base(currentRun, currentRoom)
    end)

    module.hooks.wrap("SpawnZagContract", "execution-v10-zagreus-contract", function(_, runtime, base, room, args)
        local state = getState(runtime)
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
        encounterIndex = 0
        local ok, result = pcall(base, nativeRoom, args)
        encounterIndex = nil
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("ChooseEncounter", "execution-v10-encounter-choice", function(_, runtime, base, currentRun,
        nativeRoom, args)
        if encounterIndex ~= nil then
            encounterIndex = encounterIndex + 1
            local current = session.current(getState(runtime))
            local phase = current and current.occurrence.overview.encounterPhases[encounterIndex]
            local declaration = phase and (_G.game or game).EncounterData[phase.encounterKey]
            if declaration ~= nil then return declaration end
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

    module.hooks.wrap("ChooseRoomReward", "execution-v10-door-reward", function(_, _runtime, base, run, room,
        rewardStore, chosen, args)
        local target = doorScope and doorScope.targets[room and room.__runPlannerExecutionRoomId]
        if target ~= nil then
            room.ForceLootName = target.reward and target.reward.source or nil
            return target.reward and target.reward.rewardType or nil
        end
        return base(run, room, rewardStore, chosen, args)
    end)

    module.hooks.wrap("DoUnlockRoomExits", "execution-v10-doors", function(_, runtime, base, currentRun, nativeRoom)
        local state = getState(runtime)
        local current = session.current(state)
        local expected = current and current.occurrence.doors
        if expected and expected.resolvedSharedRewardStoreKey then
            currentRun.NextRewardStoreName = expected.resolvedSharedRewardStoreKey
        end
        local offered = _G.MapState and _G.MapState.OfferedExitDoors or {}
        local normal = {}
        for _, door in ipairs(offered) do
            local generated = door.Room or door.RoomData
            if type(generated) ~= "table" or generated.__runPlannerExecutionAdditionalKind == nil then
                normal[#normal + 1] = door
            end
        end
        local rows = expected and session.realizeDoors(state, normal, _G.game or game) or nil
        if rows ~= nil and expected and expected.kind ~= "terminal" then
            local targets = expected.kind == "fixed" and { expected.target } or expected.targets
            local targetsById = {}
            for _, target in ipairs(targets or {}) do targetsById[target.room.id] = target end
            doorScope = { rows = rows, targets = targetsById, index = 1 }
        end
        local ok, result = pcall(base, currentRun, nativeRoom)
        doorScope = nil
        if not ok then error(result, 0) end
        if expected and expected.resolvedSharedRewardStoreKey then
            normal.sharedRewardStoreKey = currentRun.NextRewardStoreName
        end
        session.proveDoors(state, normal)
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseExitDoor", "execution-v10-exit-usable", function(_, runtime, base, door, args)
        local state = getState(runtime)
        if session.checkpoint(state, "exitUsable") == nil then report(runtime); return nil end
        return base(door, args)
    end)

    module.hooks.wrap("LeaveRoom", "execution-v10-room-exit", function(_, runtime, base, currentRun, door)
        local state = getState(runtime)
        if session.exit(state, currentRun, _G.GameState) == nil then report(runtime); return nil end
        local result = base(currentRun, door)
        report(runtime)
        return result
    end)
end

return hooks
