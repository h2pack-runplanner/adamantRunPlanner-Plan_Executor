-- Route/room handshake and current-room lifecycle contacts.
local hooks = {}

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

function hooks.attach(module, session, getState, report, route, room, featureScope, navigation, loadoutScope)
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
            room.realizeFeatures(occurrence, result)
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
        if state == nil or state.state ~= "synchronized" then return base(currentRun, nativeRoom) end
        local expected = route.expected(state.route)
        local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
        if id == nil and expected and roomName(nativeRoom) == expected.gameName then id = expected.id end
        local occurrence, errorValue = route.enter(state.route, id, roomName(nativeRoom))
        if occurrence == true then
            state.state, state.reason = "inactive", "configured-prefix-complete"
            report(runtime)
            return base(currentRun, nativeRoom)
        end
        if occurrence == nil then session.mismatch(state, errorValue) else room.enter(state, occurrence) end
        report(runtime)
        local result = base(currentRun, nativeRoom)
        if state.state == "synchronized" then
            local rewardOk, rewardError = navigation.proveIncomingReward(occurrence, nativeRoom)
            if not rewardOk then session.mismatch(state, rewardError) end
        end
        if state.state == "synchronized" then
            room.proveEntry(state, nativeRoom, {
                activeObstacles = _G.MapState and _G.MapState.ActiveObstacles,
                offeredExitDoors = _G.MapState and _G.MapState.OfferedExitDoors,
                hasObject = function(key)
                    local ids = _G.GetIdsByType({ Name = key })
                    return type(ids) == "table" and next(ids) ~= nil
                end,
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("LeaveRoom", "run-planner-room-exit", function(_, runtime, base, currentRun, door)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, door) end
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
