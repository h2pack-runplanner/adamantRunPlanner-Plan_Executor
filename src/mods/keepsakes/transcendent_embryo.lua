-- Transcendent Embryo's automatic blessing result. The encounter lifecycle
-- remains in encounters/automatic.lua; this adapter only scopes the native
-- blessing selector and its processed trait values.
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods.chaos")

local embryo = {}

function embryo.attach(module, session, getState, report, room)
    local embryoTarget
    local embryoContext

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
            local observed = type(result) == "table" and (result.Name or result.TraitName) or result
            if observed ~= payload.transaction.target then
                session.mismatch(state, "transcendent-embryo-target", payload.transaction.target, observed)
            else
                session.complete(state, handle)
            end
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

return embryo
