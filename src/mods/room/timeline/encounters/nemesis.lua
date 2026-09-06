-- Nemesis encounter realization. The planner chooses the event; native text,
-- trade, removal, contest, and reward callbacks remain the carriers.
local nemesis = {}

function nemesis.attach(module, session, getState, report, room)
    local nemesisSpawnDepth = 0
    local pendingNemesis
    local npcRewardSource

    local function interactionHandle(state, source)
        return room.encounterHandle(state, source)
    end

    local function row(state, source)
        local handle = interactionHandle(state, source)
        local payload = handle and room.begin(state, handle) or nil
        local resolution = payload and payload.transaction.resolution
        if resolution and resolution.kind == "nemesisRandomEvent" then
            return handle, payload, resolution.outcome
        end
        return nil
    end

    local function freeItemAvailable(item, itemGameName)
        if type(item) ~= "table" or (item.Name ~= itemGameName and item.ItemName ~= itemGameName) then
            return false
        end
        if item.GameStateRequirements == nil then return true end
        return _G.IsGameStateEligible(item, item.GameStateRequirements) == true
    end

    local function constrainConsumables(consumables, matches)
        local constrained = {}
        for key, value in pairs(consumables) do
            if type(key) ~= "number" then constrained[key] = value end
        end
        for _, item in ipairs(matches) do constrained[#constrained + 1] = item end
        return constrained
    end

    module.hooks.wrap("SpawnNemesisForRandomEvents", "run-planner-nemesis-spawn", function(_, _, base, source, args)
        nemesisSpawnDepth = nemesisSpawnDepth + 1
        local ok, result = pcall(base, source, args)
        nemesisSpawnDepth = nemesisSpawnDepth - 1
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("CheckAvailableTextLines", "run-planner-nemesis-family", function(_, runtime, base, source,
        args)
        if nemesisSpawnDepth == 0 then return base(source, args) end
        local state = getState(runtime)
        local handle, _, outcome = row(state, source)
        local prefixes = {
            freeItem = "NemesisGetFreeItem", goldTrade = "NemesisBuyItem",
            damageTrade = "NemesisTakeDamageForItem", traitTrade = "NemesisGiveTraitForItem",
            damageContest = "NemesisDamageContest",
        }
        local original, prefix = source and source.InteractTextLineSets, outcome and prefixes[outcome.kind]
        if handle == nil or type(original) ~= "table" or prefix == nil then return base(source, args) end
        local filtered = {}
        for key, value in pairs(original) do
            if type(key) == "string" and key:sub(1, #prefix) == prefix then filtered[key] = value end
        end
        if next(filtered) == nil then
            session.mismatch(state, "nemesis-event-family", outcome.kind, nil)
            report(runtime)
            return base(source, args)
        end
        source.InteractTextLineSets = filtered
        local ok, result = pcall(base, source, args)
        source.InteractTextLineSets = original
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("NemesisTradeChoice", "run-planner-nemesis-trade", function(_, runtime, base, source, args,
        screen)
        local state = getState(runtime)
        local handle, payload, outcome = row(state, source)
        if handle and outcome and outcome.kind == "traitTrade" and type(args) == "table" then
            local retained = {}
            for _, option in ipairs(args.GiveOptions or {}) do
                if option.Name == outcome.traitKey or option.TraitName == outcome.traitKey then
                    retained[#retained + 1] = option
                end
            end
            if #retained ~= 1 then session.mismatch(state, "nemesis-trait-trade", outcome.traitKey, nil)
            else args.GiveOptions = retained end
        end
        local result = base(source, args, screen)
        if handle and outcome then
            local accepted = source and source.Accepted == true
            if (outcome.response == "accept") ~= accepted then
                session.mismatch(state, "nemesis-trade-response", outcome.response, accepted)
            elseif outcome.kind == "traitTrade" and accepted then
                pendingNemesis = { handle = handle, payload = payload, traitKey = outcome.traitKey }
            else
                session.complete(state, handle)
            end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("RemoveTrait", "run-planner-nemesis-trait-removal", function(_, runtime, base, unit,
        traitName, args)
        local result = base(unit, traitName, args)
        if pendingNemesis then
            local state, pending = getState(runtime), pendingNemesis
            pendingNemesis = nil
            if traitName ~= pending.traitKey then
                session.mismatch(state, "nemesis-trait-removal", pending.traitKey, traitName)
            else
                session.complete(state, pending.handle)
            end
            report(runtime)
        end
        return result
    end)

    module.hooks.wrap("NemesisDamageContestTimer", "run-planner-nemesis-contest", function(_, runtime, base, source,
        args)
        local priorSource = npcRewardSource
        npcRewardSource = source
        local ok, result = pcall(base, source, args)
        npcRewardSource = priorSource
        if not ok then error(result, 0) end
        local state = getState(runtime)
        local handle, _, outcome = row(state, source)
        if handle and outcome and outcome.kind == "damageContest" then
            local details = source.DamageContestArgs or {}
            local success = type(source.DamageContestAmount) == "number"
                and type(details.DamageGoal) == "number"
                and source.DamageContestAmount >= details.DamageGoal
            if (outcome.result == "success") ~= success then
                session.mismatch(state, "nemesis-damage-contest", outcome.result, success)
            else
                session.complete(state, handle)
            end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("NPCRewardDropPreProcess", "run-planner-nemesis-reward-source", function(_, _runtime,
        base, source, args, line)
        local priorSource = npcRewardSource
        npcRewardSource = source
        local ok, result = pcall(base, source, args, line)
        npcRewardSource = priorSource
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("NPCRewardDropPreProcessArgs", "run-planner-nemesis-reward-options", function(_, runtime,
        base, args, choice, line)
        local state = getState(runtime)
        local source = npcRewardSource or type(args) == "table" and args.Source or nil
        local handle, payload, outcome = row(state, source)
        if handle and outcome and outcome.kind == "freeItem" then
            local matches = {}
            local consumables = type(args) == "table" and type(args.Consumables) == "table"
                and args.Consumables or {}
            for _, item in ipairs(consumables) do
                if freeItemAvailable(item, outcome.itemGameName) then
                    matches[#matches + 1] = item
                end
            end
            if #matches == 0 then
                session.mismatch(state, "nemesis-free-item", outcome.itemGameName, nil)
            else
                args.Consumables = constrainConsumables(consumables, matches)
                pendingNemesis = { handle = handle, payload = payload, reward = true }
            end
        end
        local result = base(args, choice, line)
        report(runtime)
        return result
    end)

    module.hooks.wrap("NPCRewardDrop", "run-planner-nemesis-reward", function(_, runtime, base, source, args)
        local result = base(source, args)
        local pending = pendingNemesis
        if pending and pending.reward then
            pendingNemesis = nil
            session.complete(getState(runtime), pending.handle)
        end
        report(runtime)
        return result
    end)
end

return nemesis
