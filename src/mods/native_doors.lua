-- Native Door checkpoint proof.  The adapter preserves generated physical
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

function doors.prove(occurrence, nativeDoors)
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
        if target.exitKey ~= nil and native.ExitKey ~= target.exitKey then
            return nil, { kind = "exitKey", index = index, expected = target.exitKey,
                observed = native.ExitKey }
        end
        if target.index ~= nil and native.Index ~= nil and native.Index ~= target.index then
            return nil, { kind = "index", index = index, expected = target.index, observed = native.Index }
        end
        local actualReward = rewardName(native.RewardType or native.Reward)
        local expectedReward = target.reward and target.reward.rewardType or nil
        if actualReward ~= expectedReward then
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

-- Replace only the semantic rows.  Existing native-only door fields are
-- retained by index, while route target/reward/provider facts are stamped.
function doors.realize(occurrence, nativeDoors, game)
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
        realized.RewardType = target.reward and target.reward.rewardType or nil
        realized.Room.RewardType = realized.RewardType
        realized.Room.ChosenRewardType = realized.RewardType
        realized.Room.ForceLootName = target.reward and target.reward.source or nil
        if target.reward and target.reward.spurnedSource then
            realized.Room.Encounter = realized.Room.Encounter or {}
            realized.Room.Encounter.LootAName = target.reward.source
            realized.Room.Encounter.LootBName = target.reward.spurnedSource
        end
        realized.ExitKey = target.exitKey
        realized.Index = target.index
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

function doors.bind(occurrence, nativeDoors)
    local bound = {}
    for index, native in ipairs(nativeDoors or {}) do
        bound[native] = occurrence.doors.targets and occurrence.doors.targets[index]
            or occurrence.doors.target
    end
    return bound
end

return doors
