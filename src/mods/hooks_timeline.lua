-- Consequential acquisition, trait, and automatic transaction contacts.
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods/native_timeline_adapters")
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods/chaos")
local hooks = {}

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

local function currentIndex(session, state)
    local current = session.current(state)
    return current and current.bindings or nil
end

local function incomingRow(session, state, native)
    local current = session.current(state)
    if current == nil then return nil end
    local reward = current.occurrence.overview.incomingReward
    if reward == nil then return nil end
    local key = reward.producerLifecycleKey .. "\0" .. reward.rewardType
    local producer = adapter.bind(current.bindings,
        adapter.lookup(current.bindings, "producer", key), native)
    local gameName = type(native) == "table" and (native.Name or native.ItemName or native.LootName) or nil
    local materialized, errorValue = adapter.materialized(current.bindings, producer, gameName, native)
    if errorValue then session.mismatch(state, errorValue.checkpoint, errorValue.expected, errorValue.observed) end
    return materialized or producer
end

local function resolveTraitFallback(session, state, row, native)
    if row == nil or row.node == false then return row end
    for _, fallback in ipairs(row.node.runtimeFallbacks or {}) do
        if fallback.availabilityContact == "traitEligibility" then
            local _, resolved = session.resolveFallback(state, row, "traitEligibility", fallback, function(key)
                local declaration = _G.TraitData and _G.TraitData[key]
                return declaration ~= nil and (type(_G.IsTraitEligible) ~= "function"
                    or _G.IsTraitEligible(declaration) == true)
            end, native)
            if resolved == nil then return nil end
            row = resolved
        end
    end
    return row
end

function hooks.attach(module, session, getState, report)
    local chaosContext
    local pendingTrait
    local pendingLevel
    local embryoTarget
    local bossScope
    local arcanaQueue
    local pendingProduced = {}
    local pendingSeaStar
    local pendingSimple
    local nemesisSpawnDepth = 0
    local pendingNemesis
    local npcRewardSource

    local function interactionRow(state, source)
        local current = session.current(state)
        if current == nil then return nil end
        local room = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local encounter = room and room.Encounter
        local name = type(encounter) == "table" and (encounter.Name or encounter.EncounterName) or nil
        name = name or type(source) == "table" and (source.EncounterName or source.Name) or nil
        for _, phase in ipairs(current.occurrence.overview.encounterPhases or {}) do
            if phase.encounterKey == name then return adapter.phase(current.bindings, phase.slotKey, source) end
        end
        return nil
    end

    local function nemesisRow(state, source)
        local row = interactionRow(state, source)
        local resolution = row and row.node and row.node.resolution
        if resolution and resolution.kind == "nemesisRandomEvent" then return row, resolution.outcome end
        return nil
    end

    local function childFor(state, source, kind)
        local current = session.current(state)
        local sourceRow = adapter.bound(current and current.bindings, source)
            or incomingRow(session, state, source)
        local sourceRole = adapter.sourceRole(sourceRow, source and source.Name)
        local child = current and adapter.produced(current.bindings, sourceRow, sourceRole)
        if child and child.detail and child.detail.producer
            and child.detail.producer.kind == kind then
            return sourceRow, child
        end
        return sourceRow, nil
    end

    module.hooks.wrap("SetupRoomReward", "execution-v10-reward-source", function(_, runtime, base, currentRun,
        nativeRoom, prior, args)
        local current = session.current(getState(runtime))
        local reward = current and current.occurrence.overview.incomingReward
        if reward and type(nativeRoom) == "table" then
            nativeRoom.ForceLootName = reward.source
            if reward.spurnedSource and type(nativeRoom.Encounter) == "table" then
                nativeRoom.Encounter.LootAName = reward.source
                nativeRoom.Encounter.LootBName = reward.spurnedSource
            end
        end
        return base(currentRun, nativeRoom, prior, args)
    end)

    module.hooks.wrap("UseLoot", "execution-v10-use-loot", function(_, runtime, base, usee, args, user)
        local state = getState(runtime)
        local row = adapter.bound(currentIndex(session, state), usee) or incomingRow(session, state, usee)
        if row == nil then return base(usee, args, user) end
        row = resolveTraitFallback(session, state, row, usee)
        if row == nil then report(runtime); return nil end
        usee.__runPlannerTimelineRow = row
        local _, seaStarChild = childFor(state, usee, "seaStarDuplicate")
        if seaStarChild then pendingSeaStar = { source = usee, child = seaStarChild } end
        local expected, traitOffer = adapter.expectedTrait(row)
        if expected ~= nil then
            adapter.applyTraitOffer(row, usee)
            pendingTrait = { row = row, source = usee }
        elseif traitOffer and traitOffer.kind == "chaos" then
            pendingTrait = { row = row, source = usee }
        elseif adapter.applyLevelResolution(row, usee) then
            pendingLevel = { row = row, source = usee }
        end
        if expected == nil and pendingTrait == nil and pendingLevel == nil then
            pendingSimple = { row = row, source = usee, gameName = usee.Name }
        end
        local result = base(usee, args, user)
        pendingSeaStar = nil
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseConsumableItem", "execution-v10-use-consumable", function(_, runtime, base, item, args, user)
        local state = getState(runtime)
        local row = adapter.bound(currentIndex(session, state), item) or incomingRow(session, state, item)
        if row ~= nil then pendingSimple = { row = row, source = item, gameName = item.Name } end
        local result = base(item, args, user)
        report(runtime)
        return result
    end)

    local function completeSimpleAcquisition(runtime, item)
        local pending = pendingSimple
        if pending == nil or pending.source ~= item then return end
        pendingSimple = nil
        local state = getState(runtime)
        session.complete(state, pending.row, adapter.verifySimple(pending.row, pending.gameName),
            pending.row.detail, pending.gameName)
        report(runtime)
    end

    module.hooks.wrap("HandleLootPickup", "execution-v10-confirm-loot", function(_, runtime, base, currentRun, loot,
        args)
        local result = base(currentRun, loot, args)
        completeSimpleAcquisition(runtime, loot)
        return result
    end)

    module.hooks.wrap("ConsumableUsedPresentation", "execution-v10-confirm-consumable", function(_, runtime, base,
        currentRun, item, args)
        local result = base(currentRun, item, args)
        completeSimpleAcquisition(runtime, item)
        return result
    end)

    module.hooks.wrap("SpawnRoomReward", "execution-v10-bind-room-reward", function(_, runtime, base, source, args)
        local result = base(source, args)
        local state = getState(runtime)
        incomingRow(session, state, result)
        return result
    end)

    module.hooks.wrap("ConvertMetaRewardPresentation", "execution-v10-artificer-source", function(_, runtime, base,
        target)
        local state = getState(runtime)
        local sourceRow, child = childFor(state, target, "artificerReplacement")
        if child == nil then return base(target) end
        pendingProduced[target.ObjectId] = child
        local result = base(target)
        session.complete(state, sourceRow, true)
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetTotalHeroTraitValue", "execution-v10-sea-star-gate", function(_, _runtime, base,
        propertyName, args)
        if propertyName == "DoubleRewardChance" and pendingSeaStar ~= nil then return 1 end
        return base(propertyName, args)
    end)

    module.hooks.wrap("RandomChance", "execution-v10-sea-star-duplicate", function(_, _, base, chance, args)
        if pendingSeaStar ~= nil then return true end
        return base(chance, args)
    end)

    local function bindProduced(state, sourceId, result)
        local child = sourceId and pendingProduced[sourceId] or pendingSeaStar and pendingSeaStar.child
        if child and result then
            local current = session.current(state)
            adapter.bind(current and current.bindings, child, result)
        end
    end

    module.hooks.wrap("CreateLoot", "execution-v10-created-loot", function(_, runtime, base, args)
        local result = base(args)
        local sourceId = type(args) == "table" and args.SpawnRewardOnId
        bindProduced(getState(runtime), sourceId, result)
        if sourceId then pendingProduced[sourceId] = nil end
        return result
    end)

    module.hooks.wrap("CreateConsumableItem", "execution-v10-created-consumable", function(_, runtime, base, ...)
        local result = base(...)
        bindProduced(getState(runtime), nil, result)
        return result
    end)

    module.hooks.wrap("CreateBoonLootButtons", "execution-v10-trait-screen", function(_, runtime, base, screen,
        lootData, reroll, args)
        local state = getState(runtime)
        local row = adapter.bound(currentIndex(session, state), lootData)
            or (pendingTrait and pendingTrait.row) or incomingRow(session, state, lootData)
        if row ~= nil then
            lootData.__runPlannerTimelineRow = row
            local _, offer = adapter.expectedTrait(row)
            if offer and offer.kind ~= "chaos" then adapter.applyTraitOffer(row, lootData) end
        end
        return base(screen, lootData, reroll, args)
    end)

    module.hooks.wrap("NarcissusBenefitChoice", "execution-v10-narcissus-benefit", function(_, runtime, base, source,
        args, screen)
        local state = getState(runtime)
        local row = interactionRow(state, source)
        local resolution = row and row.node and row.node.resolution
        if resolution and resolution.kind == "traitOffer" and resolution.offer.giver == "Narcissus" then
            if not adapter.applyTraitOffer(row, args) then
                session.mismatch(state, "narcissus-benefit", "published trait offer", nil)
            else
                pendingTrait = { row = row, source = source }
            end
        end
        local result = base(source, args, screen)
        report(runtime)
        return result
    end)

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
        local row, outcome = nemesisRow(state, source)
        local prefixes = {
            freeItem = "NemesisGetFreeItem", goldTrade = "NemesisBuyItem",
            damageTrade = "NemesisTakeDamageForItem", traitTrade = "NemesisGiveTraitForItem",
            damageContest = "NemesisDamageContest",
        }
        local original, prefix = source and source.InteractTextLineSets, outcome and prefixes[outcome.kind]
        if row == nil or type(original) ~= "table" or prefix == nil then return base(source, args) end
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
        local row, outcome = nemesisRow(state, source)
        if row and outcome and outcome.kind == "traitTrade" and type(args) == "table" then
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
        if row and outcome then
            local accepted = source and source.Accepted == true
            if (outcome.response == "accept") ~= accepted then
                session.mismatch(state, "nemesis-trade-response", outcome.response, accepted)
            elseif outcome.kind == "traitTrade" and accepted then
                pendingNemesis = { row = row, traitKey = outcome.traitKey }
            else
                session.complete(state, row, true)
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
            session.complete(state, pending.row, traitName == pending.traitKey, pending.row.node, traitName)
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
        local row, outcome = nemesisRow(state, source)
        if row and outcome and outcome.kind == "damageContest" then
            local details = source.DamageContestArgs or {}
            local success = type(source.DamageContestAmount) == "number"
                and type(details.DamageGoal) == "number"
                and source.DamageContestAmount >= details.DamageGoal
            session.complete(state, row, (outcome.result == "success") == success, row.node, success)
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
        local row, outcome = nemesisRow(state, source)
        if row and outcome and outcome.runtimeFallbacks then
            for _, fallback in ipairs(outcome.runtimeFallbacks) do
                if fallback.availabilityContact == "npcConsumableSelection" then
                    local key = session.resolveFallback(state, row, "npcConsumableSelection", fallback,
                        function(candidate)
                            for _, item in ipairs(args.Consumables or {}) do
                                if item.Name == candidate or item.ItemName == candidate then return true end
                            end
                            return false
                        end)
                    if key == nil then report(runtime); return base(args, choice, line) end
                    local chosen = {}
                    for _, item in ipairs(args.Consumables or {}) do
                        if item.Name == key or item.ItemName == key then chosen[#chosen + 1] = item end
                    end
                    args.Consumables = chosen
                end
            end
            pendingNemesis = { row = row, reward = true }
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
            session.complete(getState(runtime), pending.row, produced, pending.row.node, args)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("CreateUpgradeChoiceButton", "execution-v10-trait-option", function(_, _runtime, base, screen,
        lootData, itemIndex, itemData, args)
        local row = lootData and lootData.__runPlannerTimelineRow or pendingTrait and pendingTrait.row
        local _, offer = adapter.expectedTrait(row)
        if offer and offer.kind == "chaos" then
            local option = offer.curseOptions[itemIndex]
            if option then
                itemData.SecondaryItemName = option.curseKey
                chaosContext = { curseKey = option.curseKey, requirementCount = option.requirementCount }
                local selected = tonumber(offer.selected:match("(%d+)$"))
                if selected == itemIndex then
                    itemData.ItemName, itemData.Rarity = offer.blessingKey, offer.rarity
                    chaosContext.blessingKey = offer.blessingKey
                    chaosContext.rarity = offer.rarity
                    chaosContext.curseValues = offer.selectedCurseValues
                    chaosContext.blessingValues = offer.blessingValues
                end
            end
        elseif offer and offer.options[itemIndex] then
            local option = offer.options[itemIndex]
            itemData.ItemName, itemData.Rarity, itemData.StackNum = option.key, option.rarity, option.effectiveLevel
            if option.replacement then
                itemData.TraitToReplace = option.replacement.replacedTraitKey
                itemData.OldRarity = option.replacement.oldRarity
            end
        end
        local ok, result = pcall(base, screen, lootData, itemIndex, itemData, args)
        chaosContext = nil
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("GetProcessedTraitData", "execution-v10-chaos-values", function(_, _, base, args)
        local result = base(args)
        local context = chaosContext
        if context == nil or type(args) ~= "table" or type(result) ~= "table" then return result end
        if args.TraitName == context.curseKey then
            result.RemainingUses = context.requirementCount
            if context.curseValues then
                return chaos.applyCurse(result, context.curseKey, context.requirementCount, context.curseValues)
            end
        elseif args.TraitName == context.blessingKey then
            result.Rarity = context.rarity
            return chaos.applyBlessing(result, context.blessingKey, context.blessingValues)
        end
        return result
    end)

    module.hooks.wrap("SetTransformingTraitsOnLoot", "execution-v10-chaos-reservation", function(_, _, base, lootData,
        choices)
        local result = base(lootData, choices)
        local row = lootData and lootData.__runPlannerTimelineRow or pendingTrait and pendingTrait.row
        local _, offer = adapter.expectedTrait(row)
        if offer == nil or offer.kind ~= "chaos" or type(lootData.UpgradeOptions) ~= "table" then return result end
        local selectedIndex = tonumber(offer.selected:match("(%d+)$"))
        local selected = selectedIndex and lootData.UpgradeOptions[selectedIndex]
        if selected ~= nil then
            for index, option in ipairs(lootData.UpgradeOptions) do
                if option.ItemName == offer.blessingKey and index ~= selectedIndex then
                    selected.ItemName, option.ItemName = option.ItemName, selected.ItemName
                    selected.Rarity, option.Rarity = offer.rarity, selected.Rarity
                end
            end
            selected.ItemName, selected.Rarity = offer.blessingKey, offer.rarity
        end
        return result
    end)

    module.hooks.wrap("HandleUpgradeChoiceSelection", "execution-v10-trait-selection", function(_, runtime, base,
        screen, button, args)
        local state = getState(runtime)
        local selected = button and button.Data and button.Data.Name
        if pendingLevel ~= nil then
            local trait = findTrait(selected)
            pendingLevel.before = trait and trait.StackNum
            pendingLevel.selected = selected
        elseif pendingTrait ~= nil then
            pendingTrait.selected = selected
        end
        local result = base(screen, button, args)
        if pendingLevel ~= nil then
            local pending = pendingLevel
            pendingLevel = nil
            session.complete(state, pending.row,
                adapter.verifyLevel(pending.row, pending.selected, pending.before, heroTraits()),
                pending.row.detail.levelResolution, pending.selected)
        elseif pendingTrait ~= nil then
            local pending = pendingTrait
            pendingTrait = nil
            session.complete(state, pending.row,
                adapter.verifyTrait(pending.row, pending.selected, heroTraits()),
                adapter.expectedTrait(pending.row), pending.selected)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRarityToTraits", "execution-v10-steady-growth", function(_, runtime, base, source, args)
        local state = getState(runtime)
        local current = session.current(state)
        local phase = current and current.window:match("^encounterEnd:(.+)$")
        local row = phase and adapter.automatic(current.bindings, "steadyGrowth", phase) or nil
        if row and type(args) == "table" then
            local trait = findTrait(row.node.target)
            if trait then args.ForceUpgrade = { trait } end
        end
        local result = base(source, args)
        if row then
            session.complete(state, row, adapter.verifyAutomatic(row, {
                target = type(result) == "table" and result.Name or nil,
                rarity = type(result) == "table" and result.Rarity or nil,
            }), row.node, result)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRandomChaosBlessing", "execution-v10-embryo", function(_, runtime, base, rarity)
        local state = getState(runtime)
        local current = session.current(state)
        local phase = current and current.window:match("^encounterEnd:(.+)$")
        local row = phase and adapter.automatic(current.bindings, "transcendentEmbryo", phase) or nil
        embryoTarget = row and row.node.target or nil
        local result = base(row and row.node.rarity or rarity)
        embryoTarget = nil
        if row then
            session.complete(state, row, adapter.verifyAutomatic(row, {
                target = type(result) == "table" and (result.Name or result.TraitName) or result,
                rarity = type(result) == "table" and result.Rarity or nil,
            }), row.node, result)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetRandomArrayValue", "execution-v10-automatic-selection", function(_, _, base, values, rng)
        if embryoTarget and type(values) == "table" then
            for _, value in ipairs(values) do if value == embryoTarget then return value end end
        end
        return base(values, rng)
    end)

    module.hooks.wrap("Kill", "execution-v10-boss-defeated", function(_, runtime, base, victim, args)
        local state = getState(runtime)
        local current = session.current(state)
        local prior = bossScope
        if victim and victim.IsBoss and current then
            local phase = current.occurrence.overview.encounterPhases[1]
            bossScope = phase and { state = state, current = current, phaseKey = phase.slotKey } or nil
            if bossScope then session.window(state, "bossDefeated:" .. bossScope.phaseKey) end
        end
        local ok, result = pcall(base, victim, args)
        bossScope = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRandomMetaUpgrades", "execution-v10-boss-arcana", function(_, runtime, base, count, args)
        if bossScope == nil then return base(count, args) end
        local effect = type(args) == "table" and args.RarityLevel ~= nil
            and "crystalFigurine" or "judgment"
        local row = adapter.automatic(bossScope.current.bindings, effect, bossScope.phaseKey)
        if row == nil then return base(count, args) end
        local prior = arcanaQueue
        arcanaQueue = { keys = row.node.arcanaKeys, index = 1 }
        local ok, result = pcall(base, count, args)
        arcanaQueue = prior
        if not ok then error(result, 0) end
        local observed = { arcanaKeys = {}, rarity = row.node.rarity }
        local rarityOrder = _G.TraitRarityData and _G.TraitRarityData.RarityUpgradeOrder or {}
        for _, key in ipairs(row.node.arcanaKeys) do
            local stateEntry = _G.GameState and _G.GameState.MetaUpgradeState
                and _G.GameState.MetaUpgradeState[key]
            local rarity = stateEntry and rarityOrder[stateEntry.RarityLevel or stateEntry.Level or 1]
            if not stateEntry or not stateEntry.Equipped or rarity ~= row.node.rarity
                or not (_G.CurrentRun and _G.CurrentRun.TemporaryMetaUpgrades
                    and _G.CurrentRun.TemporaryMetaUpgrades[key]) then
                observed = { arcanaKeys = {}, rarity = rarity }
                break
            end
            observed.arcanaKeys[#observed.arcanaKeys + 1] = key
        end
        session.complete(bossScope.state, row, adapter.verifyAutomatic(row, observed), row.node, observed)
        report(runtime)
        return result
    end)

    module.hooks.wrap("RemoveRandomValue", "execution-v10-boss-arcana-selection", function(_, _, base, values)
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

return hooks
