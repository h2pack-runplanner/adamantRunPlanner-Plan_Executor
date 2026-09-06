-- Scoped native Anvil steering. The planner publishes the exact result;
-- native ChaosHammerUpgrade still owns candidate construction and mutation.
local anvil = {}
local json = type(import) == "function" and import("mods/protocol/json.lua")
    or require("mods.protocol.json")

local function name(value)
    return type(value) == "table" and (value.Name or value.ItemName or value.LootName) or value
end

local function matching(values, wanted)
    if wanted == nil or json.isNull(wanted) then return nil end
    for _, value in ipairs(values or {}) do
        if name(value) == wanted then return value end
    end
    return nil
end

local function absent(value)
    local metadata = type(value) == "table" and getmetatable(value) or nil
    return value == nil or json.isNull(value) or metadata and metadata.__json_null == true
end

function anvil.attach(module, session, report)
    local activeUse

    module.hooks.wrap("RemoveRandomValue", "run-planner-anvil-random", function(_, _runtime, base,
        values, args)
        local scope = activeUse
        if scope == nil or type(values) ~= "table" then return base(values, args) end
        local result = scope.result
        local expected
        if scope.stage == 1 then
            if absent(result.removedTraitKey) then
                expected = result.addedTraitKeys[1]
                scope.stage = 3
            else
                expected = result.removedTraitKey
                scope.stage = 2
            end
        elseif scope.stage == 2 then
            expected = result.addedTraitKeys[1]
            scope.stage = 3
        elseif scope.stage == 3 then
            expected = result.addedTraitKeys[2]
            scope.stage = 4
        end
        local selected = expected ~= nil and matching(values, expected) or nil
        if selected ~= nil then return selected end
        session.mismatch(scope.state, "anvil-result", expected, name(values[1]))
        return base(values, args)
    end)

    module.hooks.wrap("ChaosHammerUpgrade", "run-planner-anvil-upgrade", function(_, runtime, base, args)
        local scope = activeUse
        if scope == nil then return base(args) end
        scope.called = true
        local ok, result = pcall(base, args)
        if not ok then error(result, 0) end
        if scope.stage ~= 4 then
            local expected = scope.result.addedTraitKeys[scope.stage == 1 and 1 or 2]
            session.mismatch(scope.state, "anvil-result", expected, "native result omitted")
        end
        report(runtime)
        return result
    end)

    return {
        beginUse = function(state, payload)
            local result = payload and payload.transaction and payload.transaction.anvilResult
            if result == nil then return nil end
            activeUse = {
                state = state, result = result, stage = 1, called = false,
            }
            return activeUse
        end,
        finishUse = function(scope)
            if activeUse == scope then activeUse = nil end
            if scope ~= nil and not scope.called then
                session.mismatch(scope.state, "anvil-result", "ChaosHammerUpgrade", "native use rejected")
            end
            return scope and scope.called or false
        end,
    }
end

return anvil
