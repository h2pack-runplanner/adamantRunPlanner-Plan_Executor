-- luacheck: globals TestHookCompositionV10
local lu = require("luaunit")
local rooms = require("mods/hooks_rooms")
local timeline = require("mods/hooks_timeline")
local features = require("mods/hooks_features")

TestHookCompositionV10 = {}

local function capture()
    local names, callbacks = {}, {}
    return {
        hooks = {
            wrap = function(name, id, callback)
                names[name] = names[name] or {}
                names[name][id] = true
                callbacks[name] = callback
            end,
        },
    }, names, callbacks
end

local function stub()
    return {
        current = function() end,
        expectedOccurrence = function() end,
        additionalRoom = function() end,
        feature = function() end,
        mismatch = function() end,
    }
end

function TestHookCompositionV10.testDoorChoiceIsForcedDuringNativeGeneration()
    local module, _, callbacks = capture()
    local selected, proved
    local target = { room = { id = "next", gameName = "F_Next" }, reward = { rewardType = "Boon" } }
    local active = { occurrence = { doors = { kind = "batch", targets = { target } } } }
    local session = stub()
    session.current = function() return active end
    session.realizeDoors = function()
        return { { Room = { __runPlannerExecutionRoomId = "next", GenusName = "F_Next" } } }
    end
    session.proveDoors = function(_, doors)
        proved = doors
        return true
    end
    rooms.attach(module, session, function() return {} end, function() end, function() end)
    local priorMap, priorGame = _G.MapState, _G.game
    _G.MapState, _G.game = { OfferedExitDoors = { {} } }, { RoomData = {} }
    callbacks.DoUnlockRoomExits(nil, {}, function()
        selected = callbacks.ChooseNextRoomData(nil, {}, function() return nil end, {}, {}, {})
        return true
    end, {}, {})
    _G.MapState, _G.game = priorMap, priorGame
    lu.assertEquals(selected.__runPlannerExecutionRoomId, "next")
    lu.assertNotNil(proved)
end

function TestHookCompositionV10.testWorldShopCompletionUsesCurrentRoomPurchaseCounter()
    local module, _, callbacks = capture()
    local completed
    local node = { owner = "shop", kind = "shopPurchase", offerKey = "LastStandShopItem" }
    local active = { bindings = { offer = { LastStandShopItem = { node = node } }, generation = {}, native = {} } }
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row, verified)
        completed = { row = row, verified = verified }
        return true
    end
    features.attach(module, session, function() return {} end, function() end)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { StoreItemsPurchased = 0 }, StoreItemsPurchased = 99 }
    local itemData = { __runPlannerOfferKey = "LastStandShopItem", Name = "LastStandShopItem" }
    local world = { ObjectId = 7 }
    callbacks.SpawnStoreItemInWorld(nil, {}, function() return world end, itemData, nil)
    callbacks.RemoveStoreItem(nil, {}, function()
        _G.CurrentRun.CurrentRoom.StoreItemsPurchased = _G.CurrentRun.CurrentRoom.StoreItemsPurchased + 1
    end, { Id = 7 })
    _G.CurrentRun = priorRun
    lu.assertEquals(completed.row.node.owner, "shop")
    lu.assertTrue(completed.verified)
end

function TestHookCompositionV10.testSynchronousLootAndChaosChoiceCompleteBoundOwners()
    local module, _, callbacks = capture()
    local completed = {}
    local loot = { Name = "Onion" }
    local simple = { node = { owner = "onion" }, detail = { gameName = "Onion" } }
    local chaos = {
        node = {
            owner = "chaos",
            resolution = {
                kind = "traitOffer",
                offer = {
                    kind = "chaos", blessingKey = "ChaosBlessing", rarity = "Rare",
                    selected = "option1", curseOptions = { { curseKey = "ChaosCurse", requirementCount = 1 } },
                },
            },
        },
    }
    local active = { bindings = { native = { [loot] = simple } } }
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row, verified)
        completed[#completed + 1] = { row = row, verified = verified }
        return true
    end
    timeline.attach(module, session, function() return {} end, function() end)
    callbacks.UseLoot(nil, {}, function()
        callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    end, loot, {}, {})
    lu.assertEquals(completed[1].row.node.owner, "onion")
    lu.assertTrue(completed[1].verified)

    local chaosLoot = { Name = "ChaosBoon" }
    active.bindings.native[chaosLoot] = chaos
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    callbacks.UseLoot(nil, {}, function()
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function()
            _G.CurrentRun.Hero.Traits = { { Name = "ChaosBlessing", Rarity = "Rare" } }
        end, {}, { Data = { Name = "ChaosBlessing" } }, {})
    end, chaosLoot, {}, {})
    _G.CurrentRun = priorRun
    lu.assertEquals(completed[2].row.node.owner, "chaos")
    lu.assertTrue(completed[2].verified)
end

function TestHookCompositionV10.testStoreFallbackUsesNativeCarrierEligibilityAtGenerationAndPurchase()
    local module, _, callbacks = capture()
    local fallback = {
        availabilityContact = "storeInventoryGeneration",
        preferredKey = "LastStandShopItem", fallbackKey = "FallbackItem",
    }
    local purchaseFallback = {
        availabilityContact = "storePurchase",
        preferredKey = "LastStandShopItem", fallbackKey = "FallbackItem",
    }
    local node = { owner = "shop", kind = "shopPurchase", offerKey = "shop", runtimeFallbacks = { purchaseFallback } }
    local active = {
        occurrence = { overview = { shop = { offers = {
            { offerKey = "shop", optionKey = "LastStandShopItem", slotIndex = 0, runtimeFallbacks = { fallback } },
        } } } },
        bindings = { offer = { shop = { node = node } }, generation = {}, native = {} },
    }
    local mismatches, completed = {}, {}
    local session = stub()
    session.current = function() return active end
    session.resolveFallback = function(_, row, _, relation, available)
        local key = available(relation.preferredKey) and relation.preferredKey
            or available(relation.fallbackKey) and relation.fallbackKey or nil
        if key == nil then
            mismatches[#mismatches + 1] = relation
            return nil
        end
        row.realizedKey = key
        return key, row
    end
    session.complete = function(_, row, verified)
        completed[#completed + 1] = { row = row, verified = verified }
        return true
    end
    features.attach(module, session, function() return {} end, function() end)
    local priorTraits, priorConsumables = _G.TraitData, _G.ConsumableData
    local priorStoreEligible, priorStateEligible = _G.StoreItemEligible, _G.IsGameStateEligible
    _G.TraitData = {}
    _G.ConsumableData = {
        LastStandShopItem = { Name = "LastStandShopItem", PurchaseRequirements = { missing = "lastStand" } },
        FallbackItem = { Name = "FallbackItem", UseFunctionNames = { "FallbackUse" } },
    }
    _G.StoreItemEligible = function(item) return item.Name == "FallbackItem" end
    _G.IsGameStateEligible = function(item, requirements)
        return item.Name == "FallbackItem" or requirements == nil
    end
    local generated
    callbacks.FillInShopOptions(nil, {}, function(args)
        generated = args.StoreData.GroupsOf[1].OptionsData[1].Name
        return { StoreOptions = { { Name = "FallbackItem" } } }
    end, { StoreData = { GroupsOf = { { OptionsData = {
        { Name = "LastStandShopItem" }, { Name = "FallbackItem" },
    } } } } })
    lu.assertEquals(generated, "FallbackItem")

    local item = {
        __runPlannerOfferKey = "shop", Name = "LastStandShopItem", Index = 2,
        ResourceCosts = { Money = 200 },
    }
    callbacks.HandleStorePurchase(nil, {}, function(_, button)
        lu.assertEquals(button.Data.Name, "FallbackItem")
        lu.assertEquals(button.Data.UseFunctionNames, { "FallbackUse" })
        lu.assertEquals(button.Data.__runPlannerOfferKey, "shop")
    end, {}, { Data = item }, {})
    lu.assertTrue(completed[1].verified)

    _G.StoreItemEligible = function() return false end
    callbacks.FillInShopOptions(nil, {}, function() return { StoreOptions = {} } end, {
        StoreData = { GroupsOf = { { OptionsData = {
            { Name = "LastStandShopItem" }, { Name = "FallbackItem" },
        } } } },
    })
    _G.TraitData, _G.ConsumableData = priorTraits, priorConsumables
    _G.StoreItemEligible, _G.IsGameStateEligible = priorStoreEligible, priorStateEligible
    lu.assertEquals(#mismatches, 1)
end

function TestHookCompositionV10.testExplicitGateBHookGroupsStayInstalled()
    local module, names = capture()
    local session = stub()
    rooms.attach(module, session, function() end, function() end, function() end)
    timeline.attach(module, session, function() end, function() end)
    features.attach(module, session, function() end, function() end)
    for _, name in ipairs({
        "ChooseStartingRoom", "StartRoomPreLoadBinks", "DoUnlockRoomExits", "LeaveRoom",
        "UseLoot", "HandleLootPickup", "ConvertMetaRewardPresentation", "CreateLoot",
        "NarcissusBenefitChoice", "SpawnNemesisForRandomEvents", "CheckAvailableTextLines",
        "NemesisTradeChoice", "NPCRewardDropPreProcess", "NPCRewardDropPreProcessArgs", "NemesisDamageContestTimer",
        "AddRandomMetaUpgrades", "FillInShopOptions", "RestockWorldItem",
        "SpawnStoreItemInWorld", "RemoveStoreItem", "HandleStorePurchase",
    }) do
        lu.assertNotNil(names[name], name)
    end
end
