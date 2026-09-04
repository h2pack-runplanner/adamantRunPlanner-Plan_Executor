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

    module.hooks.wrap("SpawnNemesisForRandomEvents", "execution-v10-nemesis-spawn", function(_, _, base, source, args)
        nemesisSpawnDepth = nemesisSpawnDepth + 1
        local ok, result = pcall(base, source, args)
        nemesisSpawnDepth = nemesisSpawnDepth - 1
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("CheckAvailableTextLines", "execution-v10-nemesis-family", function(_, runtime, base, source,
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

    module.hooks.wrap("NemesisTradeChoice", "execution-v10-nemesis-trade", function(_, runtime, base, source, args,
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
                session.complete(state, handle, true)
            end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("RemoveTrait", "execution-v10-nemesis-trait-removal", function(_, runtime, base, unit,
        traitName, args)
        local result = base(unit, traitName, args)
        if pendingNemesis then
            local state, pending = getState(runtime), pendingNemesis
            pendingNemesis = nil
            session.complete(state, pending.handle, traitName == pending.traitKey,
                pending.payload.transaction, traitName)
            report(runtime)
        end
        return result
    end)

    module.hooks.wrap("NemesisDamageContestTimer", "execution-v10-nemesis-contest", function(_, runtime, base, source,
        args)
        local priorSource = npcRewardSource
        npcRewardSource = source
        local ok, result = pcall(base, source, args)
        npcRewardSource = priorSource
        if not ok then error(result, 0) end
        local state = getState(runtime)
        local handle, payload, outcome = row(state, source)
        if handle and outcome and outcome.kind == "damageContest" then
            local details = source.DamageContestArgs or {}
            local success = type(source.DamageContestAmount) == "number"
                and type(details.DamageGoal) == "number"
                and source.DamageContestAmount >= details.DamageGoal
            session.complete(state, handle, (outcome.result == "success") == success, payload.transaction, success)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("NPCRewardDropPreProcess", "execution-v10-nemesis-reward-source", function(_, _runtime,
        base, source, args, line)
        local priorSource = npcRewardSource
        npcRewardSource = source
        local ok, result = pcall(base, source, args, line)
        npcRewardSource = priorSource
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("NPCRewardDropPreProcessArgs", "execution-v10-nemesis-reward-options", function(_, runtime,
        base, args, choice, line)
        local state = getState(runtime)
        local source = npcRewardSource or type(args) == "table" and args.Source or nil
        local handle, payload, outcome = row(state, source)
        if handle and outcome and outcome.runtimeFallbacks then
            for _, fallback in ipairs(outcome.runtimeFallbacks) do
                if fallback.availabilityContact == "npcConsumableSelection" then
                    local key, rebound, resolved = session.resolveFallback(state, handle, payload,
                        "npcConsumableSelection", fallback,
                        function(candidate)
                            for _, item in ipairs(args.Consumables or {}) do
                                if item.Name == candidate or item.ItemName == candidate then return true end
                            end
                            return false
                        end)
                    if key == nil then report(runtime); return base(args, choice, line) end
                    handle, payload = rebound, resolved
                    local chosen = {}
                    for _, item in ipairs(args.Consumables or {}) do
                        if item.Name == key or item.ItemName == key then chosen[#chosen + 1] = item end
                    end
                    args.Consumables = chosen
                end
            end
            pendingNemesis = { handle = handle, payload = payload, reward = true }
        end
        local result = base(args, choice, line)
        report(runtime)
        return result
    end)

    module.hooks.wrap("NPCRewardDrop", "execution-v10-nemesis-reward", function(_, runtime, base, source, args)
        local result = base(source, args)
        local pending = pendingNemesis
        if pending and pending.reward then
            pendingNemesis = nil
            local produced = type(args) == "table" and type(args.Consumables) == "table"
                and #args.Consumables > 0
            session.complete(getState(runtime), pending.handle, produced, pending.payload.transaction, args)
        end
        report(runtime)
        return result
    end)
end

return nemesis
