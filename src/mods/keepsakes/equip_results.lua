-- Native selectors for keepsakes that publish an immediate equip result.
-- Lifecycle ownership stays with loadout/hooks.lua; this module only scopes
-- the native result-producing contacts used by loadout, rack changes, and
-- Echo replay.
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods.chaos")

local equipResults = {}

local function traitKey(value)
    return type(value) == "table" and (value.Name or value.TraitName) or value
end

function equipResults.attach(module, options)
    local scope
    local embryoContext

    local function finishReplay(runtime, kind)
        local active = scope
        if active == nil or not active.defer or active.expected[kind] == nil or active.finished then
            return
        end
        active.contacts[kind] = true
        active.finished = true
        scope = active.prior
        for expectedKind in pairs(active.expected) do
            if not active.contacts[expectedKind] then
                options.mismatch(
                    options.state(runtime),
                    "availability:keepsakeEquipResult",
                    expectedKind,
                    "missing native contact"
                )
            end
        end
        if active.onTerminal ~= nil then active.onTerminal(runtime, kind) end
    end

    local function wrapEquipResult(functionName, hookId, kind)
        module.hooks.wrap(functionName, hookId, function(_, runtime, base, ...)
            if not options.enforcing(runtime) then return base(...) end
            local expected = scope and scope.expected and scope.expected[kind]
            if expected == nil then return base(...) end
            scope.contacts[kind] = true
            local priorKind = scope.kind
            scope.kind = kind
            local ok, result = pcall(base, ...)
            scope.kind = priorKind
            if not ok then error(result, 0) end
            finishReplay(runtime, kind)
            return result
        end)
    end

    wrapEquipResult(options.contacts.experimentalHammer,
        "run-planner-equip-hammer", "experimentalHammer")
    wrapEquipResult(options.contacts.jeweledPom,
        "run-planner-equip-pom", "jeweledPom")
    wrapEquipResult(options.contacts.transcendentEmbryo,
        "run-planner-equip-embryo", "transcendentEmbryo")

    module.hooks.wrap("AddRandomChaosBlessing", "run-planner-equip-embryo-result", function(_, _, base, rarity)
        local expected = scope and scope.expected and scope.expected.transcendentEmbryo
        local prior = embryoContext
        if expected ~= nil then
            embryoContext = {
                target = expected.blessingKey,
                rarity = rarity,
                blessingValues = expected.blessingValues,
            }
        end
        local ok, result = pcall(base, rarity)
        embryoContext = prior
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("GetProcessedTraitData", "run-planner-equip-embryo-values", function(_, _, base, args)
        local result = base(args)
        if type(args) ~= "table" or type(result) ~= "table" or embryoContext == nil then return result end
        if args.TraitName ~= embryoContext.target then return result end
        result.Rarity = embryoContext.rarity
        return chaos.applyBlessing(result, embryoContext.target, embryoContext.blessingValues)
    end)

    module.hooks.wrap("GetRandomArrayValue", "run-planner-equip-selection", function(_, runtime, base, values, rng)
        if not options.enforcing(runtime) then return base(values, rng) end
        local expected = scope and scope.kind and scope.expected[scope.kind]
        local key = expected and (expected.traitKey or expected.blessingKey)
        if key and type(values) == "table" then
            for _, value in ipairs(values) do
                if traitKey(value) == key then return value end
            end
            options.mismatch(options.state(runtime), "availability:traitEligibility", key, "missing candidate")
            return base(values, rng)
        end
        return base(values, rng)
    end)

    return {
        run = function(_, expected, callback, defer, onTerminal)
            local prior = scope
            local active = {
                expected = expected or {},
                contacts = {},
                defer = defer and expected ~= nil,
                onTerminal = onTerminal,
                prior = prior,
            }
            scope = active
            local ok, result = pcall(callback)
            if not ok then
                if scope == active then scope = prior end
                error(result, 0)
            end
            if not active.defer and scope == active then scope = prior end
            return result
        end,
    }
end

return equipResults
