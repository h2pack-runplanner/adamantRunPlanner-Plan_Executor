-- Boss lifecycle and its encounter-owned automatic Arcana outcomes.
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods.native_timeline_adapters")

local boss = {}

function boss.attach(module, session, getState, report, room)
    local bossScope
    local arcanaQueue

    module.hooks.wrap("Kill", "run-planner-boss-defeated", function(_, runtime, base, victim, args)
        local state = getState(runtime)
        local current = room.current(state)
        local prior = bossScope
        if victim and victim.IsBoss and current then
            local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
            local nativeEncounter = nativeRoom and nativeRoom.Encounter
            local phase = room.encounterPhase(state, nativeEncounter)
            bossScope = phase and { state = state, current = current, phaseKey = phase.slotKey } or nil
            if bossScope then room.window(state, "bossDefeated:" .. bossScope.phaseKey) end
        end
        local ok, result = pcall(base, victim, args)
        bossScope = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRandomMetaUpgrades", "run-planner-boss-arcana", function(_, runtime, base, count, args)
        if bossScope == nil then return base(count, args) end
        local effect = type(args) == "table" and args.RarityLevel ~= nil
            and "crystalFigurine" or "judgment"
        local handle = room.resolve(bossScope.state, bossScope.current,
            { kind = "automatic", effect = effect, phaseKey = bossScope.phaseKey })
        local payload = handle and room.begin(bossScope.state, handle) or nil
        if payload == nil then return base(count, args) end
        local prior = arcanaQueue
        arcanaQueue = { keys = payload.transaction.arcanaKeys, index = 1 }
        local ok, result = pcall(base, count, args)
        arcanaQueue = prior
        if not ok then error(result, 0) end
        local observed = { arcanaKeys = {}, rarity = payload.transaction.rarity }
        local rarityOrder = _G.TraitRarityData and _G.TraitRarityData.RarityUpgradeOrder or {}
        for _, key in ipairs(payload.transaction.arcanaKeys) do
            local stateEntry = _G.GameState and _G.GameState.MetaUpgradeState
                and _G.GameState.MetaUpgradeState[key]
            local rarity = stateEntry and rarityOrder[stateEntry.RarityLevel or stateEntry.Level or 1]
            if not stateEntry or not stateEntry.Equipped or rarity ~= payload.transaction.rarity
                or not (_G.CurrentRun and _G.CurrentRun.TemporaryMetaUpgrades
                    and _G.CurrentRun.TemporaryMetaUpgrades[key]) then
                observed = { arcanaKeys = {}, rarity = rarity }
                break
            end
            observed.arcanaKeys[#observed.arcanaKeys + 1] = key
        end
        session.complete(bossScope.state, handle, adapter.verifyAutomatic(payload, observed),
            payload.transaction, observed)
        report(runtime)
        return result
    end)

    module.hooks.wrap("RemoveRandomValue", "run-planner-boss-arcana-selection", function(_, _, base, values)
        if arcanaQueue and arcanaQueue.keys[arcanaQueue.index] then
            local key = arcanaQueue.keys[arcanaQueue.index]
            for index, value in ipairs(values or {}) do
                if value == key then
                    table.remove(values, index)
                    arcanaQueue.index = arcanaQueue.index + 1
                    return value
                end
            end
        end
        return base(values)
    end)
end

return boss
