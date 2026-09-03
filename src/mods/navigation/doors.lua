-- Navigation-owned Door checkpoint proof. The adapter preserves generated physical
-- order and checks only the complete published Doors product.
local doors = {}

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
    return type(value) == "table" and (value.GenusName or value.Name)
end
local function rewardName(value)
    return type(value) == "table" and (value.RewardType or value.Name or value.Reward) or value
end

local function destinationId(door)
    local room = type(door) == "table" and (door.Room or door.RoomData or door) or nil
    return type(door) == "table" and door.__runPlannerExecutionDoorTarget
        or type(room) == "table" and room.__runPlannerExecutionRoomId
end

local function additionalOwner(door)
    local room = type(door) == "table" and (door.Room or door.RoomData) or nil
    return type(door) == "table" and door.__runPlannerExecutionAdditionalOwner
        or type(room) == "table" and room.__runPlannerExecutionAdditionalOwner
end

local function additionalKind(door)
    local room = type(door) == "table" and (door.Room or door.RoomData) or nil
    return type(door) == "table" and door.__runPlannerExecutionAdditionalKind
        or type(room) == "table" and room.__runPlannerExecutionAdditionalKind
end

local function preservesNativeRequiredReward(target, occurrencesById)
    local targetOccurrence = occurrencesById and occurrencesById[target.room.id]
    return type(targetOccurrence) == "table"
        and type(targetOccurrence.overview) == "table"
        and targetOccurrence.overview.effectNeutralRequiredReward == true
end

function doors.prove(occurrence, nativeDoors, occurrencesById)
    local expected = occurrence.doors
    if expected.kind == "terminal" then
        if nativeDoors ~= nil and #nativeDoors ~= 0 then
            return nil, { kind = "terminal", observed = #nativeDoors }
        end
        return true, {}
    end
    local targets = expected.kind == "fixed" and { { room = expected.target } } or expected.targets
    if type(nativeDoors) ~= "table" or #nativeDoors ~= #targets then
        return nil, { kind = "count", expected = #targets,
            observed = type(nativeDoors) == "table" and #nativeDoors or nil }
    end
    if expected.resolvedSharedRewardStoreKey ~= nil and
        nativeDoors.sharedRewardStoreKey ~= expected.resolvedSharedRewardStoreKey then
        return nil, { kind = "sharedRewardStore", expected = expected.resolvedSharedRewardStoreKey,
            observed = nativeDoors.sharedRewardStoreKey }
    end
    for index, target in ipairs(targets) do
        local native = nativeDoors[index]
        local room = native and (native.Room or native.RoomData or native)
        if roomName(room) ~= target.room.gameName then
            return nil, { kind = "target", index = index, expected = target.room.gameName, observed = roomName(room) }
        end
        local actualReward = rewardName(native.RewardType or native.Reward
            or room.ChosenRewardType or room.RewardType or room.Reward)
        local expectedReward = target.reward and target.reward.rewardType or nil
        local preserveNativeReward = preservesNativeRequiredReward(target, occurrencesById)
        if preserveNativeReward and actualReward == nil then
            return nil, { kind = "reward", index = index, expected = "native required reward",
                observed = actualReward }
        elseif not preserveNativeReward and actualReward ~= expectedReward then
            return nil, { kind = "reward", index = index, expected = expectedReward,
                observed = actualReward }
        end
        if target.reward and target.reward.source ~= nil
            and room.ForceLootName ~= target.reward.source then
            return nil, { kind = "rewardSource", index = index,
                expected = target.reward.source, observed = room.ForceLootName }
        end
    end
    return true, nativeDoors
end

function doors.partition(occurrence, nativeDoors)
    local expectedIds = {}
    for _, additional in ipairs(occurrence.overview.additional or {}) do
        expectedIds[additional.room.id] = true
    end
    local normal, additional = {}, {}
    for _, door in ipairs(nativeDoors or {}) do
        if additionalOwner(door) ~= nil or additionalKind(door) ~= nil
            or expectedIds[destinationId(door)] then
            additional[#additional + 1] = door
        else
            normal[#normal + 1] = door
        end
    end
    return normal, additional
end

function doors.proveAdditional(occurrence, nativeDoors)
    local expected = occurrence.overview.additional or {}
    if type(nativeDoors) ~= "table" or #nativeDoors ~= #expected then
        return nil, { kind = "additionalCount", expected = #expected,
            observed = type(nativeDoors) == "table" and #nativeDoors or nil }
    end
    local observedByOwner = {}
    for _, door in ipairs(nativeDoors) do
        local owner = additionalOwner(door)
        if owner == nil or observedByOwner[owner] ~= nil then
            return nil, { kind = "additionalBinding", expected = "unique owner", observed = owner }
        end
        observedByOwner[owner] = door
    end
    for _, row in ipairs(expected) do
        local door = observedByOwner[row.owner]
        local room = type(door) == "table" and (door.Room or door.RoomData) or nil
        local observed = {
            owner = additionalOwner(door), kind = additionalKind(door),
            id = destinationId(door), gameName = roomName(room),
        }
        local wanted = {
            owner = row.owner, kind = row.kind,
            id = row.room.id, gameName = row.room.gameName,
        }
        if observed.owner ~= wanted.owner or observed.kind ~= wanted.kind
            or observed.id ~= wanted.id or observed.gameName ~= wanted.gameName then
            return nil, { kind = "additionalBinding", expected = wanted, observed = observed }
        end
    end
    return true
end

function doors.additional(additional, occurrence, game)
    if additional == nil or occurrence == nil or game == nil or game.RoomData == nil then return nil end
    local declaration = game.RoomData[occurrence.gameName]
    if type(declaration) ~= "table" then return nil end
    local result = copy(declaration)
    result.GenusName, result.Name = occurrence.gameName, occurrence.gameName
    result.__runPlannerExecutionRoomId = occurrence.id
    result.__runPlannerExecutionAdditionalOwner = additional.owner
    result.__runPlannerExecutionAdditionalKind = additional.kind
    return result
end

function doors.bindAdditional(nativeRoom, additional)
    if type(nativeRoom) ~= "table" or type(additional) ~= "table" then return nativeRoom end
    nativeRoom.__runPlannerExecutionAdditionalOwner = additional.owner
    nativeRoom.__runPlannerExecutionAdditionalKind = additional.kind
    return nativeRoom
end

-- Replace only the semantic rows.  Existing native-only door fields are
-- retained by index, while route target/reward/provider facts are stamped.
function doors.realize(occurrence, nativeDoors, game, occurrencesById)
    local expected = occurrence.doors
    if expected.kind == "terminal" then return {} end
    local targets = expected.kind == "fixed" and { { room = expected.target } } or expected.targets
    local rows = {}
    for index, target in ipairs(targets) do
        local row = nativeDoors and nativeDoors[index] or {}
        local realized = copy(row)
        local declaration = game and game.RoomData and game.RoomData[target.room.gameName]
        realized.Room = copy(declaration or { GenusName = target.room.gameName })
        realized.Room.GenusName = target.room.gameName
        realized.Room.Name = target.room.gameName
        realized.Room.__runPlannerExecutionRoomId = target.room.id
        if not preservesNativeRequiredReward(target, occurrencesById) then
            realized.RewardType = target.reward and target.reward.rewardType or nil
            realized.Room.RewardType = realized.RewardType
            realized.Room.ChosenRewardType = nil
            realized.Room.ForceLootName = target.reward and target.reward.source or nil
        end
        if target.reward and target.reward.spurnedSource then
            realized.Room.Encounter = realized.Room.Encounter or {}
            realized.Room.Encounter.LootAName = target.reward.source
            realized.Room.Encounter.LootBName = target.reward.spurnedSource
        end
        realized.__runPlannerExecutionDoorTarget = target.room.id
        rows[index] = realized
    end
    if expected.resolvedSharedRewardStoreKey then rows.sharedRewardStoreKey = expected.resolvedSharedRewardStoreKey end
    return rows
end

function doors.chooseNext(occurrence, game, index)
    local expected = occurrence.doors
    local target = expected.kind == "fixed" and expected.target
        or expected.kind == "batch" and expected.targets[index or 1] and expected.targets[index or 1].room
    if target == nil or game == nil or game.RoomData == nil then return nil end
    local declaration = game.RoomData[target.gameName]
    if type(declaration) ~= "table" then return nil end
    local result = copy(declaration)
    result.GenusName = target.gameName
    result.Name = target.gameName
    result.__runPlannerExecutionRoomId = target.id
    return result
end

return doors
