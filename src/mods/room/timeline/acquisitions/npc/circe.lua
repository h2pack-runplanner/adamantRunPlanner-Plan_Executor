-- Circe's three stateful traits keep their native mutation functions.  This
-- adapter scopes only the native random selectors to the exact selected-option
-- result carried by the shared NPC acquisition contact.
local circe = {}

local function resolution(scope)
    return scope and scope.selectedOption and scope.selectedOption.circeResolution or nil
end

local function identity(value)
    if type(value) == "table" then return value.MetaUpgradeName end
    return value
end

local function contains(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then return true end
    end
    return false
end

function circe.attach(module, session, report, npcScope)
    local pendingArcana
    local selectorScope

    local function mismatch(scope, expected, observed)
        if scope.failed then return end
        scope.failed = true
        session.mismatch(scope.shared.state, "circe-consequence-selection", expected, observed)
    end

    local function scopedSelector(scope, callback)
        local prior = selectorScope
        selectorScope = scope
        local ok, result = pcall(callback)
        selectorScope = prior
        if not ok then error(result, 0) end
        if not scope.failed and scope.index <= #scope.targets then
            mismatch(scope, scope.targets[scope.index], "missing native selection")
        end
        return result
    end

    local function consequence(kind)
        local shared = npcScope.current("Circe")
        local expected = resolution(shared)
        if expected == nil or expected.kind ~= kind then return nil end
        return {
            shared = shared,
            targets = expected.arcanaKeys or { expected.vowKey },
            index = 1,
            kind = kind,
            admitCastCount = kind == "activateArcana" and
                contains(expected.arcanaKeys, "CastCount"),
        }
    end

    module.hooks.wrap("CirceRandomMetaUpgrade", "run-planner-circe-arcana", function(_, runtime,
        base, args)
        local scope = consequence("activateArcana")
        if scope == nil then return base(args) end
        local prior = pendingArcana
        pendingArcana = scope
        local ok, result = pcall(base, args)
        pendingArcana = prior
        if not ok then error(result, 0) end
        if not scope.contacted then
            mismatch(scope, "AddRandomMetaUpgrades", "missing native contact")
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRandomMetaUpgrades", "run-planner-circe-arcana-native", function(_, _,
        base, count, args)
        local scope = pendingArcana
        if scope == nil then return base(count, args) end
        scope.contacted = true
        return scopedSelector(scope, function() return base(count, args) end)
    end)

    module.hooks.wrap("RandomChance", "run-planner-circe-cast-count-admission", function(_, _,
        base, chance, ...)
        local scope = selectorScope
        if scope == nil or scope.castCountAdmissionConsumed or scope.selectionStarted then
            return base(chance, ...)
        end
        -- CastCount is the sole source-declared RandomDrawChance card.  The
        -- planner models it as a supported outcome; admit that positive branch
        -- only when it is the exact published target.
        if scope.admitCastCount then
            scope.castCountAdmissionConsumed = true
            return true
        end
        return base(chance, ...)
    end)

    module.hooks.wrap("CirceMetaUpgradeRarity", "run-planner-circe-arcana-rarity", function(_, runtime,
        base, args)
        local scope = consequence("promoteArcana")
        if scope == nil then return base(args) end
        local result = scopedSelector(scope, function() return base(args) end)
        report(runtime)
        return result
    end)

    module.hooks.wrap("CirceRemoveShrineUpgrades", "run-planner-circe-fear", function(_, runtime,
        base, args)
        local scope = consequence("disableFear")
        if scope == nil then return base(args) end
        local result = scopedSelector(scope, function() return base(args) end)
        report(runtime)
        return result
    end)

    module.hooks.wrap("RemoveRandomValue", "run-planner-circe-arcana-selection", function(_, _,
        base, values, ...)
        local scope = selectorScope
        if scope == nil or scope.kind == "disableFear" then return base(values, ...) end
        scope.selectionStarted = true
        local expected = scope.targets[scope.index]
        if expected == nil then
            mismatch(scope, "no additional Circe target", "additional native selection")
            return base(values, ...)
        end
        for index, value in ipairs(values or {}) do
            if identity(value) == expected then
                table.remove(values, index)
                scope.index = scope.index + 1
                return value
            end
        end
        mismatch(scope, expected, "missing native candidate")
        return base(values, ...)
    end)

    module.hooks.wrap("GetRandomKey", "run-planner-circe-fear-selection", function(_, _, base,
        values, ...)
        local scope = selectorScope
        if scope == nil or scope.kind ~= "disableFear" then return base(values, ...) end
        local expected = scope.targets[scope.index]
        if expected == nil then
            mismatch(scope, "no additional Circe target", "additional native selection")
            return base(values, ...)
        end
        if type(values) == "table" and values[expected] ~= nil then
            scope.index = scope.index + 1
            return expected
        end
        mismatch(scope, expected, "missing native candidate")
        return base(values, ...)
    end)
end

return circe
