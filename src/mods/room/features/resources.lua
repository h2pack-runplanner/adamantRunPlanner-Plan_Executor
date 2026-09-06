-- Native resource collection contacts. Point realization belongs to the room
-- structure; this adapter only steers the one element roll reached by a native
-- GrantElementFromTool call.
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local bindings = nativeBindings.roomFeatures
local resources = {}
local elementKeys = { "Aether", "Earth", "Air", "Fire", "Water" }

local unpackValues = table.unpack
local function packValues(...)
    return { n = select("#", ...), ... }
end

function resources.elementMismatch(occurrence, policy, currentRun)
    local expected = policy and policy.postExitElementCounts
    if expected == nil then return nil end
    local hero = type(currentRun) == "table" and currentRun.Hero or nil
    local elements = type(hero) == "table" and hero.Elements or nil
    local observed = {}
    for _, key in ipairs(elementKeys) do
        observed[key] = type(elements) == "table" and elements[key] or 0
    end
    for _, key in ipairs(elementKeys) do
        if observed[key] ~= expected[key] then
            return {
                kind = "resourceElementCounts",
                checkpoint = "resource-element-counts",
                occurrenceId = occurrence.id,
                element = key,
                expected = expected,
                observed = observed,
            }
        end
    end
    return nil
end

function resources.attach(module, getState, report, route)
    local active

    module.hooks.wrap("GrantElementFromTool", "run-planner-resource-element", function(_, runtime, base,
        toolName, args, ...)
        local state = getState(runtime)
        local policy = state and state.state == "synchronized"
            and type(route.currentResource) == "function" and route.currentResource(state.route) or nil
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
