-- luacheck: globals TestFeatureInteractionHooks
local lu = require("luaunit")
local roomCoordinatorModule = require("mods.room.coordinator")
local json = require("mods.protocol.json")
local mysteryAcquisitions = require("mods.room.timeline.acquisitions.mystery.hooks")
local traitAcquisitions = require("mods.room.timeline.acquisitions.traits.hooks")
local logic = require("mods.runtime.composition")
local support = require("tests.harness.hook_composition")
local capture, stub, opaque = support.capture, support.stub, support.opaque
local fakePayload, attachFeatureHooks = support.fakePayload, support.attachFeatureHooks

TestFeatureInteractionHooks = {}

function TestFeatureInteractionHooks.testWorldShopCompletionUsesCurrentRoomPurchaseCounter()
    local module, _, callbacks = capture()
    local completed
    local node = { owner = "shop", kind = "shopPurchase", offerKey = "Boon" }
    local active = opaque({
        occurrence = { overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
        } } } },
    }, function(contact)
        if contact.kind == "offer" and contact.offerKey == "Boon" then return { transaction = node } end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        completed = { row = row }
        return true
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { StoreItemsPurchased = 0 }, StoreItemsPurchased = 99 }
    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        return { StoreOptions = { args.StoreData.GroupsOf[1].OptionsData[1] } }
    end, { StoreData = { GroupsOf = { { OptionsData = { { Name = "BlindBoxLoot" } } } } } })
    local itemData = generated.StoreOptions[1]
    lu.assertEquals(itemData.__runPlannerOfferKey, "Boon")
    local world = { ObjectId = 7 }
    callbacks.SpawnStoreItemInWorld(nil, {}, function() return world end, itemData, nil)
    callbacks.RemoveStoreItem(nil, {}, function()
        _G.CurrentRun.CurrentRoom.StoreItemsPurchased = _G.CurrentRun.CurrentRoom.StoreItemsPurchased + 1
    end, { Id = 7 })
    _G.CurrentRun = priorRun
    lu.assertEquals(fakePayload(completed.row).transaction.owner, "shop")
end

function TestFeatureInteractionHooks.testSuccessfulNativeKeepsakeEquipCompletesTheRackTransaction()
    local module, _, callbacks = capture()
    local completed
    local node = {
        owner = "rack", kind = "keepsakeChange", keepsakeKey = "GoldifyKeepsake",
        window = { kind = "standard", phase = "beforeCombat" }, equipResults = {},
    }
    local occurrence = { transactionsByOwner = { rack = node }, timeline = { dependencies = {}, obligations = {} } }
    local plan = { occurrencesById = { one = occurrence } }
    local state = { initialized = true, state = "synchronized", plan = plan, route = {} }
    state.room = roomCoordinatorModule.new(plan, function() end, {})
    assert(roomCoordinatorModule.enter(state, occurrence))
    local session = stub()
    session.defineCache = function() end
    session.get = function() return state end
    session.complete = function(_, handle)
        completed = { handle = handle }
        return true
    end
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    logic.attach(module, { session = session })
    callbacks.EquipKeepsake(nil, {}, function() return true end, {}, "GoldifyKeepsake", {})
    _G.import = priorImport

    lu.assertNotNil(completed.handle)
end

function TestFeatureInteractionHooks.testMysteryBoonPurchaseWaitsForItsTraitResolution()
    local module, _, callbacks = capture()
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    local completions = {}
    local node = {
        owner = "mystery", kind = "shopPurchase", offerKey = "Boon",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            { role = "box", lifecyclePoint = "purchase", gameName = "BlindBoxLoot" },
            {
                role = "hiddenSource", lifecyclePoint = "afterUnwrap", kind = "trait",
                disposition = "normal", gameName = "HeraUpgrade",
                traitOffer = {
                    kind = "traits", giver = "Hera", selected = "option1",
                    options = {
                        { key = "HeraCastBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraSprintBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraManaBoon", rarity = "Common", effectiveLevel = 4 },
                    },
                },
            },
        },
    }
    local occurrence = {
        id = "shop",
        overview = { shop = { offers = { { offerKey = "Boon", optionKey = "BlindBoxLoot" } } } },
        transactionsByOwner = { mystery = node },
        timeline = { transactions = { node }, dependencies = {}, obligations = {} },
    }
    local plan = { occurrencesById = { shop = occurrence } }
    local mismatches = {}
    local room = roomCoordinatorModule.new(plan, function(errorValue, expected, observed)
        mismatches[#mismatches + 1] = { error = errorValue, expected = expected, observed = observed }
    end)
    local state = { state = "synchronized", plan = plan, room = room }
    local active = assert(roomCoordinatorModule.enter(state, occurrence))
    local root = assert(roomCoordinatorModule.resolve(state, active, { kind = "offer", offerKey = "Boon" }))
    local box = { Name = "BlindBoxLoot" }
    local loot = { Name = "HeraUpgrade", GodLoot = true }
    local boxHandle = assert(roomCoordinatorModule.resolve(state, active,
        { kind = "materialized", gameName = box.Name, source = root }))
    lu.assertTrue(roomCoordinatorModule.bind(state, active, boxHandle, box) ~= nil)
    lu.assertNotNil(roomCoordinatorModule.peek(state, boxHandle))
    local session = {
        current = roomCoordinatorModule.current,
        peek = roomCoordinatorModule.peek,
        bind = roomCoordinatorModule.bind,
        bound = roomCoordinatorModule.bound,
        begin = roomCoordinatorModule.begin,
        resolve = roomCoordinatorModule.resolve,
        claimReady = roomCoordinatorModule.claimReady,
        mismatch = function() end,
    }
    session.complete = function(runtimeState, handle)
        completions[#completions + 1] = { handle = handle }
        return roomCoordinatorModule.complete(runtimeState, handle)
    end
    mysteryAcquisitions.attach(module, session, function() return state end, function() end, roomCoordinatorModule)
    local mysteryCallbacks = {
        CreateLoot = callbacks.CreateLoot,
        UseConsumableItem = callbacks.UseConsumableItem,
        ConsumableUsedPresentation = callbacks.ConsumableUsedPresentation,
        UnwrapRandomLoot = callbacks.UnwrapRandomLoot,
        GiveLoot = callbacks.GiveLoot,
    }
    for name, callback in pairs(mysteryCallbacks) do callbacks[name] = callback end
    traitAcquisitions.attach(module, session, function() return state end, function() end, roomCoordinatorModule)

    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        lu.assertTrue(callbacks.ConsumableUsedPresentation(nil, {}, function() return true end,
            _G.CurrentRun, nativeItem, {}))
        lu.assertNotNil(roomCoordinatorModule.peek(state, boxHandle))
        callbacks.UnwrapRandomLoot(nil, {}, function()
            callbacks.GiveLoot(nil, {}, function(args)
                lu.assertEquals(args.ForceLootName, "HeraUpgrade")
                return callbacks.CreateLoot(nil, {}, function() return loot end, { Name = args.ForceLootName })
            end, {})
        end, nativeItem)
    end, box, {}, {})
    lu.assertEquals(#completions, 0)
    lu.assertTrue(rawequal(roomCoordinatorModule.bound(state, active, loot), boxHandle))
    lu.assertEquals(roomCoordinatorModule.peek(state, boxHandle).detail, node.roles[2])
    callbacks.HandleLootPickup(nil, {}, function() end, _G.CurrentRun, loot, {})
    lu.assertEquals(#completions, 0)
    _G.CurrentRun.Hero.Traits = { { Name = "HeraCastBoon", Rarity = "Common", StackNum = 4 } }
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
        {}, { LootData = loot, Data = { Name = "HeraCastBoon" } }, {})
    lu.assertEquals(#completions, 1)
    lu.assertEquals(mismatches, {})
    _G.CurrentRun = priorRun
end

function TestFeatureInteractionHooks.testDestinationShopInventoryUsesTheNextOccurrenceBeforeRoomEntry()
    local module, _, callbacks = capture()
    local shop = opaque({
        occurrence = { id = "shop", overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
            { offerKey = "MajorNonBoon", optionKey = "ArmorBoost" },
            { offerKey = "Minor", optionKey = "MaxManaDrop" },
        } } } },
    }, function() return nil end)
    local session = stub()
    session.current = function() return nil end
    session.prepare = function(_, value)
        lu.assertEquals(value, shop.occurrence)
        return shop
    end
    local state = { route = {} }
    local route = { expected = function() return shop.occurrence end }
    attachFeatureHooks(module, session, function() return state end, function() end, session, route)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { __runPlannerExecutionRoomId = "shop" } }
    local result = callbacks.FillInShopOptions(nil, {}, function(args)
        local options = {}
        for _, group in ipairs(args.StoreData.GroupsOf) do options[#options + 1] = group.OptionsData[1] end
        return { StoreOptions = options }
    end, { StoreData = { GroupsOf = {
        { OptionsData = { { Name = "RandomLoot" }, { Name = "BlindBoxLoot" } } },
        { OptionsData = { { Name = "ArmorBoost" }, { Name = "MetaCurrencyDrop" } } },
        { OptionsData = { { Name = "StackUpgrade" }, { Name = "MaxManaDrop" } } },
    } } })
    _G.CurrentRun = priorRun

    lu.assertEquals(result.StoreOptions[1].Name, "BlindBoxLoot")
    lu.assertEquals(result.StoreOptions[2].Name, "ArmorBoost")
    lu.assertEquals(result.StoreOptions[3].Name, "MaxManaDrop")
end

function TestFeatureInteractionHooks.testProcessedWellButtonRetainsItsExactGenerationBinding()
    local module, _, callbacks = capture()
    local completed
    local node = {
        owner = "well-left", kind = "wellPurchase", generationKey = "initial:secondLeft",
        offerKey = "TemporaryEmptySlotDamageTrait", twistResultKey = nil,
    }
    local well = { transaction = node }
    local active = opaque({}, function(contact)
        if contact.kind == "generation" and contact.generationKey == "initial:secondLeft" then return well end
        if contact.kind == "offer" and contact.offerKey == "TemporaryEmptySlotDamageTrait" then return well end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        completed = { row = row }
        return true
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    local raw = {
        Name = "TemporaryEmptySlotDamageTrait",
        __runPlannerOfferKey = "TemporaryEmptySlotDamageTrait",
        __runPlannerGenerationKey = "initial:secondLeft",
    }
    local screen = { Components = {} }
    _G.CurrentRun = {
        WellPurchases = 0,
        CurrentRoom = { Store = { StoreOptions = { raw } } },
    }
    local priorTraitData, priorEligibility = _G.TraitData, _G.IsTraitEligible
    _G.TraitData = { TemporaryEmptySlotDamageTrait = {} }
    _G.IsTraitEligible = function() return true end
    callbacks.CreateStoreButtons(nil, {}, function(nativeScreen)
        local processed = { Name = "TemporaryEmptySlotDamageTrait", Type = "Trait", Processed = true }
        _G.CurrentRun.CurrentRoom.Store.StoreOptions[1] = processed
        nativeScreen.Components.PurchaseButton1 = { Data = processed }
    end, screen, false)

    local item = screen.Components.PurchaseButton1.Data
    lu.assertEquals(item.__runPlannerGenerationKey, "initial:secondLeft")
    callbacks.HandleStorePurchase(nil, {}, function()
        _G.CurrentRun.WellPurchases = _G.CurrentRun.WellPurchases + 1
    end, screen, screen.Components.PurchaseButton1, {})
    _G.TraitData, _G.IsTraitEligible = priorTraitData, priorEligibility
    _G.CurrentRun = priorRun

    lu.assertEquals(fakePayload(completed.row).transaction.owner, "well-left")
end

function TestFeatureInteractionHooks.testRejectedWellPurchaseReportsMismatchWithoutCompleting()
    local module, _, callbacks = capture()
    local completed, mismatch, nativeCalls = 0, 0, 0
    local node = {
        owner = "well-left", kind = "wellPurchase", generationKey = "initial:secondLeft",
        offerKey = "TemporaryEmptySlotDamageTrait", twistResultKey = nil,
    }
    local well = { transaction = node }
    local active = opaque({}, function(contact)
        if contact.kind == "generation" and contact.generationKey == "initial:secondLeft" then return well end
        if contact.kind == "offer" and contact.offerKey == "TemporaryEmptySlotDamageTrait" then return well end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function() completed = completed + 1 end
    session.mismatch = function() mismatch = mismatch + 1 end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    local priorTraitData, priorEligibility = _G.TraitData, _G.IsTraitEligible
    _G.TraitData = { TemporaryEmptySlotDamageTrait = {} }
    _G.IsTraitEligible = function() return false end
    _G.CurrentRun = {
        WellPurchases = 0,
        CurrentRoom = { Store = { StoreOptions = {
            { Name = "TemporaryEmptySlotDamageTrait", __runPlannerOfferKey = "TemporaryEmptySlotDamageTrait",
                __runPlannerGenerationKey = "initial:secondLeft" },
        } } },
    }
    local result = callbacks.HandleStorePurchase(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return true
    end, {}, { Data = _G.CurrentRun.CurrentRoom.Store.StoreOptions[1] }, {})
    _G.TraitData, _G.IsTraitEligible = priorTraitData, priorEligibility
    _G.CurrentRun = priorRun

    lu.assertTrue(result == nil or result == true)
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(completed, 0)
    lu.assertEquals(mismatch, 1)
end

function TestFeatureInteractionHooks.testTravelDealRefillKeepsSlotBindingSeparateFromReplacementItem()
    local module, _, callbacks = capture()
    local completed, begun, refilled = 0, 0, false
    local node = {
        owner = "travel-refill", kind = "acquisition", sourceOwner = "travel-refill-source",
        roles = { { role = "self", disposition = "normal", lifecyclePoint = "purchase",
            kind = "consumable", gameName = "ShopHermesUpgrade" } },
    }
    local refill = { transaction = node }
    local active = opaque({
        occurrence = { overview = { shop = {
            offers = { { offerKey = "Boon", optionKey = "BlindBoxLoot" } },
            travelDealRefill = {
                sourceOfferKey = "Boon", sourceOwner = "travel-refill-source",
                slotIndex = 1, groupIndex = 0,
                optionKey = "ShopHermesUpgrade",
                reward = { rewardType = "ShopHermesUpgrade" },
            },
        } } },
    }, function(contact)
        if contact.kind == "source" and contact.sourceOwner == "travel-refill-source" then return refill end
    end)
    local session = stub()
    session.current = function() return active end
    session.begin = function()
        begun = begun + 1
        return fakePayload(refill)
    end
    session.complete = function() completed = completed + 1 end
    local bindings = attachFeatureHooks(module, session, function() return {} end, function() end, session)

    callbacks.RestockWorldItem(nil, {}, function(index)
        refilled = true
        local generated = callbacks.FillInShopOptions(nil, {}, function(args)
            lu.assertEquals(#args.StoreData.GroupsOf, 1)
            lu.assertEquals(args.StoreData.GroupsOf[1].Offers, 1)
            lu.assertEquals(args.StoreData.GroupsOf[1].OptionsData, { { Name = "ShopHermesUpgrade" } })
            return { StoreOptions = { args.StoreData.GroupsOf[1].OptionsData[1] } }
        end, { StoreData = { GroupsOf = {
            { Offers = 2, OptionsData = {
                { Name = "BlindBoxLoot" }, { Name = "ShopHermesUpgrade" },
            } },
            { Offers = 1, OptionsData = { { Name = "MaxHealthDrop" } } },
        } } })
        local item = generated.StoreOptions[index]
        lu.assertEquals(item.__runPlannerOfferKey, "Boon")
        lu.assertEquals(item.__runPlannerGenerationKey, "travelDealRefill")
        lu.assertEquals(item.__runPlannerSourceOwner, "travel-refill-source")
        callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 73 } end, item, 10)
    end, 2, 10, {})

    lu.assertTrue(refilled)
    lu.assertEquals(fakePayload(bindings.find(73).handle).transaction.owner, "travel-refill")
    lu.assertEquals(begun, 0)
    lu.assertEquals(completed, 0)
end

function TestFeatureInteractionHooks.testWorldShopInventoryUsesThePublishedOfferSetAcrossQGroups()
    local module, _, callbacks = capture()
    local expected = {
        { offerKey = "Boon", optionKey = "BoostedRandomLoot" },
        { offerKey = "Minor", optionKey = "MaxManaDrop" },
        { offerKey = "Major", optionKey = "ArmorBoost" },
        { offerKey = "Hammer", optionKey = "WeaponUpgradeDrop" },
        { offerKey = "Talent", optionKey = "TalentDrop" },
        { offerKey = "Spell", optionKey = "SpellDrop" },
    }
    local active = opaque({ occurrence = { overview = { shop = { offers = expected } } } }, function()
        return nil
    end)
    local session = stub()
    session.current = function() return active end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        local options = {}
        for _, group in ipairs(args.StoreData.GroupsOf) do
            for _, option in ipairs(group.OptionsData or {}) do
                if option.Name == "BoostedRandomLoot" then
                    options[#options + 1] = {
                        Name = "RandomLoot",
                        Args = {
                            AddBoostedAnimation = true,
                            BoonRaritiesOverride = { Rare = 0.9 },
                        },
                    }
                else
                    options[#options + 1] = option
                end
            end
        end
        return { StoreOptions = options }
    end, { StoreData = { GroupsOf = {
        { OptionsData = {
            { Name = "BlindBoxLoot" }, { Name = "BoostedRandomLoot" },
            { Name = "MaxHealthDrop" },
        } },
        { OptionsData = { { Name = "MaxManaDrop" }, { Name = "StackUpgrade" } } },
        { OptionsData = { { Name = "ArmorBoost" }, { Name = "LastStandDrop" } } },
        { OptionsData = { { Name = "WeaponUpgradeDrop" }, { Name = "ChaosWeaponUpgrade" } } },
        { OptionsData = { { Name = "TalentDrop" }, { Name = "SpellDrop" } } },
    } } })

    lu.assertEquals(#generated.StoreOptions, #expected)
    for index, offer in ipairs(expected) do
        lu.assertEquals(generated.StoreOptions[index].Name,
            offer.optionKey == "BoostedRandomLoot" and "RandomLoot" or offer.optionKey)
        if offer.optionKey == "BoostedRandomLoot" then
            lu.assertTrue(generated.StoreOptions[index].Args.AddBoostedAnimation)
        end
        lu.assertEquals(generated.StoreOptions[index].__runPlannerOfferKey, offer.offerKey)
    end
end

function TestFeatureInteractionHooks.testWorldShopCarrierRetryReachesRemoveStoreItemOnlyAfterNativeAcceptance()
    local module, _, callbacks = capture()
    local completed, mismatch, nativeCalls = 0, 0, 0
    local node = { owner = "shop", kind = "shopPurchase", offerKey = "Boon" }
    local active = opaque({}, function(contact)
        if contact.kind == "offer" and contact.offerKey == "Boon" then return { transaction = node } end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function() completed = completed + 1 end
    session.mismatch = function() mismatch = mismatch + 1 end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { StoreItemsPurchased = 0 } }
    local item = { Name = "BlindBoxLoot", __runPlannerOfferKey = "Boon" }
    local world = callbacks.SpawnStoreItemInWorld(nil, {}, function()
        return { ObjectId = 11 }
    end, item, nil)
    callbacks.UseConsumableItem(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return false
    end, world, {}, {})
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(completed, 0)
    lu.assertEquals(mismatch, 0)

    callbacks.UseConsumableItem(nil, {}, function()
        nativeCalls = nativeCalls + 1
        callbacks.RemoveStoreItem(nil, {}, function()
            _G.CurrentRun.CurrentRoom.StoreItemsPurchased =
                _G.CurrentRun.CurrentRoom.StoreItemsPurchased + 1
        end, { Id = world.ObjectId })
        return true
    end, world, {}, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(nativeCalls, 2)
    lu.assertEquals(completed, 1)
    lu.assertEquals(mismatch, 0)
end

function TestFeatureInteractionHooks.testAcceptedUnpublishedWorldShopPurchaseReportsWithoutBlockingNative()
    local module, _, callbacks = capture()
    local completed, mismatches = 0, {}
    local node = { owner = "shop", kind = "shopPurchase", offerKey = "Boon" }
    local active = opaque({
        occurrence = { overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
            { offerKey = "Minor", optionKey = "MaxManaDrop" },
        } } } },
    }, function(contact)
        if contact.kind == "offer" and contact.offerKey == "Boon" then return { transaction = node } end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function() completed = completed + 1 end
    session.mismatch = function(_, checkpoint, expected, observed)
        mismatches[#mismatches + 1] = {
            checkpoint = checkpoint, expected = expected, observed = observed,
        }
    end
    local bindings = attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { StoreItemsPurchased = 0 } }
    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        return { StoreOptions = {
            args.StoreData.GroupsOf[1].OptionsData[1],
            args.StoreData.GroupsOf[2].OptionsData[1],
        } }
    end, { StoreData = { GroupsOf = {
        { OptionsData = { { Name = "BlindBoxLoot" } } },
        { OptionsData = { { Name = "MaxManaDrop" } } },
    } } })
    local item = generated.StoreOptions[2]
    local world = callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 14 } end,
        item, nil)
    lu.assertNotNil(bindings.find(world.ObjectId))
    lu.assertNil(bindings.find(world.ObjectId).handle)
    local result = callbacks.RemoveStoreItem(nil, {}, function()
        _G.CurrentRun.CurrentRoom.StoreItemsPurchased =
            _G.CurrentRun.CurrentRoom.StoreItemsPurchased + 1
        return "native-accepted"
    end, { Id = world.ObjectId })
    _G.CurrentRun = priorRun

    lu.assertEquals(result, "native-accepted")
    lu.assertEquals(completed, 0)
    lu.assertEquals(mismatches, { {
        checkpoint = "purchase-selection",
        expected = "authored Shop purchase",
        observed = "Minor",
    } })
end

function TestFeatureInteractionHooks.testInfernalContractUsesThePublishedFreePedestalInventory()
    local module, _, callbacks = capture()
    local sourceOwner = "acquisition-owner"
    local active = opaque({ occurrence = { overview = { shop = {
        offers = {}, infernalContract = { sourceOwner = sourceOwner, rewardType = "BlindBoxLoot" },
    } } } }, function(_contact)
        return nil
    end)
    local session = stub()
    session.current = function() return active end
    local bindings = attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = {} }
    callbacks.SpawnZagContractRewards(nil, {}, function()
        local generated = callbacks.FillInShopOptions(nil, {}, function(args)
            return { StoreOptions = { args.StoreData.GroupsOf[1].OptionsData[1] } }
        end, { StoreData = { GroupsOf = { { OptionsData = {
            { Name = "MetaCurrencyDrop" }, { Name = "BlindBoxLoot" },
        } } } } })
        lu.assertEquals(generated.StoreOptions[1].Name, "BlindBoxLoot")
        lu.assertEquals(generated.StoreOptions[1].__runPlannerContractSourceOwner, sourceOwner)
        callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 15 } end,
            generated.StoreOptions[1], nil)
        lu.assertNil(bindings.find(15))
    end, {}, {})
    _G.CurrentRun = priorRun
end

function TestFeatureInteractionHooks.testAnvilPurchaseBindsAndSteersNativeUpgrade()
    local module, _, callbacks = capture()
    local completed, mismatch = 0, 0
    local node = {
        owner = "anvil", kind = "shopPurchase", offerKey = "Anvil", rewardType = "ChaosWeaponUpgrade",
        anvilResult = { kind = "anvilOfFates", removedTraitKey = "HammerOld",
            addedTraitKeys = { "HammerNewA", "HammerNewB" } },
    }
    local active = opaque({ occurrence = { overview = { shop = { offers = {
        { offerKey = "Anvil", optionKey = "ChaosWeaponUpgrade", rewardType = "ChaosWeaponUpgrade" },
    } } } } }, function(contact)
        if contact.kind == "offer" and contact.offerKey == "Anvil" then return { transaction = node } end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function() completed = completed + 1 end
    session.mismatch = function() mismatch = mismatch + 1 end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { StoreItemsPurchased = 0 } }
    local item = { Name = "ChaosWeaponUpgrade", __runPlannerOfferKey = "Anvil" }
    local carrier = callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 12 } end, item, nil)

    callbacks.UseConsumableItem(nil, {}, function(_consumable)
        callbacks.RemoveStoreItem(nil, {}, function()
            _G.CurrentRun.CurrentRoom.StoreItemsPurchased =
                _G.CurrentRun.CurrentRoom.StoreItemsPurchased + 1
        end, { Id = carrier.ObjectId })
        return callbacks.ChaosHammerUpgrade(nil, {}, function()
            callbacks.RemoveRandomValue(nil, {}, function(values) return values[1] end,
                { { Name = "HammerOld" } }, {})
            callbacks.RemoveRandomValue(nil, {}, function(values) return values[1] end,
                { { Name = "HammerNewA" } }, {})
            callbacks.RemoveRandomValue(nil, {}, function(values) return values[1] end,
                { { Name = "HammerNewB" } }, {})
            return true
        end, {})
    end, carrier, {}, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(completed, 1)
    lu.assertEquals(mismatch, 0)
end

function TestFeatureInteractionHooks.testAnvilNullRemovalSteersTheFirstNativeAddition()
    local module, _, callbacks = capture()
    local completed, mismatch = 0, 0
    local node = {
        owner = "anvil", kind = "shopPurchase", offerKey = "Anvil", rewardType = "ChaosWeaponUpgrade",
        anvilResult = { kind = "anvilOfFates", removedTraitKey = json.null,
            addedTraitKeys = { "HammerNewA", "HammerNewB" } },
    }
    local active = opaque({}, function(contact)
        if contact.kind == "offer" and contact.offerKey == "Anvil" then return { transaction = node } end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function() completed = completed + 1 end
    session.mismatch = function() mismatch = mismatch + 1 end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { StoreItemsPurchased = 0 } }
    local item = { Name = "ChaosWeaponUpgrade", __runPlannerOfferKey = "Anvil" }
    local carrier = callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 13 } end, item, nil)
    callbacks.UseConsumableItem(nil, {}, function(_consumable)
        callbacks.RemoveStoreItem(nil, {}, function()
            _G.CurrentRun.CurrentRoom.StoreItemsPurchased =
                _G.CurrentRun.CurrentRoom.StoreItemsPurchased + 1
        end, { Id = carrier.ObjectId })
        return callbacks.ChaosHammerUpgrade(nil, {}, function()
            callbacks.RemoveRandomValue(nil, {}, function(values) return values[1] end,
                { { Name = "HammerNewA" } }, {})
            callbacks.RemoveRandomValue(nil, {}, function(values) return values[1] end,
                { { Name = "HammerNewB" } }, {})
            return true
        end, {})
    end, carrier, {}, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(completed, 1)
    lu.assertEquals(mismatch, 0)
end
