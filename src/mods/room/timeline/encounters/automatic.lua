-- Encounter-owned automatic outcomes. The planner supplies the exact target;
-- native callbacks remain responsible for applying and reporting the result.
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
            local observed = type(result) == "table" and (result.Name or result.TraitName) or nil
            if observed ~= payload.transaction.target then
                session.mismatch(state, "steady-growth-target", payload.transaction.target, observed)
            else
                session.complete(state, handle)
            end
        end
        report(runtime)
        return result
    end)

    local embryo = type(import) == "function" and import("mods/keepsakes/transcendent_embryo.lua")
        or require("mods.keepsakes.transcendent_embryo")
    embryo.attach(module, session, getState, report, room)
end

return automatic
