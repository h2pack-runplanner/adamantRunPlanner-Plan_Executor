-- Current-room identity realization and proof. Encounter, feature, reward, and
-- Door facts are delegated to their owning components.
local overview = {}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function name(value)
    return type(value) == "table" and (value.GenusName or value.Name)
end

function overview.realize(occurrence, game, nativeRoom)
    local source = game and game.RoomData and game.RoomData[occurrence.gameName]
    if type(source) ~= "table" then
        return nil, { kind = "roomDeclaration", expected = occurrence.gameName }
    end
    local result = copy(source)
    for key, value in pairs(nativeRoom or {}) do
        if result[key] == nil then result[key] = copy(value) end
    end
    result.__runPlannerExecutionRoomId = occurrence.id
    result.GenusName, result.Name = occurrence.gameName, occurrence.gameName
    if occurrence.biomeKey == "G" then
        result.LockExtraExitsChance, result.LockExtraExits = 0, false
    end
    return result
end

function overview.prove(occurrence, nativeRoom)
    local observed = name(nativeRoom)
    if type(nativeRoom) ~= "table" or observed ~= occurrence.gameName then
        return nil, { kind = "room", expected = occurrence.gameName, observed = observed }
    end
    return true
end

return overview
