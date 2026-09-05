-- Structural room-feature realization and proof. Native inventories remain
-- feature-owned; purchases and acquired effects remain Timeline-owned.
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local bindings = nativeBindings.roomFeatures
local features = {}

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

function features.realize(occurrence, nativeRoom)
    local expected = occurrence.overview
    local resources = expected.resources or {}
    for _, field in pairs(bindings.resourceSuccessFields) do nativeRoom[field] = false end
    for _, resource in ipairs(resources) do
        local field = bindings.resourceSuccessFields[resource.grantedTraitKey]
        if field ~= nil then nativeRoom[field] = true end
    end
    nativeRoom.__runPlannerExecutionResources = expected.resources
    return nativeRoom
end

function features.prove(occurrence, nativeRoom, context)
    local expected = occurrence.overview
    for _, object in ipairs(expected.requiredObjects or {}) do
        if context == nil or type(context.hasObject) ~= "function" or not context.hasObject(object) then
            return nil, { kind = "requiredObject", expected = object }
        end
    end
    local expectedResources = {}
    for _, resource in ipairs(expected.resources or {}) do
        expectedResources[resource.grantedTraitKey] = true
    end
    for traitKey, field in pairs(bindings.resourceSuccessFields) do
        local planned = expectedResources[traitKey] == true
        local observed = nativeRoom[field] == true
        if planned ~= observed then
            return nil, { kind = "resource", expected = planned and traitKey or false,
                observed = observed and traitKey or false }
        end
    end
    for key, binding in pairs(bindings.features) do
        local present = featurePresent(binding, nativeRoom, context)
        if (expected[key] ~= nil) ~= present then
            return nil, { kind = "feature", expected = key, observed = present }
        end
    end
    return true
end

return features
