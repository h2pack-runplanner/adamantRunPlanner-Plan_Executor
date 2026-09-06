-- Element outcomes from planner-authored successful resource points.
local resources = {}

local elementsByTool = {
    ToolPickaxe2 = "FireEssence",
    ToolExorcismBook2 = "AirEssence",
    ToolShovel2 = "EarthEssence",
    ToolFishingRod2 = "WaterEssence",
}

function resources.attach(module, session, getState, report, room)
    module.hooks.wrap("GrantElementFromTool", "run-planner-resource", function(_, runtime, base, toolName, args)
        local state = getState(runtime)
        local active = room.current(state)
        local expected
        for _, resource in ipairs(active and active.occurrence.overview.resources or {}) do
            if resource.grantedTraitKey == elementsByTool[toolName] then expected = resource; break end
        end
        local result = base(toolName, args)
        if expected and result ~= expected.grantedTraitKey then
            session.mismatch(state, "resource-element", expected.grantedTraitKey, result)
        end
        report(runtime)
        return result
    end)
end

return resources
