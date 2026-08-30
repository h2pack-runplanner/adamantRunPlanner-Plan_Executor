local logic = {}

function logic.bind(data, inboxRoot)
    if type(inboxRoot) ~= "string" or inboxRoot == "" then error("executor config path is required", 2) end
    local json = import("mods/json.lua")
    local protocol = import("mods/protocol.lua")
    local inbox = import("mods/inbox.lua")
    local session = import("mods/session.lua")
    data.inbox = inbox.create(inboxRoot, function(raw)
        local value, jsonError = json.decode(raw)
        if value == nil then return nil, "malformed-json: " .. tostring(jsonError) end
        return protocol.decode(value)
    end, rom.path)
    data.session = session
    return logic
end

function logic.attach(moduleRef, data)
    data.session.defineCache(moduleRef)
    -- Vanilla StartNewRun enters ChooseStartingRoom before it returns.  Keep
    -- initialization scoped to that lifecycle so a standalone mid-run hook
    -- can never freeze a newly published plan.
    local startLifecycleDepth = 0
    local startLifecycleEnabled = true
    local embryoSelection = nil
    local leaveRoomDepth = 0
    local lootUseDepth, consumableUseDepth = 0, 0
    local function writeStatus(runtime, state)
        if runtime.status and type(runtime.status.write) == "function" then
            local status = data.session.status(state)
            local text = status.state .. ": " .. status.reason
            if status.state == "desynchronized" then
                text = text .. " (" .. status.disposition .. " at " .. status.checkpoint .. ")"
            end
            runtime.status.write("ExecutionSessionStatus", text)
        end
    end
    moduleRef.hooks.wrap("StartNewRun", "execution-start-new-run", function(host, runtime, base, previousRun, args)
        local priorDepth = startLifecycleDepth
        local priorEnabled = startLifecycleEnabled
        local lifecycleEnabled = host.isEnabled == nil or host.isEnabled()
        startLifecycleDepth = priorDepth + 1
        startLifecycleEnabled = lifecycleEnabled
        local ok, currentRun = pcall(base, previousRun, args)
        startLifecycleDepth = priorDepth
        startLifecycleEnabled = priorEnabled
        if not ok then error(currentRun, 0) end
        local state = data.session.get(runtime)
        -- The normal base call has already passed through the nested starting
        -- room hook.  This fallback only covers hosts that do not make that
        -- nested call, while remaining inside StartNewRun.
        if not state.initialized then
            data.session.startNewRun(state, {
                currentRun = currentRun,
                args = args,
                enabled = lifecycleEnabled,
                inbox = data.inbox,
            })
        end
        writeStatus(runtime, state)
        return currentRun
    end)
    moduleRef.hooks.wrap("ChooseStartingRoom", "execution-opening-room", function(_, runtime, base, currentRun, args)
        local state = data.session.get(runtime)
        if startLifecycleDepth > 0 and not state.initialized then
            data.session.startNewRun(state, {
                currentRun = currentRun,
                args = args,
                enabled = startLifecycleEnabled,
                inbox = data.inbox,
            })
        end
        local gameValue = _G.game or game
        local room = data.session.chooseStartingRoom(state, currentRun, args, gameValue)
        return room or base(currentRun, args)
    end)
    -- StartRoom applies RunOverrides and initializes the live depth caches
    -- before this existing nested seam. Observe here so room-entry diagnostics
    -- see the game-owned values without pre-applying or duplicating them.
    moduleRef.hooks.wrap("StartRoomPreLoadBinks", "execution-observe-room", function(_, runtime, base, args)
        local state = data.session.get(runtime)
        local currentRun = type(args) == "table" and args.Run or nil
        local currentRoom = type(args) == "table" and args.Room or nil
        data.session.observeRoom(state, currentRun, currentRoom)
        writeStatus(runtime, state)
        return base(args)
    end)
    moduleRef.hooks.wrap("SetupRoomMultipleEncountersData", "execution-resolve-encounter-assembly", function(_, runtime, base, room, args)
        local currentRun = _G.CurrentRun
        local state = data.session.get(runtime)
        data.session.beginMultipleEncounterResolution(state, currentRun, room)
        local ok, result = pcall(base, room, args)
        data.session.endMultipleEncounterResolution(state)
        if not ok then error(result, 0) end
        data.session.verifyEncounterAssembly(state, currentRun, room)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("ChooseEncounter", "execution-resolve-phase-encounter", function(_, runtime, base, currentRun, room, args)
        local resolved = data.session.chooseResolvedEncounter(
            data.session.get(runtime), currentRun, room, _G.game or game)
        return resolved or base(currentRun, room, args)
    end)
    -- These are observation seams only.  The room copy's LegalEncounters was
    -- populated from the frozen plan before vanilla prepared the room.
    moduleRef.hooks.wrap("StartEncounterEffects", "execution-observe-encounter-start", function(_, runtime, base, encounter)
        local state = data.session.get(runtime)
        local currentRun = _G.CurrentRun
        data.session.observeEncounterStart(state, currentRun, currentRun and currentRun.CurrentRoom, encounter)
        local result = base(encounter)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("EndEncounterEffects", "execution-observe-encounter-end", function(_, runtime, base, currentRun, currentRoom, encounter)
        local state = data.session.get(runtime)
        data.session.observeEncounterEnd(state, currentRun, currentRoom, encounter)
        local result = base(currentRun, currentRoom, encounter)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("ChooseNextRoomData", "execution-outgoing-room", function(_, runtime, base, currentRun, args, otherDoors)
        local result = data.session.chooseNextRoomData(
            data.session.get(runtime), currentRun, args, otherDoors, _G.game or game)
        if result.kind == "passThrough" then return base(currentRun, args, otherDoors) end
        if result.kind == "failed" then
            writeStatus(runtime, data.session.get(runtime))
            return base(currentRun, args, otherDoors)
        end
        return result.roomData
    end)
    moduleRef.hooks.wrap("DoUnlockRoomExits", "execution-batch-reward-store", function(_, runtime, base, currentRun, room)
        local state = data.session.get(runtime)
        local result = data.session.prepareBatchRewardStore(state, currentRun)
        if result.kind == "failed" then
            writeStatus(runtime, state)
            return base(currentRun, room)
        end
        return base(currentRun, room)
    end)
    moduleRef.hooks.wrap("LeaveRoom", "execution-observe-exit", function(_, runtime, base, currentRun, door)
        local state = data.session.get(runtime)
        data.session.observeExit(state, currentRun, door)
        leaveRoomDepth = leaveRoomDepth + 1
        local ok, result = pcall(base, currentRun, door)
        leaveRoomDepth = leaveRoomDepth - 1
        if not ok then error(result, 0) end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("CleanupEnemies", "execution-observe-cleanup", function(_, runtime, base, args)
        local result = base(args)
        if leaveRoomDepth > 0 then data.session.observeCleanup(data.session.get(runtime), _G.CurrentRun) end
        return result
    end)
    moduleRef.hooks.wrap("UpdateRunHistoryCache", "execution-observe-before-exit", function(_, runtime, base, currentRun, roomAdded)
        local result = base(currentRun, roomAdded)
        local state = data.session.get(runtime)
        if data.session.observeBeforeRoomExit(state, currentRun) then
            -- Vanilla has appended the source and updated its caches, while
            -- CurrentRoom still names that source. Commit before LeaveRoom
            -- continues into target preparation and LoadMap.
            data.session.commitExit(state)
        end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap(
        "ChooseRoomReward", "execution-opening-reward",
        function(_, runtime, base, currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        local result = data.session.chooseRoomReward(
            data.session.get(runtime), currentRun, room, _G.game or game, base,
            rewardStoreName, previouslyChosenRewards, args)
        if result.kind == "passThrough" then
            return base(currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        end
        -- A pre-contact mismatch has no realized value.  Let vanilla continue
        -- from that point while the session remains frozen/desynchronized.
        if result.kind == "failed" and result.value == nil then
            return base(currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        end
        return result.value
    end)
    moduleRef.hooks.wrap("SetupRoomReward", "execution-reward-source", function(_, runtime, base, currentRun, room, previouslyChosenRewards, args)
        local state = data.session.get(runtime)
        local result = data.session.prepareRewardSource(state, currentRun, room)
        if result.kind == "failed" then
            writeStatus(runtime, state)
            return base(currentRun, room, previouslyChosenRewards, args)
        end
        return base(currentRun, room, previouslyChosenRewards, args)
    end)
    moduleRef.hooks.wrap("UseLoot", "execution-acquire-loot", function(_, runtime, base, usee, args, user)
        local state = data.session.get(runtime)
        local prepared = data.session.prepareLootUse(state, usee)
        if prepared.kind == "failed" then writeStatus(runtime, state); return base(usee, args, user) end
        lootUseDepth = lootUseDepth + 1
        local ok, result = pcall(base, usee, args, user)
        lootUseDepth = lootUseDepth - 1
        if not ok then error(result, 0) end
        if prepared.kind == "handled" and data.session.completeSimpleAcquisition then
            data.session.completeSimpleAcquisition(state, usee.Name)
        end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("UseConsumableItem", "execution-acquire-consumable", function(_, runtime, base, consumableItem, args, user)
        -- Purchases and cost-bearing world items are Gate D; resource/minor
        -- pickups reach the same closed acquisition observer after vanilla use.
        if type(consumableItem) == "table" and consumableItem.ResourceCosts ~= nil and consumableItem.IgnorePurchase ~= true then return base(consumableItem, args, user) end
        local state = data.session.get(runtime)
        local prepared = data.session.prepareLootUse(state, consumableItem)
        if prepared.kind == "failed" then writeStatus(runtime, state); return base(consumableItem, args, user) end
        consumableUseDepth = consumableUseDepth + 1
        local ok, result = pcall(base, consumableItem, args, user)
        consumableUseDepth = consumableUseDepth - 1
        if not ok then error(result, 0) end
        if prepared.kind == "handled" then data.session.completeSimpleAcquisition(state, consumableItem.Name) end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("HandleLootPickup", "execution-confirm-loot-pickup", function(_, runtime, base, currentRun, loot, args)
        local result = base(currentRun, loot, args)
        if lootUseDepth > 0 then data.session.markSimpleAcquisitionContact(data.session.get(runtime), loot and loot.Name) end
        return result
    end)
    moduleRef.hooks.wrap("ConsumableUsedPresentation", "execution-confirm-consumable", function(_, runtime, base, currentRun, consumableItem, args)
        local result = base(currentRun, consumableItem, args)
        if consumableUseDepth > 0 then data.session.markSimpleAcquisitionContact(data.session.get(runtime), consumableItem and consumableItem.Name) end
        return result
    end)
    moduleRef.hooks.wrap("UseNPCPostTextLines", "execution-observe-encounter-interaction", function(_, runtime, base, source, partner, textLines)
        local result = base(source, partner, textLines)
        local currentRun = _G.CurrentRun
        data.session.observeEncounterInteraction(data.session.get(runtime), currentRun, currentRun and currentRun.CurrentRoom)
        writeStatus(runtime, data.session.get(runtime))
        return result
    end)
    -- Each generated choice reaches this final pre-presentation seam.  Some
    -- screens bypass SetTraitsOnLoot, so this is the complete contact.
    moduleRef.hooks.wrap("CreateUpgradeChoiceButton", "execution-trait-offer", function(_, runtime, base, screen, lootData, itemIndex, itemData, args)
        local state = data.session.get(runtime)
        local prepared = data.session.prepareTraitOfferOption(state, itemIndex, itemData)
        if prepared.kind == "failed" then writeStatus(runtime, state) end
        return base(screen, lootData, itemIndex, itemData, args)
    end)
    moduleRef.hooks.wrap("HandleUpgradeChoiceSelection", "execution-observe-trait-selection", function(_, runtime, base, screen, button, args)
        local state = data.session.get(runtime)
        if data.session.observeTraitSelection ~= nil then
            local trait = type(button) == "table" and button.Data and button.Data.Name or nil
            if state.pendingPom ~= nil then
                local hero = _G.CurrentRun and _G.CurrentRun.Hero
                data.session.observePomSelection(state, trait, hero and hero.Traits)
            else
                data.session.observeTraitSelection(state, trait)
            end
        end
        local result = base(screen, button, args)
        if data.session.verifyTraitAcquisition ~= nil then
            local hero = _G.CurrentRun and (_G.CurrentRun.Hero or _G.CurrentRun.HeroTraits) or nil
            if state.pendingPom ~= nil then data.session.verifyPomResolution(state, type(hero) == "table" and hero.Traits or nil)
            else data.session.verifyTraitAcquisition(state, type(hero) == "table" and hero.Traits or nil) end
        end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("AddRarityToTraits", "execution-steady-growth", function(_, runtime, base, source, args)
        local state = data.session.get(runtime)
        local currentRun = _G.CurrentRun
        local hero = currentRun and currentRun.Hero
        local prepared = data.session.prepareSteadyGrowth(state, source, args, hero and hero.Traits)
        if prepared.kind == "failed" then writeStatus(runtime, state) end
        local result = base(source, args)
        if prepared.kind == "handled" then data.session.verifySteadyGrowth(state, hero and hero.Traits, result) end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("AddRandomChaosBlessing", "execution-embryo", function(_, runtime, base, rarityName)
        local state = data.session.get(runtime)
        local prepared = data.session.prepareEmbryo(state)
        embryoSelection = prepared and prepared.target or nil
        local ok, result = pcall(base, prepared and prepared.rarity or rarityName)
        embryoSelection = nil
        if not ok then error(result, 0) end
        local hero = _G.CurrentRun and _G.CurrentRun.Hero
        data.session.verifyEmbryo(state, result, hero and hero.TraitDictionary)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("GetRandomArrayValue", "execution-embryo-choice", function(_, runtime, base, values, rng)
        -- This is deliberately scoped by AddRandomChaosBlessing's synchronous
        -- call. Other random arrays remain entirely vanilla-owned.
        if embryoSelection ~= nil and type(values) == "table" then
            for _, value in ipairs(values) do
                if value == embryoSelection then return value end
            end
        end
        return base(values, rng)
    end)
end

return logic
