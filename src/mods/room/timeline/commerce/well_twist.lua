-- Stygian Well Twist outcome steering. The shared consumable-use coordinator
-- owns native callback composition and supplies the active Twist scope.
local twist = {}

function twist.scope(state, handle, transaction)
    if transaction == nil or transaction.kind ~= "wellPurchase"
        or transaction.twistResultKey == nil then return nil end
    return {
        state = state,
        handle = handle,
        target = transaction.twistResultKey,
        awarded = false,
        unavailable = false,
    }
end

function twist.attachSelectionHooks(module, session, report, currentScope)
    module.hooks.wrap("AwardRandomStoreItem", "run-planner-well-twist-award", function(_, runtime, base, ...)
        local scope = currentScope()
        local ok, result = pcall(base, ...)
        if not ok then error(result, 0) end
        if scope ~= nil then scope.awarded = result ~= false end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetRandomValue", "run-planner-well-twist-use", function(_, runtime, base, values, args)
        local scope = currentScope()
        if scope ~= nil and type(values) == "table" then
            for _, value in pairs(values) do
                local key = type(value) == "table" and (value.Name or value.ItemName) or value
                if key == scope.target then return value end
            end
            if not scope.unavailable then
                scope.unavailable = true
                session.mismatch(scope.state, "well-twist-result", scope.target, "unavailable")
            end
        end
        report(runtime)
        return base(values, args)
    end)
end

return twist
