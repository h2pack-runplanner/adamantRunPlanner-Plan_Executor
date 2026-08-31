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
    local resourceElementGrant = nil
    local leaveRoomDepth = 0
    local travelDealRefillDepth = 0
    local inventoryGeneration = nil
    local wellTwistSelection = nil
    local rackSelection = nil
    local echoLastRewardDepth = 0
    local lootUseDepth, consumableUseDepth = 0, 0
    local chaosTraitProcessing = nil
    local chaosGeneration = nil
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
    moduleRef.hooks.wrap("CreateRoom", "execution-resource-success", function(_, runtime, base, roomData, args)
        local state = data.session.get(runtime)
        local prepared = data.session.prepareAdditionalRoomCreation(state, roomData, _G.game or game)
        local room = base(prepared, args)
        data.session.applyResourceSuccesses(data.session.get(runtime), room)
        return room
    end)
    moduleRef.hooks.wrap("HandleSecretSpawns", "execution-chaos-gate", function(_, runtime, base, currentRun)
        local state = data.session.get(runtime)
        local room = type(currentRun) == "table" and currentRun.CurrentRoom or nil
        local scope = data.session.beginChaosGeneration(state, room)
        local prior = chaosGeneration
        chaosGeneration = scope
        local ok, result = pcall(base, currentRun)
        chaosGeneration = prior
        data.session.applyChaosGeneration(scope, room)
        if not ok then error(result, 0) end
        return result
    end)
    moduleRef.hooks.wrap(
        "IsSecretDoorEligible",
        "execution-chaos-gate-eligibility",
        function(_, _, base, currentRun, currentRoom)
            if chaosGeneration ~= nil then return chaosGeneration.force end
            return base(currentRun, currentRoom)
        end
    )
    moduleRef.hooks.wrap("SpawnZagContract", "execution-zagreus-contract", function(_, runtime, base, room, args)
        local state = data.session.get(runtime)
        local scope = data.session.beginZagreusGeneration(state, room)
        if scope ~= nil and type(room) == "table" then room.ZagreusContractSuccess = scope.target ~= nil end
        local ok, result = pcall(base, room, args)
        data.session.finishZagreusGeneration(state, scope, room)
        if not ok then error(result, 0) end
        return result
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
        local state = data.session.get(runtime)
        local result = data.session.chooseArtificerReward
            and data.session.chooseArtificerReward(state, currentRun, room, _G.game or game, base,
                rewardStoreName, previouslyChosenRewards, args)
            or { kind = "passThrough" }
        if result.kind == "passThrough" then
            result = data.session.chooseRoomReward(state, currentRun, room, _G.game or game, base,
                rewardStoreName, previouslyChosenRewards, args)
        end
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
    -- Constrain the native candidate inputs before FillInShopOptions builds
    -- records.  We never post-filter a completed random inventory.
    moduleRef.hooks.wrap("FillInShopOptions", "execution-world-shop-options", function(_, runtime, base, args)
        local state = data.session.get(runtime)
        local prepared = data.session.prepareInventoryGeneration(state, args, travelDealRefillDepth > 0)
        local priorGeneration = inventoryGeneration
        inventoryGeneration = prepared.kind == "handled" and prepared or nil
        local ok, result = pcall(base, prepared.args or args)
        inventoryGeneration = priorGeneration
        if not ok then error(result, 0) end
        result = data.session.orderWellInventoryGeneration(prepared, result)
        local verified = data.session.verifyInventoryGeneration(state, prepared, result)
        if verified and verified.kind == "failed" then writeStatus(runtime, state) end
        return result
    end)
    moduleRef.hooks.wrap("GetEligibleInteractedGod", "execution-inventory-source", function(_, runtime, base, ignoredGod)
        local source = data.session.chooseInventoryGod(data.session.get(runtime), inventoryGeneration)
        if source ~= nil then return source end
        return base(ignoredGod)
    end)
    moduleRef.hooks.wrap("CreateSellButtons", "execution-purging-pool-options", function(_, runtime, base, screen)
        -- OpenSellTraitMenu blocks in HandleScreenInput.  This seam runs after
        -- its native stale-list regeneration and immediately before the UI
        -- reads CurrentRoom.SellOptions to construct buttons.
        local prepared = data.session.applyPurgingPoolInventory(data.session.get(runtime), _G.CurrentRun and _G.CurrentRun.CurrentRoom)
        if prepared.kind == "failed" then writeStatus(runtime, data.session.get(runtime)) end
        return base(screen)
    end)
    moduleRef.hooks.wrap("SpawnStoreItemInWorld", "execution-world-shop-spawn", function(_, runtime, base, itemData, kitId)
        local result = base(itemData, kitId)
        data.session.noteWorldShopSpawn(data.session.get(runtime), itemData, kitId, _G.CurrentRun)
        return result
    end)
    moduleRef.hooks.wrap("RemoveStoreItem", "execution-world-shop-removal", function(_, runtime, base, args)
        local state = data.session.get(runtime)
        local pending = data.session.beginWorldShopRemoval(state, args)
        state.pendingTravelDealRefill = pending
        local result = base(args)
        data.session.observeWorldShopRemoval(state, args, pending)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("RestockWorldItem", "execution-travel-deal-refill", function(_, runtime, base, replacedIndex, kitId, args)
        local state = data.session.get(runtime)
        -- This request was captured from the successful physical purchase;
        -- no future trace search is involved.
        if not data.session.verifyTravelDealRefillSlot(state, replacedIndex) then
            writeStatus(runtime, state)
            return base(replacedIndex, kitId, args)
        end
        travelDealRefillDepth = travelDealRefillDepth + 1
        local ok, result = pcall(base, replacedIndex, kitId, args)
        travelDealRefillDepth = travelDealRefillDepth - 1
        state.pendingTravelDealRefill = nil
        if not ok then error(result, 0) end
        return result
    end)
    moduleRef.hooks.wrap("UseLoot", "execution-acquire-loot", function(_, runtime, base, usee, args, user)
        local state = data.session.get(runtime)
        local timePiece = data.session.beginTimePiece(state, usee)
        local prepared = data.session.prepareLootUse(state, usee)
        -- Trait offers settle from HandleUpgradeChoiceSelection; only direct
        -- loot uses reach their native duplication roll in this call.
        local seaStar = state.pendingAcquisition == nil and state.pendingPom == nil
            and data.session.beginSeaStarDuplicate(state, usee) or nil
        if prepared.kind == "failed" then writeStatus(runtime, state); return base(usee, args, user) end
        lootUseDepth = lootUseDepth + 1
        local ok, result = pcall(base, usee, args, user)
        lootUseDepth = lootUseDepth - 1
        if not ok then error(result, 0) end
        if prepared.kind == "handled" and data.session.completeSimpleAcquisition then
            data.session.completeSimpleAcquisition(state, usee.Name)
        end
        if seaStar then data.session.finishSeaStarDuplicate(state, usee) end
        if timePiece then data.session.finishTimePiece(state, usee) end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("SpecialInteract", "execution-time-piece", function(_, runtime, base, usee, args)
        local state = data.session.get(runtime)
        local prepared = data.session.beginTimePiece(state, usee)
        local result = base(usee, args)
        if prepared then data.session.finishTimePiece(state, usee) end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("SpawnRoomReward", "execution-produced-pickup-capture", function(_, runtime, base, source, args)
        local result = base(source, args)
        local state = data.session.get(runtime)
        data.session.captureArtificerReplacement(state, args, result)
        data.session.captureProducedChild(state, result)
        return result
    end)
    moduleRef.hooks.wrap("EchoLastReward", "execution-echo-last-reward", function(_, runtime, base, args)
        local state = data.session.get(runtime)
        data.session.beginEchoLastReward(state)
        echoLastRewardDepth = echoLastRewardDepth + 1
        local ok, result = pcall(base, args)
        echoLastRewardDepth = echoLastRewardDepth - 1
        if not ok then error(result, 0) end
        data.session.finishEchoLastReward(state)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("UseConsumableItem", "execution-acquire-consumable", function(_, runtime, base, consumableItem, args, user)
        -- Purchases and cost-bearing world items are Gate D; resource/minor
        -- pickups reach the same closed acquisition observer after vanilla use.
        if type(consumableItem) == "table" and consumableItem.ResourceCosts ~= nil and consumableItem.IgnorePurchase ~= true then return base(consumableItem, args, user) end
        local state = data.session.get(runtime)
        local prepared = data.session.prepareLootUse(state, consumableItem)
        local seaStar = data.session.beginSeaStarDuplicate(state, consumableItem)
        if prepared.kind == "failed" then writeStatus(runtime, state); return base(consumableItem, args, user) end
        consumableUseDepth = consumableUseDepth + 1
        local ok, result = pcall(base, consumableItem, args, user)
        consumableUseDepth = consumableUseDepth - 1
        if not ok then error(result, 0) end
        if prepared.kind == "handled" then data.session.completeSimpleAcquisition(state, consumableItem.Name) end
        if seaStar then data.session.captureSeaStarDuplicate(state, consumableItem); data.session.finishSeaStarDuplicate(state, consumableItem) end
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
    moduleRef.hooks.wrap("HandleStorePurchase", "execution-observe-well-purchase", function(_, runtime, base, screen, button, args)
        -- HandleStorePurchase returns early for unaffordable or requirement-
        -- blocked clicks.  WellPurchases is incremented only after those
        -- guards, before the native award is applied.
        local currentRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local purchasesBefore = _G.CurrentRun and _G.CurrentRun.WellPurchases or nil
        local item = type(button) == "table" and (button.Data or button) or nil
        local priorTwistSelection = wellTwistSelection
        wellTwistSelection = type(item) == "table" and item.__runPlannerTwistResultKey or nil
        local ok, result = pcall(base, screen, button, args)
        wellTwistSelection = priorTwistSelection
        if not ok then error(result, 0) end
        local purchasesAfter = _G.CurrentRun and _G.CurrentRun.WellPurchases or nil
        if currentRoom ~= nil and type(purchasesBefore) == "number" and purchasesAfter == purchasesBefore + 1 then
            data.session.observeStygianWellPurchase(data.session.get(runtime), type(item) == "table" and (item.Name or item.ItemName) or nil)
        end
        writeStatus(runtime, data.session.get(runtime))
        return result
    end)
    moduleRef.hooks.wrap("GetRandomValue", "execution-well-twist-result", function(_, runtime, base, values, args)
        local target = wellTwistSelection
        if type(target) ~= "string" then return base(values, args) end
        if type(values) ~= "table" then return base(values, args) end
        for _, candidate in pairs(values) do
            if type(candidate) == "table" and candidate.Name == target then return candidate end
        end
        local state = data.session.get(runtime)
        data.session.recordWellTwistMismatch(state, target)
        -- A failed exact result freezes the suffix immediately. Do not let a
        -- later random-array contact in the same native purchase force it.
        wellTwistSelection = nil
        writeStatus(runtime, state)
        return base(values, args)
    end)
    moduleRef.hooks.wrap("HandleSellChoiceSelection", "execution-observe-pool-sale", function(_, runtime, base, screen, button, args)
        local result = base(screen, button, args)
        local traitKey = type(button) == "table" and button.UpgradeName or nil
        data.session.observePurgingPoolSale(data.session.get(runtime), traitKey)
        writeStatus(runtime, data.session.get(runtime))
        return result
    end)
    moduleRef.hooks.wrap("KeepsakeScreenClose", "execution-observe-keepsake-rack", function(_, runtime, base, screen, button)
        -- The rack interaction only opens its UI.  The selected key becomes
        -- authoritative at close, immediately before native EquipKeepsake.
        local key = _G.GameState and _G.GameState.LastAwardTrait or nil
        if type(screen) == "table" and screen.LastTrait ~= key then
            local state = data.session.get(runtime)
            data.session.beginKeepsakeRackChange(state, key)
            rackSelection = data.session.beginRackEquipResult(state)
        end
        local ok, result = pcall(base, screen, button)
        rackSelection = nil
        if not ok then error(result, 0) end
        data.session.verifyKeepsakeRackChange(
            data.session.get(runtime),
            _G.GameState and _G.GameState.LastAwardTrait or nil,
            _G.CurrentRun and _G.CurrentRun.Hero or nil
        )
        writeStatus(runtime, data.session.get(runtime))
        return result
    end)
    moduleRef.hooks.wrap("AddTraitToHero", "execution-keepsake-equip-result", function(_, runtime, base, args)
        local state = data.session.get(runtime)
        local result = base(args)
        data.session.verifyRackEquipResult(state, result)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("UseHealthFountain", "execution-observe-fountain", function(_, runtime, base, source, args)
        local state = data.session.get(runtime)
        -- Native use starts AddRarityToTraits on a thread, so arm the target
        -- before use and leave the trace pending until that thread verifies.
        data.session.observeFountainUse(state, nil)
        local result = base(source, args)
        if state.pendingPhialTarget == nil then data.session.completeFountainUse(state) end
        writeStatus(runtime, state)
        return result
    end)
    -- Each generated choice reaches this final pre-presentation seam.  Some
    -- screens bypass SetTraitsOnLoot, so this is the complete contact.
    moduleRef.hooks.wrap("CreateUpgradeChoiceButton", "execution-trait-offer", function(_, runtime, base, screen, lootData, itemIndex, itemData, args)
        local state = data.session.get(runtime)
        local prepared = data.session.prepareTraitOfferOption(state, itemIndex, itemData)
        if prepared.kind == "failed" then writeStatus(runtime, state) end
        local prior = chaosTraitProcessing
        chaosTraitProcessing = prepared.chaos
        local ok, result = pcall(base, screen, lootData, itemIndex, itemData, args)
        chaosTraitProcessing = prior
        if not ok then error(result, 0) end
        return result
    end)
    moduleRef.hooks.wrap("GetProcessedTraitData", "execution-chaos-trait-values", function(_, _, base, args)
        local result = base(args)
        local context = chaosTraitProcessing
        if context == nil or type(args) ~= "table" or type(result) ~= "table" then return result end
        if args.TraitName == context.curseKey then
            return data.session.applyProcessedChaosCurse(result, context)
        end
        if args.TraitName == context.blessingKey then
            return data.session.applyProcessedChaosBlessing(result, context)
        end
        return result
    end)
    moduleRef.hooks.wrap("HandleUpgradeChoiceSelection", "execution-observe-trait-selection", function(_, runtime, base, screen, button, args)
        local state = data.session.get(runtime)
        local seaStar = data.session.beginSeaStarDuplicate(state, type(screen) == "table" and screen.Source or nil)
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
        if seaStar then data.session.finishSeaStarDuplicate(state, screen.Source) end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("ConvertMetaRewardPresentation", "execution-artificer-source", function(_, runtime, base, target)
        local state = data.session.get(runtime)
        data.session.beginArtificerReplacement(state, target)
        local result = base(target)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("GetTotalHeroTraitValue", "execution-sea-star-gate", function(_, runtime, base, propertyName, args)
        local state = data.session.get(runtime)
        if propertyName == "DoubleRewardChance" then data.session.armSeaStarDuplicateRng(state) end
        return base(propertyName, args)
    end)
    moduleRef.hooks.wrap("RandomChance", "execution-sea-star-duplicate", function(_, runtime, base, chance, args)
        local state = data.session.get(runtime)
        if data.session.consumeSeaStarDuplicateRng(state) then return true end
        return base(chance, args)
    end)
    moduleRef.hooks.wrap("CreateLoot", "execution-sea-star-created-child", function(_, runtime, base, args)
        local result = base(args)
        local state = data.session.get(runtime)
        if echoLastRewardDepth > 0 then data.session.captureEchoLastReward(state, result) end
        data.session.captureSeaStarDuplicate(state, result)
        return result
    end)
    moduleRef.hooks.wrap("CreateConsumableItem", "execution-echo-created-consumable", function(_, runtime, base, ...)
        local result = base(...)
        if echoLastRewardDepth > 0 then data.session.captureEchoLastReward(data.session.get(runtime), result) end
        return result
    end)
    moduleRef.hooks.wrap("AddRarityToTraits", "execution-steady-growth", function(_, runtime, base, source, args)
        local state = data.session.get(runtime)
        local currentRun = _G.CurrentRun
        local hero = currentRun and currentRun.Hero
        local prepared = data.session.prepareSteadyGrowth(state, source, args, hero and hero.Traits)
        if prepared.kind == "passThrough" then
            prepared = data.session.preparePhialRarity(state, args, hero and hero.Traits)
        end
        if prepared.kind == "failed" then writeStatus(runtime, state) end
        local result = base(source, args)
        if prepared.kind == "handled" then
            if state.pendingPhialRarity ~= nil then data.session.verifyPhialRarity(state, hero and hero.Traits, result)
            else data.session.verifySteadyGrowth(state, hero and hero.Traits, result) end
        end
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
    moduleRef.hooks.wrap("GrantElementFromTool", "execution-resource-element", function(_, runtime, base, toolName, args)
        local state = data.session.get(runtime)
        local resource = data.session.beginResourceElementGrant(state, toolName)
        resourceElementGrant = resource
        local ok, result = pcall(base, toolName, args)
        resourceElementGrant = nil
        if not ok then error(result, 0) end
        data.session.verifyResourceElementGrant(state, resource, result)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("RandomChance", "execution-resource-element-chance", function(_, _, base, chance, rng)
        -- This flag is set only for GrantElementFromTool's synchronous native
        -- chance roll. Other game randomness remains untouched.
        if resourceElementGrant ~= nil then return true end
        return base(chance, rng)
    end)
    moduleRef.hooks.wrap("GetRandomArrayValue", "execution-embryo-choice", function(_, runtime, base, values, rng)
        -- This is deliberately scoped by AddRandomChaosBlessing's synchronous
        -- call. Other random arrays remain entirely vanilla-owned.
        if rackSelection ~= nil then
            local selected = data.session.selectRackEquipResult(data.session.get(runtime), values)
            if selected ~= nil then return selected end
        end
        if embryoSelection ~= nil and type(values) == "table" then
            for _, value in ipairs(values) do
                if value == embryoSelection then return value end
            end
        end
        return base(values, rng)
    end)
end

return logic
