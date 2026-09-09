-- Route/room handshake and current-room lifecycle contacts.
local hooks = {}

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

function hooks.attach(module, session, getState, report, route, room, featureScope, navigation, loadoutScope,
    admissionRuntime)
    assert(type(loadoutScope) == "table"
        and type(loadoutScope.synchronizeStartingRoom) == "function",
        "starting-room loadout scope is required")
    module.hooks.wrap("ChooseStartingRoom", "run-planner-starting-room", function(_, runtime, base, currentRun,
        args)
        local state = getState(runtime)
        if state == nil then return base(currentRun, args) end
        if state.state ~= "starting" then report(runtime); return base(currentRun, args) end
        if not loadoutScope.synchronizeStartingRoom(runtime) then
            report(runtime)
            return base(currentRun, args)
        end
        local occurrence = route.expected(state.route)
        if occurrence == nil or room.prepare(state, occurrence) == nil
            or state.state ~= "synchronized" then
            report(runtime)
            return base(currentRun, args)
        end
        local gameValue = _G.game or game
        local data = occurrence and room.realize(state, occurrence, gameValue) or nil
        if data ~= nil then data = navigation.realizeIncomingReward(occurrence, data) end
        if type(data) == "table" then
            local value = (gameValue.CreateRoom or _G.CreateRoom)(data, args)
            report(runtime)
            return value
        end
        report(runtime)
        return base(currentRun, args)
    end)

    module.hooks.wrap("CreateRoom", "run-planner-create-room", function(_, runtime, base, roomData, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(roomData, args) end
        local additional = featureScope and featureScope.currentAdditional()
        local id = type(roomData) == "table" and roomData.__runPlannerExecutionRoomId or nil
        local occurrence = id and state.plan.occurrencesById[id]
            or additional and additional.occurrence
            or navigation.resolveNativeRoom and navigation.resolveNativeRoom(state, roomData)
        if occurrence ~= nil then
            local realized = room.realize(state, occurrence, _G.game or game, roomData)
            if type(realized) == "table" then
                roomData = navigation.realizeIncomingReward(occurrence, realized)
                if additional ~= nil then
                    roomData = navigation.bindAdditionalRoom(roomData, additional.additional)
                end
            end
        end
        local result = base(roomData, args)
        if type(result) == "table" and occurrence ~= nil then
            room.realizeFeatures(state, occurrence, result)
            result.__runPlannerExecutionRoomId = occurrence.id
            local binding = additional and additional.additional or nil
            if binding == nil and type(roomData) == "table"
                and roomData.__runPlannerExecutionAdditionalOwner ~= nil then
                binding = {
                    owner = roomData.__runPlannerExecutionAdditionalOwner,
                    kind = roomData.__runPlannerExecutionAdditionalKind,
                }
            end
            if binding ~= nil then navigation.bindAdditionalRoom(result, binding) end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("StartRoom", "run-planner-room-entry", function(_, runtime, base, currentRun, nativeRoom)
        local state = getState(runtime)
        if state == nil then return base(currentRun, nativeRoom) end
        local liveRun = type(currentRun) == "table" and currentRun or _G.CurrentRun
        if currentRun == nil then currentRun = liveRun end
        local processFresh = type(session.canAttemptPostbossAdmission) ~= "function"
            or session.canAttemptPostbossAdmission(state)
        if processFresh and type(liveRun) == "table"
            and type(admissionRuntime) == "table"
            and type(admissionRuntime.inbox) == "table"
            and type(admissionRuntime.activePlanSlot) == "function" then
            local originalRoom = nativeRoom or liveRun.CurrentRoom
            local recovered = session.attemptPostbossAdmission(
                state,
                admissionRuntime.inbox,
                admissionRuntime.activePlanSlot(runtime),
                originalRoom,
                function(occurrence, loadedRoom)
                    local data = room.realize(state, occurrence, _G.game or game, loadedRoom)
                    if data ~= nil and navigation.realizeIncomingReward ~= nil then
                        data = navigation.realizeIncomingReward(occurrence, data)
                    end
                    return data
                end
            )
            if recovered ~= nil then
                nativeRoom = recovered.nativeRoom
                if liveRun.CurrentRoom == originalRoom or liveRun.CurrentRoom == nil then
                    liveRun.CurrentRoom = nativeRoom
                end
            end
        end
        if state.state ~= "synchronized" then report(runtime); return base(currentRun, nativeRoom) end
        local expected = route.expected(state.route)
        local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
        if route.enterTransparent and route.enterTransparent(state.route, roomName(nativeRoom)) then
            return base(currentRun, nativeRoom)
        end
        if id == nil and expected and roomName(nativeRoom) == expected.gameName then id = expected.id end
        -- Native room restoration can discard planner-private fields. Once the
        -- route cursor has resolved the exact occurrence by game name, restore
        -- its identity before any native room lifecycle runs. Peripheral hooks
        -- such as auto-harvest then consult the same occurrence through exit.
        if type(nativeRoom) == "table" and id ~= nil then
            nativeRoom.__runPlannerExecutionRoomId = id
        end
        local occurrence, errorValue = route.enter(state.route, id, roomName(nativeRoom))
        if occurrence == true then
            state.state, state.reason = "inactive", "configured-prefix-complete"
            report(runtime)
            return base(currentRun, nativeRoom)
        end
        if occurrence == nil then session.mismatch(state, errorValue) else room.enter(state, occurrence) end
        report(runtime)
        if state.state == "synchronized" then room.bindEntryEncounters(state, nativeRoom) end
        local result = base(currentRun, nativeRoom)
        if state.state == "synchronized" then
            local rewardOk, rewardError = navigation.proveIncomingReward(occurrence, nativeRoom)
            if not rewardOk then session.mismatch(state, rewardError) end
        end
        if state.state == "synchronized" then
            room.proveEntry(state, nativeRoom, {
                activeObstacles = _G.MapState and _G.MapState.ActiveObstacles,
                offeredExitDoors = _G.MapState and _G.MapState.OfferedExitDoors,
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("LeaveRoom", "run-planner-room-exit", function(_, runtime, base, currentRun, door)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, door) end
        local nativeRoomName = roomName(currentRun and currentRun.CurrentRoom)
        if route.leaveTransparent and route.leaveTransparent(state.route, nativeRoomName) then
            return base(currentRun, door)
        end
        local proved, errorValue = navigation.proveOutgoingDoors(state, currentRun)
        if not proved then session.mismatch(state, errorValue) end
        if state.state == "synchronized" then room.close(state, currentRun, _G.GameState) end
        if state.state == "synchronized" then
            local ok, routeError = route.exit(state.route)
            if not ok then session.mismatch(state, routeError) end
        end
        if state.state == "synchronized" and route.expected(state.route) == nil then
            state.reason = "configured-prefix-complete"
        end
        local result = base(currentRun, door)
        report(runtime)
        return result
    end)
end

return hooks
