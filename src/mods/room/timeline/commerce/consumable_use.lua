-- Coordinator for the shared UseConsumableItem callback. Anvil and Well Twist
-- semantics remain separate capabilities composed at this native seam.
local anvil = type(import) == "function" and import("mods/room/timeline/commerce/anvil.lua")
    or require("mods.room.timeline.commerce.anvil")
local wellTwist = type(import) == "function"
    and import("mods/room/timeline/commerce/well_twist.lua")
    or require("mods.room.timeline.commerce.well_twist")
local use = {}

function use.attach(module, session, getState, report, room)
    local activeWellTwist
    local anvilScope = anvil.attach(module, session, report)
    wellTwist.attachSelectionHooks(module, session, report, function() return activeWellTwist end)

    module.hooks.wrap("UseConsumableItem", "run-planner-commerce-consumable-use", function(_, runtime, base,
        item, args, user)
        local state = getState(runtime)
        local active = room.current(state)
        local handle = active and room.bound(state, active, item) or nil
        if handle == nil and active and type(item) == "table"
            and item.__runPlannerGenerationKey ~= nil
            and item.__runPlannerTwistResultKey ~= nil then
            handle = room.resolve(state, active, {
                kind = "wellPurchase", generationKey = item.__runPlannerGenerationKey,
            })
            handle = room.bind(state, active, handle, item)
        end
        local payload = handle and room.peek(state, handle) or nil
        local transaction = payload and payload.transaction
        local twistScope = wellTwist.scope(state, handle, transaction)
        local priorTwist = activeWellTwist
        activeWellTwist = twistScope
        local scope = anvilScope.beginUse(state, payload)
        if scope == nil and twistScope == nil then
            activeWellTwist = priorTwist
            return base(item, args, user)
        end
        local ok, result = pcall(base, item, args, user)
        activeWellTwist = priorTwist
        local called = scope and anvilScope.finishUse(scope) or false
        if not ok then error(result, 0) end
        if called then session.complete(state, handle) end
        if twistScope and twistScope.awarded and result ~= false then session.complete(state, handle) end
        report(runtime)
        return result
    end)
end

return use
