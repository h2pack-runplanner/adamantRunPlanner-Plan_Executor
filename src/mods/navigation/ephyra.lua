-- Native Ephyra Hub and side-door adaptation. The planner owns the complete
-- board; this module only binds that product to native physical doors.
local ephyra = {}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function roomName(value)
    return type(value) == "table" and (value.GenusName or value.Name) or nil
end

local function rewardName(value)
    return type(value) == "table" and (value.RewardType or value.Name or value.Reward) or value
end

function ephyra.hub(plan, nativeRoom)
    if roomName(nativeRoom) ~= "N_Hub" then return nil end
    for _, occurrence in pairs(plan and plan.occurrencesById or {}) do
        local hub = occurrence.overview and occurrence.overview.hub
        if hub and hub.room and hub.room.gameName == "N_Hub" then return hub end
    end
end

function ephyra.hubEntry(occurrence)
    local hub = occurrence and occurrence.overview and occurrence.overview.hub
    return hub and hub.room or nil
end

function ephyra.chooseHubEntry(occurrence, args, game)
    local target = ephyra.hubEntry(occurrence)
    if target == nil or type(args) == "table" and args.ForceNextRoomSet ~= nil then return nil end
    local declaration = game and game.RoomData and game.RoomData[target.gameName] or nil
    if declaration == nil then return nil end
    local result = copy(declaration)
    result.GenusName, result.Name = target.gameName, target.gameName
    return result
end

function ephyra.parentForSide(plan, sideId)
    for _, occurrence in pairs(plan and plan.occurrencesById or {}) do
        for _, slot in ipairs(occurrence.overview and occurrence.overview.localSlots or {}) do
            if slot.room and slot.room.id == sideId then return occurrence end
        end
    end
end

function ephyra.occurrenceForNative(state, routeSession, nativeRoom)
    local plan = state and state.plan
    local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
    if id and plan and plan.occurrencesById[id] then return plan.occurrencesById[id] end
    local current = routeSession.current(state and state.route)
    if current and current.gameName == roomName(nativeRoom) then return current end
    local expected = routeSession.expected(state and state.route)
    if expected and expected.gameName == roomName(nativeRoom) then return expected end
    local last = state and state.route and state.route.lastExitedOccurrence
    local parent = last and ephyra.parentForSide(plan, last.id) or nil
    if parent and parent.gameName == roomName(nativeRoom) then return parent end
end

local function hubWasVisited(hub, route)
    local hubIds = {}
    for _, slot in ipairs(hub.slots or {}) do hubIds[slot.room.id] = true end
    local selected = route and route.plan and route.plan.selectedOccurrenceIds or {}
    for index = 1, math.max(0, (route and route.index or 1) - 1) do
        if hubIds[selected[index]] then return true end
    end
    return false
end

function ephyra.scope(plan, occurrence, nativeRoom, game, route)
    local hub = ephyra.hub(plan, nativeRoom)
    if hub ~= nil and hubWasVisited(hub, route) then return nil end
    local slots = hub and hub.slots or occurrence and occurrence.overview
        and occurrence.overview.localSlots or nil
    if slots == nil then return nil end
    local byDoor = {}
    local plannedDoorIds = {}
    for _, slot in ipairs(slots) do
        plannedDoorIds[slot.physicalDoorId] = true
        if hub ~= nil or slot.generation == "generated" then byDoor[slot.physicalDoorId] = slot end
    end
    local declaredDoorIds = {}
    local declaration = game and game.RoomData and game.RoomData[roomName(nativeRoom)] or nil
    for doorId in pairs(declaration and declaration.PredeterminedDoorRooms or {}) do
        declaredDoorIds[doorId] = true
    end
    return {
        hub = hub,
        slots = slots,
        byDoor = byDoor,
        plannedDoorIds = plannedDoorIds,
        declaredDoorIds = declaredDoorIds,
    }
end

function ephyra.forceSideAvailability(base, currentRun, source, args, slot)
    currentRun.CurrentRoom.UnavailableDoors = currentRun.CurrentRoom.UnavailableDoors or {}
    if slot.generation == "notGenerated" then
        currentRun.CurrentRoom.UnavailableDoors[source.ObjectId] = true
        return nil
    end
    local forcedArgs = {}
    for key, value in pairs(args or {}) do forcedArgs[key] = value end
    forcedArgs.AboveMinAvailableChance = 1
    return base(source, forcedArgs)
end

function ephyra.bindNativeDoors(scope, nativeDoors)
    if scope.hub ~= nil then return end
    for _, door in ipairs(nativeDoors or {}) do
        local slot = scope.byDoor[door.ObjectId]
        if slot ~= nil then
            door.ChooseRoomArgs = copy(door.ChooseRoomArgs or {})
            door.ChooseRoomArgs.RunPlannerEphyraDoorId = door.ObjectId
        end
    end
end

function ephyra.chooseSideRoom(scope, args, game)
    local doorId = type(args) == "table" and args.RunPlannerEphyraDoorId or nil
    local slot = doorId and scope and scope.byDoor[doorId] or nil
    local declaration = slot and game and game.RoomData and game.RoomData[slot.room.gameName] or nil
    if declaration == nil then return nil end
    local result = copy(declaration)
    result.GenusName, result.Name = slot.room.gameName, slot.room.gameName
    result.__runPlannerExecutionRoomId = slot.room.id
    return result
end

function ephyra.prove(scope, nativeDoors)
    local byDoor = {}
    local nonBoardDoors = {}
    for _, door in ipairs(nativeDoors or {}) do
        byDoor[door.ObjectId] = door
        if scope.declaredDoorIds[door.ObjectId] == nil then
            nonBoardDoors[#nonBoardDoors + 1] = door
        end
    end
    for doorId in pairs(scope.declaredDoorIds) do
        if byDoor[doorId] ~= nil and scope.plannedDoorIds[doorId] == nil then
            return nil, {
                kind = "ephyraUnexpectedDoor", doorId = doorId,
                expected = false, observed = true,
            }
        end
    end
    for _, slot in ipairs(scope.slots) do
        local expectedPresent = scope.hub ~= nil or slot.generation == "generated"
        local door = byDoor[slot.physicalDoorId]
        if expectedPresent ~= (door ~= nil) then
            return nil, {
                kind = "ephyraDoorAvailability", doorId = slot.physicalDoorId,
                expected = expectedPresent, observed = door ~= nil,
            }
        end
        if expectedPresent then
            local nativeRoom = door.Room or door.RoomData
            if roomName(nativeRoom) ~= slot.room.gameName then
                return nil, {
                    kind = "ephyraDoorRoom", doorId = slot.physicalDoorId,
                    expected = slot.room.gameName, observed = roomName(nativeRoom),
                }
            end
            local observedReward = rewardName(door.RewardType or door.Reward
                or type(nativeRoom) == "table" and
                    (nativeRoom.ChosenRewardType or nativeRoom.RewardType))
            if observedReward ~= slot.reward.rewardType then
                return nil, {
                    kind = "ephyraDoorReward", doorId = slot.physicalDoorId,
                    expected = slot.reward.rewardType, observed = observedReward,
                }
            end
            if slot.reward.source ~= nil and
                (type(nativeRoom) ~= "table" or nativeRoom.ForceLootName ~= slot.reward.source) then
                return nil, {
                    kind = "ephyraDoorRewardSource", doorId = slot.physicalDoorId,
                    expected = slot.reward.source, observed = nativeRoom.ForceLootName,
                }
            end
        end
    end
    if scope.hub ~= nil then
        if #nonBoardDoors ~= 0 then
            return nil, {
                kind = "ephyraUnexpectedDoor", doorId = nonBoardDoors[1].ObjectId,
                expected = false, observed = true,
            }
        end
    end
    return true
end

function ephyra.proveHubEntry(occurrence, nativeDoors)
    local target = ephyra.hubEntry(occurrence)
    if target == nil then return nil end
    if type(nativeDoors) ~= "table" or #nativeDoors ~= 1 then
        return nil, {
            kind = "ephyraHubEntryCount", expected = 1,
            observed = type(nativeDoors) == "table" and #nativeDoors or nil,
        }
    end
    local door = nativeDoors[1]
    local nativeRoom = door and (door.Room or door.RoomData)
    if roomName(nativeRoom) ~= target.gameName then
        return nil, {
            kind = "ephyraHubEntryRoom", expected = target.gameName,
            observed = roomName(nativeRoom),
        }
    end
    return true
end

function ephyra.finalHandoff(state, routeSession, nativeRoomData)
    local currentRun = _G.CurrentRun
    local hub = ephyra.hub(state and state.plan, currentRun and currentRun.CurrentRoom)
    local expected = routeSession.expected(state and state.route)
    if hub == nil or expected == nil or expected.id ~= hub.finalHandoff.id
        or expected.gameName ~= hub.finalHandoff.gameName
        or roomName(nativeRoomData) ~= expected.gameName then return nil end
    return expected
end

return ephyra
