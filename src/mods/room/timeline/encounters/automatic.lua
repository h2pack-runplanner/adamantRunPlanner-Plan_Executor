-- Encounter-owned automatic outcomes. The planner supplies the exact target;
-- native callbacks remain responsible for applying and reporting the result.
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods.native_timeline_adapters")
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods.chaos")

local automatic = {}

local function heroTraits()
    local hero = _G.CurrentRun and _G.CurrentRun.Hero
    return type(hero) == "table" and hero.Traits or nil
end

local function findTrait(key)
    for _, trait in pairs(heroTraits() or {}) do
        if type(trait) == "table" and (trait.Name == key or trait.TraitName == key) then return trait end
    end
    return nil
end

function automatic.attach(module, session, getState, report, room)
    local embryoTarget
    local embryoContext

    module.hooks.wrap("AddRarityToTraits", "run-planner-steady-growth", function(_, runtime, base, source, args)
        local state = getState(runtime)
        local current = room.current(state)
        local phase = room.activePhase(state, "encounterEnd")
        local handle = phase and room.resolve(state, current,
            { kind = "automatic", effect = "steadyGrowth", phaseKey = phase }) or nil
        local payload = handle and room.begin(state, handle) or nil
        if payload and type(args) == "table" then
            local trait = findTrait(payload.transaction.target)
            if trait then args.ForceUpgrade = { trait } end
        end
        local result = base(source, args)
        if payload then
            session.complete(state, handle, adapter.verifyAutomatic(payload, {
                target = type(result) == "table" and result.Name or nil,
                rarity = type(result) == "table" and result.Rarity or nil,
            }), payload.transaction, result)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRandomChaosBlessing", "run-planner-embryo", function(_, runtime, base, rarity)
        local state = getState(runtime)
        local current = room.current(state)
        local phase = room.activePhase(state, "encounterEnd")
        local handle = phase and room.resolve(state, current,
            { kind = "automatic", effect = "transcendentEmbryo", phaseKey = phase }) or nil
        local payload = handle and room.begin(state, handle) or nil
        embryoTarget = payload and payload.transaction.target or nil
        embryoContext = payload and payload.transaction or nil
        local ok, result = pcall(base, payload and payload.transaction.rarity or rarity)
        embryoTarget = nil
        embryoContext = nil
        if not ok then error(result, 0) end
        if payload then
            session.complete(state, handle, adapter.verifyAutomatic(payload, {
                target = type(result) == "table" and (result.Name or result.TraitName) or result,
                rarity = type(result) == "table" and result.Rarity or nil,
                blessingValues = type(result) == "table"
                    and chaos.blessingValues(result,
                        type(result) == "table" and (result.Name or result.TraitName) or result)
                    or nil,
            }), payload.transaction, result)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetRandomArrayValue", "run-planner-automatic-selection", function(_, _, base, values, rng)
        if embryoTarget and type(values) == "table" then
            for _, value in ipairs(values) do if value == embryoTarget then return value end end
        end
        return base(values, rng)
    end)

    -- Keep the native trait data override available while Embryo's callback is
    -- executing; this is the same scoped value used by its existing carrier.
    module.hooks.wrap("GetProcessedTraitData", "run-planner-embryo-values", function(_, _, base, args)
        local result = base(args)
        if embryoContext == nil or type(args) ~= "table" or type(result) ~= "table"
            or args.TraitName ~= embryoContext.target then return result end
        result.Rarity = embryoContext.rarity
        return chaos.applyBlessing(result, embryoContext.target, embryoContext.blessingValues)
    end)
end

return automatic
