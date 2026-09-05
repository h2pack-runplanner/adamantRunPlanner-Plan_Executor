-- luacheck: globals TestFeatureInteractionHooks
local lu = require("luaunit")
local roomCoordinatorModule = require("mods.room.coordinator")
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
    local completed, refilled
    local node = {
        owner = "travel-refill", kind = "wellRefill", generationKey = "travelDealRefill",
        offerKey = "ShopHermesUpgrade",
    }
    local refill = { transaction = node }
    local active = opaque({
        occurrence = { overview = { shop = {
            offers = { { offerKey = "Boon", optionKey = "BlindBoxLoot" } },
            travelDealRefill = {
                sourceOfferKey = "Boon", slotIndex = 0, optionKey = "ShopHermesUpgrade",
                reward = { rewardType = "ShopHermesUpgrade" },
            },
        } } },
    }, function(contact)
        if contact.kind == "generation" and contact.generationKey == "travelDealRefill" then return refill end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        lu.assertTrue(refilled)
        completed = { row = row }
        return true
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    callbacks.RestockWorldItem(nil, {}, function()
        refilled = true
        local generated = callbacks.FillInShopOptions(nil, {}, function(args)
            return { StoreOptions = { args.StoreData.GroupsOf[1].OptionsData[1] } }
        end, { StoreData = { GroupsOf = { { OptionsData = {
            { Name = "BlindBoxLoot" }, { Name = "ShopHermesUpgrade" },
        } } } } })
        local item = generated.StoreOptions[1]
        lu.assertEquals(item.__runPlannerOfferKey, "Boon")
        lu.assertEquals(item.__runPlannerGenerationKey, "travelDealRefill")
        callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 73 } end, item, 10)
    end, 1, 10, {})

    lu.assertEquals(fakePayload(completed.row).transaction.owner, "travel-refill")
end
