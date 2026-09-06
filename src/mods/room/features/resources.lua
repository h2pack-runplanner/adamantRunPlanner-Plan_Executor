-- Native resource collection contacts. Point realization belongs to the room
-- structure; this adapter only steers the one element roll reached by a native
-- GrantElementFromTool call.
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local bindings = nativeBindings.roomFeatures
local resources = {}

local unpackValues = table.unpack
local function packValues(...)
    return { n = select("#", ...), ... }
end

local function currentPolicy(state)
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local occurrenceId = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId
    local rows = state and state.plan and state.plan.resources
        and state.plan.resources.occurrences or nil
    if occurrenceId == nil then return nil end
    for _, row in ipairs(rows or {}) do
        if row.occurrenceId == occurrenceId then return row end
    end
    return nil
end

function resources.attach(module, getState, report)
    local active

    module.hooks.wrap("GrantElementFromTool", "run-planner-resource-element", function(_, runtime, base,
        toolName, args, ...)
        local state = getState(runtime)
        local policy = state and state.state == "synchronized" and currentPolicy(state) or nil
        local family = bindings.resourceToolFamilies[toolName]
        local disposition = policy and family and policy.pointDispositions[family] or nil
        local prior = active
        if disposition == "force" or disposition == "native" then
            active = { result = disposition == "force", consumed = false }
        else
            active = nil
        end

        local packed = packValues(pcall(base, toolName, args, ...))
        active = prior
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
