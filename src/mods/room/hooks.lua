-- Route/room handshake and current-room lifecycle contacts.
local hooks = {}

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

function hooks.attach(module, session, getState, report, route, room, featureScope, navigation)
    module.hooks.wrap("ChooseStartingRoom", "execution-v10-starting-room", function(_, runtime, base, currentRun,
        args)
        local state = getState(runtime)
        if state == nil then return base(currentRun, args) end
        if state.state ~= "starting" then report(runtime); return base(currentRun, args) end
        local occurrence = route.expected(state.route)
        local gameValue = _G.game or game
        local data = occurrence and room.realize(state, occurrence, gameValue) or nil
        if data ~= nil then data = navigation.realizeIncomingReward(occurrence, data) end
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

    module.hooks.wrap("StartRoom", "execution-v10-room-entry", function(_, runtime, base, currentRun, nativeRoom)
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
                    if type(_G.GetIdsByType) ~= "function" then return false end
                    local ids = _G.GetIdsByType({ Name = key })
                    return type(ids) == "table" and next(ids) ~= nil
                end,
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("LeaveRoom", "execution-v10-room-exit", function(_, runtime, base, currentRun, door)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, door) end
        room.close(state, currentRun, _G.GameState)
        if state.state == "synchronized" then
            local ok, errorValue = route.exit(state.route)
            if not ok then session.mismatch(state, errorValue) end
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
