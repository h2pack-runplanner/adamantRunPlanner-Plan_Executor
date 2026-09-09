-- Native resource-point realization and collection contacts. SetupHarvestPoints
-- is the sole owner of physical point presence; GrantElementFromTool is the sole
-- owner of the element outcome reached when that point is harvested.
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local bindings = nativeBindings.roomFeatures
local resources = {}
local familyByTool = {}

for family, binding in pairs(bindings.resourceFamilies) do
    familyByTool[binding.toolName] = family
end

local unpackValues = table.unpack
local function packValues(...)
    return { n = select("#", ...), ... }
end

local function currentPolicy(state, occurrenceId)
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    occurrenceId = occurrenceId
        or type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId
    local rows = state and state.plan and state.plan.resources
        and state.plan.resources.occurrences or nil
    if occurrenceId == nil then return nil end
    for _, row in ipairs(rows or {}) do
        if row.occurrenceId == occurrenceId then return row end
    end
    return nil
end

local function realizePoints(nativeRoom, policy)
    for family, binding in pairs(bindings.resourceFamilies) do
        local disposition = policy.pointDispositions[family]
        if disposition == "force" then nativeRoom[binding.successField] = true
        elseif disposition == "suppress" then nativeRoom[binding.successField] = false end
    end
end

local function stampPoints(nativeRoom)
    local occurrenceId = nativeRoom.__runPlannerExecutionRoomId
    local activeObstacles = _G.MapState and _G.MapState.ActiveObstacles or nil
    if occurrenceId == nil or type(activeObstacles) ~= "table" then return end
    for _, binding in pairs(bindings.resourceFamilies) do
        for _, objectId in ipairs(nativeRoom[binding.choicesField] or {}) do
            local point = activeObstacles[objectId]
            if type(point) == "table" then
                point.__runPlannerResourceOccurrenceId = occurrenceId
            end
        end
    end
end

local function dispositionFor(state, occurrenceId, family)
    local policy = currentPolicy(state, occurrenceId)
    return policy and family and policy.pointDispositions[family] or nil
end

local function scopeFor(disposition)
    if disposition == "force" or disposition == "native" or disposition == "suppress" then
        return { result = disposition == "force", consumed = false }
    end
end

function resources.attach(module, getState, report)
    local active
    local exitContextActive = false
    local exitDisposition

    module.hooks.wrap("SetupHarvestPoints", "run-planner-resource-point-presence", function(_, runtime, base,
        currentRoom, args)
        local state = getState(runtime)
        local policy = state and state.state == "synchronized"
            and currentPolicy(state, type(currentRoom) == "table"
                and currentRoom.__runPlannerExecutionRoomId or nil) or nil
        local ownsRoom = policy ~= nil and type(currentRoom) == "table"
        if ownsRoom then
            realizePoints(currentRoom, policy)
        end
        local result = base(currentRoom, args)
        if ownsRoom then stampPoints(currentRoom) end
        report(runtime)
        return result
    end)

    for family, binding in pairs(bindings.resourceFamilies) do
        local exitFunctionName = binding.exitFunction
        local exitFamily = family
        module.hooks.wrap(exitFunctionName, "run-planner-resource-" .. string.lower(exitFamily) .. "-exit",
            function(_, runtime, base, source, ...)
                local state = getState(runtime)
                local occurrenceId = type(source) == "table"
                    and source.__runPlannerResourceOccurrenceId or nil
                local priorContext = exitContextActive
                local priorDisposition = exitDisposition
                exitContextActive = true
                exitDisposition = occurrenceId ~= nil and state and state.state == "synchronized"
                    and dispositionFor(state, occurrenceId, exitFamily) or nil
                local packed = packValues(pcall(base, source, ...))
                exitContextActive = priorContext
                exitDisposition = priorDisposition
                if not packed[1] then error(packed[2], 0) end
                return unpackValues(packed, 2, packed.n)
            end)
    end

    module.hooks.wrap("GrantElementFromTool", "run-planner-resource-element", function(_, runtime, base,
        toolName, args, ...)
        local state = getState(runtime)
        local family = familyByTool[toolName]
        local disposition = exitDisposition
        if not exitContextActive and state and state.state == "synchronized" then
            disposition = dispositionFor(state, nil, family)
        end
        local prior = active
        local priorExitContext = exitContextActive
        local priorExitDisposition = exitDisposition
        active = scopeFor(disposition)
        exitContextActive = false
        exitDisposition = nil

        local packed = packValues(pcall(base, toolName, args, ...))
        active = prior
        exitContextActive = priorExitContext
        exitDisposition = priorExitDisposition
        local ok = packed[1]
        if not ok then error(packed[2], 0) end
        report(runtime)
        return unpackValues(packed, 2, packed.n)
    end)

    module.hooks.wrap("RandomChance", "run-planner-resource-element-roll", function(_, _, base,
        chance, args, ...)
        if active ~= nil and not active.consumed then
            active.consumed = true
            return active.result
        end
        return base(chance, args, ...)
    end)
end

return resources
