-- Native Overview construction/proof.  It reads only the active occurrence;
-- no trace cursor, address grammar, or fallback selection lives here.
local overview = {}
local nativeFacts = type(import) == "function" and import("mods/native_fact_bindings.lua")
    or require("mods/native_fact_bindings")
local overviewBindings = nativeFacts.overview

function overview.isLogicalRoomAcquisition(rewardData)
    return type(rewardData) == "table"
        and overviewBindings.logicalRoomAcquisitions[rewardData.rewardType] == true
end

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

function overview.applyResources(occurrence, room)
    if type(room) ~= "table" or type(occurrence) ~= "table"
        or type(occurrence.overview) ~= "table" then return room end
    local resources = occurrence.overview.resources or {}
    for _, field in pairs(overviewBindings.resourceSuccessFields) do room[field] = false end
    for _, resource in ipairs(resources) do
        local field = overviewBindings.resourceSuccessFields[resource.grantedTraitKey]
        if field ~= nil then room[field] = true end
    end
    return room
end

local function encounterPhases(room)
    if type(room.Encounters) == "table" and #room.Encounters > 0 then return room.Encounters end
    if room.Encounter ~= nil then return { room.Encounter } end
    return {}
end

local function hasObstacle(context, functionName)
    for _, object in pairs(context and context.activeObstacles or {}) do
        if type(object) == "table" and object.OnUsedFunctionName == functionName then return true end
    end
    return false
end

local function featurePresent(binding, room, context)
    if binding.carrier == "roomField" then return room[binding.key] ~= nil end
    if binding.carrier == "obstacleUseFunction" then return hasObstacle(context, binding.key) end
    return false
end

local function hasAdditional(context, expected)
    for _, door in pairs(context and context.offeredExitDoors or {}) do
        local generated = type(door) == "table" and (door.Room or door.RoomData) or nil
        if type(generated) == "table"
            and generated.__runPlannerExecutionAdditionalKind == expected.kind
            and name(generated) == expected.room.gameName then return true end
    end
    return false
end

function overview.prove(occurrence, room, context)
    if type(room) ~= "table" or name(room) ~= occurrence.gameName then
        return nil, { kind = "room", expected = occurrence.gameName, observed = name(room) }
    end
    local expected = occurrence.overview
    local actualReward = reward(room.ChosenRewardType)
    local expectedReward = expected.incomingReward and expected.incomingReward.rewardType or nil
    if not overview.isLogicalRoomAcquisition(expected.incomingReward)
        and actualReward ~= expectedReward then
        return nil, { kind = "incomingReward", expected = expectedReward, observed = actualReward }
    end
    local nativePhases = encounterPhases(room)
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
        if context == nil or type(context.hasObject) ~= "function" or not context.hasObject(object) then
            return nil, { kind = "requiredObject", expected = object }
        end
    end
    local expectedResources = {}
    for _, resource in ipairs(expected.resources or {}) do
        expectedResources[resource.grantedTraitKey] = true
    end
    for traitKey, field in pairs(overviewBindings.resourceSuccessFields) do
        local planned = expectedResources[traitKey] == true
        local observed = room[field] == true
        if planned ~= observed then
            return nil, { kind = "resource", expected = planned and traitKey or false,
                observed = observed and traitKey or false }
        end
    end
    for key, binding in pairs(overviewBindings.features) do
        local present = featurePresent(binding, room, context)
        if (expected[key] ~= nil) ~= present then
            return nil, { kind = "feature", expected = key, observed = present }
        end
    end
    for _, additional in ipairs(expected.additional or {}) do
        if not hasAdditional(context, additional) then
            return nil, { kind = "additional", expected = additional.kind, observed = false }
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
    if expected.incomingReward and not overview.isLogicalRoomAcquisition(expected.incomingReward) then
        result.RewardType = expected.incomingReward.rewardType
        result.ChosenRewardType = nil
        result.ForceLootName = expected.incomingReward.source
    elseif expected.incomingReward == nil then
        result.RewardType = nil
        result.ChosenRewardType = nil
        result.Reward = nil
        result.ForceLootName = nil
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
