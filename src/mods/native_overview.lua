-- Native Overview construction/proof.  It reads only the active occurrence;
-- no trace cursor, address grammar, or fallback selection lives here.
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

local function reward(value)
    if type(value) == "table" then return value.RewardType or value.Name or value.Reward end
    return value
end

local function has(objects, expected)
    for _, object in pairs(objects or {}) do
        if object == expected or (type(object) == "table" and
            (object.Name == expected or object.ObjectId == expected)) then return true end
    end
    return false
end

local resourceFieldByTrait = {
    FireEssence = "PickaxePointSuccess",
    AirEssence = "ExorcismPointSuccess",
    EarthEssence = "ShovelPointSuccess",
    WaterEssence = "FishingPointSuccess",
}

function overview.applyResources(occurrence, room)
    local resources = occurrence and occurrence.overview and occurrence.overview.resources
    if resources == nil or type(room) ~= "table" then return room end
    room.PickaxePointSuccess = false
    room.ExorcismPointSuccess = false
    room.ShovelPointSuccess = false
    room.FishingPointSuccess = false
    for _, resource in ipairs(resources) do
        local field = resourceFieldByTrait[resource.grantedTraitKey]
        if field ~= nil then room[field] = true end
    end
    return room
end

function overview.prove(occurrence, room)
    if type(room) ~= "table" or name(room) ~= occurrence.gameName then
        return nil, { kind = "room", expected = occurrence.gameName, observed = name(room) }
    end
    local expected = occurrence.overview
    local actualReward = reward(room.RewardType or room.Reward)
    local expectedReward = expected.incomingReward and expected.incomingReward.rewardType or nil
    if actualReward ~= expectedReward then
        return nil, { kind = "incomingReward", expected = expectedReward, observed = actualReward }
    end
    local nativePhases = room.EncounterPhases or room.Encounters or {}
    if #nativePhases ~= #(expected.encounterPhases or {}) then
        return nil, { kind = "encounterCount", expected = #expected.encounterPhases, observed = #nativePhases }
    end
    for index, phase in ipairs(expected.encounterPhases or {}) do
        local native = nativePhases[index]
        if name(native) ~= phase.encounterKey and native ~= phase.encounterKey then
            return nil, { kind = "encounter", expected = phase.encounterKey, observed = name(native) or native }
        end
    end
    for _, object in ipairs(expected.requiredObjects or {}) do
        if not has(room.ObjectIds or room.Objects, object) then
            return nil, { kind = "requiredObject", expected = object }
        end
    end
    for _, resource in ipairs(expected.resources or {}) do
        local field = resourceFieldByTrait[resource.grantedTraitKey]
        if field ~= nil and room[field] ~= true then
            return nil, { kind = "resource", expected = resource.grantedTraitKey, observed = room[field] }
        end
    end
    local features = {
        stygianWell = room.WellShop, purgingPool = room.PurgingPool,
        keepsakeRack = room.KeepsakeRack, fountain = room.Fountain,
        shop = room.Shop,
    }
    for key, native in pairs(features) do
        if (expected[key] ~= nil) ~= (native ~= nil) then
            return nil, { kind = "feature", expected = key, observed = native ~= nil }
        end
    end
    return true, { gameName = name(room), reward = actualReward }
end

-- Construction is a bounded copy/stamp of the exact declaration selected by
-- the occurrence.  Native-only declaration fields survive untouched.
function overview.realize(occurrence, game, room)
    local source = game and game.RoomData and game.RoomData[occurrence.gameName]
    if type(source) ~= "table" then return nil, { kind = "roomDeclaration", expected = occurrence.gameName } end
    local result = copy(source)
    for key, value in pairs(room or {}) do
        if result[key] == nil then result[key] = copy(value) end
    end
    result.__runPlannerExecutionRoomId = occurrence.id
    result.GenusName, result.Name = occurrence.gameName, occurrence.gameName
    local expected = occurrence.overview
    if expected.incomingReward then
        result.RewardType = expected.incomingReward.rewardType
        result.ForcedRewardSource = expected.incomingReward.source
    else
        result.RewardType = nil
        result.Reward = nil
        result.ForcedRewardSource = nil
    end
    result.EncounterPhases = {}
    for _, phase in ipairs(expected.encounterPhases or {}) do
        result.EncounterPhases[#result.EncounterPhases + 1] = phase.encounterKey
    end
    result.ObjectIds = {}
    for _, object in ipairs(expected.requiredObjects or {}) do result.ObjectIds[#result.ObjectIds + 1] = object end
    local featureFields = { stygianWell = "WellShop", purgingPool = "PurgingPool",
        keepsakeRack = "KeepsakeRack", fountain = "Fountain", shop = "Shop" }
    for fact, field in pairs(featureFields) do
        if expected[fact] ~= nil then result[field] = result[field] or {} else result[field] = nil end
    end
    result.__runPlannerExecutionResources = expected.resources
    result.__runPlannerExecutionAdditional = expected.additional
    overview.applyResources(occurrence, result)
    if occurrence.biomeKey == "G" then
        result.LockExtraExitsChance, result.LockExtraExits = 0, false
    end
    return result
end

function overview.chooseEncounter(occurrence, slotKey)
    for _, phase in ipairs(occurrence.overview.encounterPhases or {}) do
        if phase.slotKey == slotKey then return phase.encounterKey end
    end
    return nil
end

function overview.prepareAdditional(occurrence, native)
    native = native or {}
    native.__runPlannerExecutionAdditional = occurrence.overview.additional or {}
    return native
end

-- Bind only already-published identities.  Feature inventory is deliberately
-- absent: Well/shop rows are bound at their later native construction seam.
function overview.bind(occurrence, room)
    local bindings = { objects = {}, resources = {}, additional = {} }
    local expected = occurrence.overview or {}
    for _, object in ipairs(expected.requiredObjects or {}) do
        bindings.objects[object] = object
    end
    for _, resource in ipairs(expected.resources or {}) do
        bindings.resources[resource.acquisitionRole] = resource
    end
    for _, additional in ipairs(expected.additional or {}) do
        bindings.additional[additional.owner] = additional
    end
    bindings.room = room
    return bindings
end

return overview
