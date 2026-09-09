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

function features.prove(occurrence, nativeRoom, context)
    local expected = occurrence.overview
    for key, binding in pairs(bindings.features) do
        local present = featurePresent(binding, nativeRoom, context)
        if (expected[key] ~= nil) ~= present then
            return nil, { kind = "feature", expected = key, observed = present }
        end
    end
    return true
end

return features
