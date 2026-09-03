-- luacheck: globals TestHookCompositionV10
local lu = require("luaunit")
local rooms = require("mods/hooks_rooms")
local timeline = require("mods/hooks_timeline")
local features = require("mods/hooks_features")
local logic = require("mods/logic")

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
        proveOverview = function() end,
        additionalRoom = function() end,
        feature = function() end,
        mismatch = function() end,
        expectRewardSelection = function() end,
        takeRewardSelection = function() end,
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
    rooms.attach(module, session, function() return { state = "synchronized" } end, function() end)
    local priorMap, priorGame, priorCollapse = _G.MapState, _G.game, _G.CollapseTableOrdered
    local physicalDoor = { ObjectId = 101 }
    _G.MapState, _G.game = { OfferedExitDoors = { [101] = physicalDoor } }, { RoomData = {} }
    _G.CollapseTableOrdered = function(values)
        lu.assertEquals(values[101], physicalDoor)
        return { physicalDoor }
    end
    callbacks.DoUnlockRoomExits(nil, {}, function()
        selected = callbacks.ChooseNextRoomData(nil, {}, function() return nil end, {}, {}, {})
        return true
    end, {}, {})
    _G.MapState, _G.game, _G.CollapseTableOrdered = priorMap, priorGame, priorCollapse
    lu.assertEquals(selected.__runPlannerExecutionRoomId, "next")
    lu.assertNotNil(proved)
end

function TestHookCompositionV10.testChaosDoorIsExcludedAfterNormalDoorGeneration()
    local module, _, callbacks = capture()
    local additional = {
        owner = "chaos-exit", kind = "chaos",
        room = { id = "chaos", gameName = "Chaos_01" },
    }
    local occurrence = {
        id = "opening", overview = { additional = { additional } },
        doors = { kind = "batch", targets = {
            { room = { id = "next", gameName = "F_Next" } },
        } },
    }
    local active = { occurrence = occurrence }
    local proved
    local session = stub()
    session.current = function() return active end
    session.realizeDoors = function(_, nativeDoors)
        lu.assertEquals(#nativeDoors, 1)
        return { { Room = { __runPlannerExecutionRoomId = "next", GenusName = "F_Next" } } }
    end
    session.proveDoors = function(_, nativeDoors)
        proved = nativeDoors
        return true
    end
    rooms.attach(module, session, function() return { state = "synchronized" } end, function() end)

    local normalDoor = { ObjectId = 101 }
    local chaosRoom = {
        Name = "Chaos_01", __runPlannerExecutionRoomId = "chaos",
        __runPlannerExecutionAdditionalOwner = "chaos-exit",
        __runPlannerExecutionAdditionalKind = "chaos",
    }
    local chaosDoor = {
        ObjectId = 102, Room = chaosRoom,
        __runPlannerExecutionAdditionalOwner = "chaos-exit",
        __runPlannerExecutionAdditionalKind = "chaos",
    }
    local priorMap, priorCollapse = _G.MapState, _G.CollapseTableOrdered
    _G.MapState = { OfferedExitDoors = { [101] = normalDoor, [102] = chaosDoor } }
    _G.CollapseTableOrdered = function() return { normalDoor, chaosDoor } end
    callbacks.DoUnlockRoomExits(nil, {}, function()
        normalDoor.Room = callbacks.ChooseNextRoomData(nil, {}, function() return nil end, {}, {}, {})
        return true
    end, {}, {})
    _G.MapState, _G.CollapseTableOrdered = priorMap, priorCollapse

    lu.assertEquals(#proved, 1)
    lu.assertEquals(proved[1], normalDoor)
end

function TestHookCompositionV10.testRoomSessionStartsBeforeNativeFeatureSpawns()
    local module, _, callbacks = capture()
    local entered, proved = false, false
    local additional = { room = { id = "chaos", gameName = "Chaos_01" } }
    local session = stub()
    session.expectedOccurrence = function()
        return { id = "opening", gameName = "F_Opening01" }
    end
    session.enter = function(_, id, gameName, nativeRoom)
        entered = true
        lu.assertEquals(id, "opening")
        lu.assertEquals(gameName, "F_Opening01")
        lu.assertNil(nativeRoom)
    end
    session.additionalRoom = function()
        if entered then return additional.room, additional end
        return nil
    end
    session.proveOverview = function(_, nativeRoom)
        proved = true
        lu.assertEquals(nativeRoom.__runPlannerExecutionRoomId, "opening")
        return true
    end
    rooms.attach(module, session, function() return { state = "synchronized" } end, function() end)

    local room = { Name = "F_Opening01", __runPlannerExecutionRoomId = "opening" }
    local eligible
    callbacks.StartRoom(nil, {}, function()
        callbacks.HandleSecretSpawns(nil, {}, function()
            eligible = callbacks.IsSecretDoorEligible(nil, {}, function() return false end, {}, room)
        end, {})
    end, {}, room)

    lu.assertTrue(entered)
    lu.assertTrue(proved)
    lu.assertTrue(eligible)
end

function TestHookCompositionV10.testZagreusContractRemainsAnAdditionalDoorDuringNormalDoorProof()
    local module, _, callbacks = capture()
    local additional = {
        owner = "contract-exit", kind = "zagreusContract",
        room = { id = "contract", gameName = "C_Boss01" },
    }
    local occurrence = {
        id = "shop",
        overview = { additional = { additional } },
        doors = { kind = "batch", targets = {
            { room = { id = "one", gameName = "F_One" } },
            { room = { id = "two", gameName = "F_Two" } },
        } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = {
        shop = occurrence,
        contract = { id = "contract", gameName = "C_Boss01", overview = {} },
    } } }
    local active = { occurrence = occurrence }
    local proved
    local session = stub()
    session.current = function() return active end
    session.additionalRoom = function() return { Name = "C_Boss01" }, additional end
    session.realizeOccurrence = function(_, id)
        return { Name = "C_Boss01", GenusName = "C_Boss01", __runPlannerExecutionRoomId = id }
    end
    session.realizeDoors = function(_, nativeDoors)
        lu.assertEquals(#nativeDoors, 2)
        return nativeDoors
    end
    session.proveDoors = function(_, nativeDoors)
        proved = nativeDoors
        return true
    end
    rooms.attach(module, session, function() return state end, function() end)

    local contractRoom
    local contractDoor = { ObjectId = 3 }
    callbacks.SpawnZagContract(nil, {}, function()
        contractRoom = callbacks.CreateRoom(nil, {}, function(roomData) return roomData end,
            { Name = "C_Boss01" }, {})
        callbacks.AssignRoomToExitDoor(nil, {}, function(door, room)
            door.Room = room
        end, contractDoor, contractRoom)
    end, {}, {})
    lu.assertEquals(contractRoom.__runPlannerExecutionAdditionalOwner, "contract-exit")
    lu.assertEquals(contractRoom.__runPlannerExecutionAdditionalKind, "zagreusContract")
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalOwner, "contract-exit")
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalKind, "zagreusContract")

    local priorMap, priorCollapse = _G.MapState, _G.CollapseTableOrdered
    _G.MapState = { OfferedExitDoors = {
        { Room = { Name = "F_One" } },
        { Room = { Name = "F_Two" } },
        contractDoor,
    } }
    _G.CollapseTableOrdered = function(value) return value end
    callbacks.DoUnlockRoomExits(nil, {}, function() return true end, {}, {})
    _G.MapState, _G.CollapseTableOrdered = priorMap, priorCollapse

    lu.assertEquals(#proved, 2)
end

function TestHookCompositionV10.testEncounterForcingKeepsNativeSetupAndGeneration()
    local module, _, callbacks = capture()
    local declaration = { Name = "OpeningGeneratedF", Generated = true }
    local occurrence = {
        id = "opening",
        overview = { encounterPhases = { { slotKey = "Encounter", encounterKey = "OpeningGeneratedF" } } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { opening = occurrence } } }
    local session = stub()
    local priorGame, priorGlobalForce = _G.game, _G.ForceNextEncounter
    _G.game = { EncounterData = { OpeningGeneratedF = declaration } }
    _G.ForceNextEncounter = "DebugEncounter"
    rooms.attach(module, session, function() return state end, function() end)

    local run = { ForceNextEncounterData = { Name = "PriorEncounter" } }
    local nativeRoom = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseEncounter(nil, {}, function(currentRun, room, args)
        lu.assertEquals(currentRun.ForceNextEncounterData, declaration)
        lu.assertNil(_G.ForceNextEncounter)
        lu.assertEquals(room, nativeRoom)
        -- Witness the native ChooseEncounter -> SetupEncounter result rather
        -- than accepting the raw EncounterData declaration.
        return { Name = declaration.Name, GeneratedWaves = true, Args = args }
    end, run, nativeRoom, { Source = "test" })

    lu.assertTrue(result.GeneratedWaves)
    lu.assertEquals(result.Args.Source, "test")
    lu.assertEquals(run.ForceNextEncounterData.Name, "PriorEncounter")
    lu.assertEquals(_G.ForceNextEncounter, "DebugEncounter")
    _G.game, _G.ForceNextEncounter = priorGame, priorGlobalForce
end

function TestHookCompositionV10.testRoomRewardForcingConsumesTheMatchingNativeBagEntry()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening",
        overview = { incomingReward = { rewardType = "WeaponUpgrade" } },
    }
    local state = {
        state = "synchronized",
        plan = { occurrencesById = { opening = occurrence } },
    }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    rooms.attach(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = {},
        RewardStores = {
            RunProgress = { { Name = "Boon" }, { Name = "WeaponUpgrade" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, _, rewardStoreName)
        local selected
        for index, reward in ipairs(currentRun.RewardStores[rewardStoreName]) do
            if callbacks.IsRoomRewardEligible(nil, {}, function() return true end, currentRun, room, reward, {}, {}) then
                selected = index
                break
            end
        end
        local reward = currentRun.RewardStores[rewardStoreName][selected]
        table.remove(currentRun.RewardStores[rewardStoreName], selected)
        return reward.Name
    end, run, room, "RunProgress", {}, {})

    lu.assertEquals(result, "WeaponUpgrade")
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "Boon" } })
end

function TestHookCompositionV10.testPublishedRewardStoreOverridesAStaleNativeStore()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "target",
        overview = {
            incomingReward = {
                rewardType = "MetaCurrencyDrop",
                resolvedStoreKey = "MetaProgress",
            },
        },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { target = occurrence } } }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    rooms.attach(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = { "MetaCardPointsCommonDrop", "MetaCurrencyDrop", "Boon" },
        RewardStores = {
            RunProgress = { { Name = "HermesUpgrade" } },
            MetaProgress = { { Name = "MetaCardPointsCommonDrop" }, { Name = "MetaCurrencyDrop" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "target", RewardStoreName = "RunProgress" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, nativeRoom, rewardStoreName)
        lu.assertEquals(rewardStoreName, "MetaProgress")
        lu.assertEquals(nativeRoom.RewardStoreName, "MetaProgress")
        local eligible = {}
        for index, reward in ipairs(currentRun.RewardStores[rewardStoreName]) do
            if callbacks.IsRoomRewardEligible(nil, {}, function()
                -- The native eligibility result is deliberately hostile: the
                -- published reward must own this scoped choice regardless.
                return false
            end, currentRun, nativeRoom, reward, {}, {}) then
                eligible[#eligible + 1] = index
            end
        end
        lu.assertEquals(eligible, { 2 })
        local selected = eligible[1]
        local reward = currentRun.RewardStores[rewardStoreName][selected]
        table.remove(currentRun.RewardStores[rewardStoreName], selected)
        return reward.Name
    end, run, room, "RunProgress", {}, {})

    lu.assertEquals(result, "MetaCurrencyDrop")
    lu.assertEquals(run.RewardStores.MetaProgress, { { Name = "MetaCardPointsCommonDrop" } })
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "HermesUpgrade" } })
    lu.assertEquals(run.RewardPriorities, { "MetaCardPointsCommonDrop", "MetaCurrencyDrop", "Boon" })
end

function TestHookCompositionV10.testContractTraitAcquisitionDoesNotOwnTheNativeMetaRewardChoice()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "contract",
        overview = { incomingReward = { rewardType = "InfernalContractBoon" } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { contract = occurrence } } }
    local mismatches = {}
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    session.mismatch = function(_, checkpoint) mismatches[#mismatches + 1] = checkpoint end
    rooms.attach(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "contract", ForcedReward = "GemPointsBigDrop" }
    local result = callbacks.ChooseRoomReward(nil, {}, function()
        return "GemPointsBigDrop"
    end, {}, room, "MetaProgress", {}, {})

    lu.assertEquals(result, "GemPointsBigDrop")
    lu.assertEquals(mismatches, {})
end

function TestHookCompositionV10.testEffectNeutralBossRewardUsesNativeForcedRewardChoice()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "boss",
        overview = { effectNeutralRequiredReward = true },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { boss = occurrence } } }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    rooms.attach(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "boss", ForcedReward = "MixerFBossDrop" }
    local baseCalled = false
    local result = callbacks.ChooseRoomReward(nil, {}, function(_, nativeRoom)
        baseCalled = true
        return nativeRoom.ForcedReward
    end, {}, room, "RunProgress", {}, {})

    lu.assertTrue(baseCalled)
    lu.assertEquals(result, "MixerFBossDrop")
end

function TestHookCompositionV10.testProducedRewardSelectionDoesNotReuseTheIncomingMinorStore()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "target",
        overview = {
            incomingReward = {
                rewardType = "MetaCurrencyDrop",
                resolvedStoreKey = "MetaProgress",
            },
        },
    }
    local produced = {
        node = {
            owner = "artificer-boon",
            reward = { rewardType = "Boon", source = "ZeusUpgrade" },
        },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { target = occurrence } } }
    local pending = produced
    local session = stub()
    session.takeRewardSelection = function()
        local result = pending
        pending = nil
        return result
    end
    rooms.attach(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = {},
        RewardStores = {
            RunProgress = { { Name = "Boon" }, { Name = "WeaponUpgrade" } },
            MetaProgress = { { Name = "MetaCurrencyDrop" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "target", RewardStoreName = "MetaProgress" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, nativeRoom, rewardStoreName)
        lu.assertEquals(rewardStoreName, "RunProgress")
        lu.assertEquals(nativeRoom.RewardStoreName, "RunProgress")
        local selected
        for index, reward in ipairs(currentRun.RewardStores[rewardStoreName]) do
            if callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                currentRun, nativeRoom, reward, {}, {}) then
                selected = index
                break
            end
        end
        local reward = currentRun.RewardStores[rewardStoreName][selected]
        table.remove(currentRun.RewardStores[rewardStoreName], selected)
        return reward.Name
    end, run, room, "RunProgress", {}, { IgnoreForcedReward = true })

    lu.assertEquals(result, "Boon")
    lu.assertEquals(room.ForceLootName, "ZeusUpgrade")
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "WeaponUpgrade" } })
    lu.assertEquals(run.RewardStores.MetaProgress, { { Name = "MetaCurrencyDrop" } })
    lu.assertNil(pending)
end

function TestHookCompositionV10.testArtificerConversionQueuesItsPublishedProducedReward()
    local module, _, callbacks = capture()
    local target = { ObjectId = 19, Name = "MetaCurrencyDrop" }
    local source = {
        node = {
            owner = "minor-source",
            sourceOwner = "incoming-reward",
            roles = {
                { role = "self", lifecyclePoint = "roomRewardPickup", gameName = "MetaCurrencyDrop" },
            },
        },
        detail = { role = "self", gameName = "MetaCurrencyDrop" },
    }
    local child = {
        node = { owner = "artificer-boon", reward = { rewardType = "Boon", source = "ZeusUpgrade" } },
        detail = { producer = { kind = "artificerReplacement" } },
    }
    local active = {
        bindings = {
            native = { [target] = source },
            produced = { ["incoming-reward\0self"] = child },
        },
    }
    local queued, completed
    local session = stub()
    session.current = function() return active end
    session.expectRewardSelection = function(_, row) queued = row end
    session.complete = function(_, row, verified)
        completed = { row = row, verified = verified }
        return true
    end
    timeline.attach(module, session, function() return {} end, function() end)

    local called = false
    callbacks.ConvertMetaRewardPresentation(nil, {}, function(value)
        called = value == target
        return "converted"
    end, target)

    lu.assertTrue(called)
    lu.assertEquals(queued, child)
    lu.assertEquals(completed.row, source)
    lu.assertTrue(completed.verified)
end

function TestHookCompositionV10.testRewardSourceUsesTheTargetOccurrenceNotTheCurrentRoom()
    local module, _, callbacks = capture()
    local current = {
        id = "current",
        overview = { incomingReward = { rewardType = "Boon", source = "ApolloUpgrade" } },
    }
    local target = {
        id = "target",
        overview = { incomingReward = { rewardType = "Boon", source = "ZeusUpgrade" } },
    }
    local state = {
        plan = { occurrencesById = { current = current, target = target } },
    }
    local session = stub()
    session.current = function() return { occurrence = current } end
    timeline.attach(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "target" }
    callbacks.SetupRoomReward(nil, {}, function(_, nativeRoom)
        nativeRoom.ForceLootName = "RandomUpgrade"
        return true
    end, {}, room, {}, {})

    lu.assertEquals(room.ForceLootName, "ZeusUpgrade")
end

function TestHookCompositionV10.testWorldShopCompletionUsesCurrentRoomPurchaseCounter()
    local module, _, callbacks = capture()
    local completed
    local node = { owner = "shop", kind = "shopPurchase", offerKey = "Boon" }
    local active = {
        occurrence = { overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
        } } } },
        bindings = { offer = { Boon = { node = node } }, generation = {}, native = {} },
    }
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row, verified)
        completed = { row = row, verified = verified }
        return true
    end
    features.attach(module, session, function() return {} end, function() end)
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
    lu.assertEquals(completed.row.node.owner, "shop")
    lu.assertTrue(completed.verified)
end

function TestHookCompositionV10.testSuccessfulNativeKeepsakeEquipCompletesTheRackTransaction()
    local module, _, callbacks = capture()
    local completed
    local node = { owner = "rack", kind = "keepsakeChange", keepsakeKey = "GoldifyKeepsake" }
    local row = { node = node }
    local active = {
        occurrence = { transactionsByOwner = { rack = node } },
        bindings = {
            keepsake = { GoldifyKeepsake = row }, owner = { rack = row }, native = {},
        },
    }
    local state = { initialized = true }
    local session = stub()
    session.defineCache = function() end
    session.get = function() return state end
    session.current = function() return active end
    session.complete = function(_, actualRow, verified)
        completed = { row = actualRow, verified = verified }
        return true
    end
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    logic.attach(module, { session = session })
    callbacks.EquipKeepsake(nil, {}, function() return true end, {}, "GoldifyKeepsake", {})
    _G.import = priorImport

    lu.assertEquals(completed.row, row)
    lu.assertTrue(completed.verified)
end

function TestHookCompositionV10.testMysteryBoonPurchaseWaitsForItsTraitResolution()
    local module, _, callbacks = capture()
    local completed = 0
    local node = {
        owner = "mystery", kind = "shopPurchase", offerKey = "Boon",
        roles = {
            { role = "box", lifecyclePoint = "purchase", gameName = "BlindBoxLoot" },
            {
                role = "hiddenSource", lifecyclePoint = "afterUnwrap", gameName = "HeraUpgrade",
                traitOffer = { kind = "traits", giver = "Hera", options = {}, selected = "option1" },
            },
        },
    }
    local active = {
        occurrence = { id = "shop", overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
        } } } },
        bindings = { offer = { Boon = { node = node } }, generation = {}, native = {} },
    }
    local session = stub()
    session.current = function() return active end
    session.complete = function() completed = completed + 1 end
    features.attach(module, session, function() return {} end, function() end)
    timeline.attach(module, session, function() return {} end, function() end)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = {
        CurrentRoom = {
            __runPlannerExecutionRoomId = "shop", StoreItemsPurchased = 0,
            Store = { StoreOptions = {} },
        },
    }
    local item = { Name = "BlindBoxLoot", __runPlannerOfferKey = "Boon" }
    local world = { ObjectId = 8 }
    callbacks.SpawnStoreItemInWorld(nil, {}, function() return world end, item, nil)
    callbacks.RemoveStoreItem(nil, {}, function()
        _G.CurrentRun.CurrentRoom.StoreItemsPurchased = 1
    end, { Id = 8 })
    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, _G.CurrentRun, nativeItem, {})
    end, world, {}, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(completed, 0)
end

function TestHookCompositionV10.testDestinationShopInventoryUsesTheNextOccurrenceBeforeRoomEntry()
    local module, _, callbacks = capture()
    local shop = {
        occurrence = { id = "shop", overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
            { offerKey = "MajorNonBoon", optionKey = "ArmorBoost" },
            { offerKey = "Minor", optionKey = "MaxManaDrop" },
        } } } },
        bindings = { offer = {}, generation = {}, native = {} },
    }
    local session = stub()
    session.current = function() return nil end
    session.prepareOccurrence = function(_, id)
        lu.assertEquals(id, "shop")
        return shop
    end
    features.attach(module, session, function() return {} end, function() end)

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

function TestHookCompositionV10.testProcessedWellButtonRetainsItsExactGenerationBinding()
    local module, _, callbacks = capture()
    local completed
    local node = {
        owner = "well-left", kind = "wellPurchase", generationKey = "initial:secondLeft",
        offerKey = "TemporaryEmptySlotDamageTrait", twistResultKey = nil,
    }
    local active = {
        bindings = {
            generation = { ["initial:secondLeft"] = { node = node } },
            offer = { TemporaryEmptySlotDamageTrait = { node = node } }, native = {},
        },
    }
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row, verified)
        completed = { row = row, verified = verified }
        return true
    end
    features.attach(module, session, function() return {} end, function() end)

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
    _G.CurrentRun = priorRun

    lu.assertEquals(completed.row.node.owner, "well-left")
    lu.assertTrue(completed.verified)
end

function TestHookCompositionV10.testTravelDealRefillKeepsSlotBindingSeparateFromReplacementItem()
    local module, _, callbacks = capture()
    local completed
    local node = {
        owner = "travel-refill", kind = "wellRefill", generationKey = "travelDealRefill",
        offerKey = "ShopHermesUpgrade",
    }
    local active = {
        occurrence = { overview = { shop = {
            offers = { { offerKey = "Boon", optionKey = "BlindBoxLoot" } },
            travelDealRefill = {
                sourceOfferKey = "Boon", slotIndex = 0, optionKey = "ShopHermesUpgrade",
                reward = { rewardType = "ShopHermesUpgrade" },
            },
        } } },
        bindings = {
            generation = { travelDealRefill = { node = node } }, offer = {}, native = {},
        },
    }
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row, verified)
        completed = { row = row, verified = verified }
        return true
    end
    features.attach(module, session, function() return {} end, function() end)

    callbacks.RestockWorldItem(nil, {}, function()
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

    lu.assertEquals(completed.row.node.owner, "travel-refill")
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
                    kind = "chaos", blessingKey = "ChaosSpeedBlessing", rarity = "Rare",
                    blessingValues = {}, selectedCurseValues = {}, selected = "option1",
                    curseOptions = { { curseKey = "ChaosNoMoneyCurse", requirementCount = 1 } },
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
            _G.CurrentRun.Hero.Traits = { {
                Name = "ChaosNoMoneyCurse", RemainingUses = 1,
                OnExpire = { TraitData = { Name = "ChaosSpeedBlessing", Rarity = "Rare" } },
            } }
        end, {}, { Data = { Name = "ChaosNoMoneyCurse" } }, {})
    end, chaosLoot, {}, {})
    _G.CurrentRun = priorRun
    lu.assertEquals(completed[2].row.node.owner, "chaos")
    lu.assertTrue(completed[2].verified)
end

function TestHookCompositionV10.testMysteryBoonBindsItsUnwrappedSourceTraitOffer()
    local module, _, callbacks = capture()
    local box = { Name = "BlindBoxLoot" }
    local loot = { Name = "HeraUpgrade" }
    local node = {
        owner = "mystery-boon",
        kind = "shopPurchase",
        roles = {
            { role = "box", lifecyclePoint = "purchase", gameName = "BlindBoxLoot" },
            {
                role = "hiddenSource", lifecyclePoint = "afterUnwrap", gameName = "HeraUpgrade",
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
    local active = { bindings = { native = { [box] = { node = node } } } }
    local session = stub()
    session.current = function() return active end
    timeline.attach(module, session, function() return {} end, function() end)

    callbacks.UnwrapRandomLoot(nil, {}, function()
        callbacks.GiveLoot(nil, {}, function(args)
            lu.assertEquals(args.ForceLootName, "HeraUpgrade")
            return callbacks.CreateLoot(nil, {}, function() return loot end, { Name = args.ForceLootName })
        end, {})
    end, box)
    callbacks.UseLoot(nil, {}, function()
        lu.assertEquals(loot.UpgradeOptions, {
            { ItemName = "HeraCastBoon", Rarity = "Common", StackNum = 4 },
            { ItemName = "HeraSprintBoon", Rarity = "Common", StackNum = 4 },
            { ItemName = "HeraManaBoon", Rarity = "Common", StackNum = 4 },
        })
    end, loot, {}, {})
end

function TestHookCompositionV10.testEachNativeNpcChoiceFunctionBindsItsPublishedTraitOffer()
    local contacts = {
        ArachneCostumeChoice = "Arachne",
        NarcissusBenefitChoice = "Narcissus",
        MedeaCurseChoice = "Medea",
        CirceBlessingChoice = "Circe",
        IcarusBenefitChoice = "Icarus",
        EchoChoice = "Echo",
    }
    for functionName, giver in pairs(contacts) do
        local module, _, callbacks = capture()
        local state = {}
        local selected = giver .. "Selected"
        local node = {
            owner = giver .. "-offer", kind = "encounterInteraction",
            resolution = {
                kind = "traitOffer",
                offer = {
                    kind = "traits", giver = giver, selected = "option2",
                    options = {
                        { key = giver .. "First" }, { key = selected }, { key = giver .. "Third" },
                    },
                },
            },
        }
        local row = { node = node }
        local active = {
            occurrence = { overview = { encounterPhases = {
                { slotKey = "Encounter", encounterKey = giver .. "Encounter" },
            } } },
            bindings = { phase = { Encounter = row }, native = {} },
        }
        local completed
        local session = stub()
        session.current = function() return active end
        session.complete = function(_, actualRow, verified)
            completed = { row = actualRow, verified = verified }
            return true
        end
        timeline.attach(module, session, function() return state end, function() end)
        local priorRun = _G.CurrentRun
        _G.CurrentRun = {
            CurrentRoom = { Encounter = { Name = giver .. "Encounter" } },
            Hero = { Traits = {} },
        }
        local args = { UpgradeOptions = {
            { ItemName = giver .. "Third", Marker = 3 },
            { ItemName = giver .. "First", Marker = 1, GameStateRequirements = { "ignored" } },
            { ItemName = selected, Marker = 2, PriorityRequirements = { "ignored" } },
        } }
        callbacks[functionName](nil, {}, function(_, prepared)
            lu.assertEquals(prepared.UpgradeOptions, {
                { ItemName = giver .. "First", Marker = 1 },
                { ItemName = selected, Marker = 2 },
                { ItemName = giver .. "Third", Marker = 3 },
            })
            _G.CurrentRun.Hero.Traits = { { Name = selected } }
            callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end, {}, {
                Data = { Name = selected },
            }, {})
            return true
        end, {}, args, {})
        _G.CurrentRun = priorRun
        lu.assertEquals(completed.row, row, functionName)
        lu.assertTrue(completed.verified, functionName)
    end
end

function TestHookCompositionV10.testNativeTraitOrderRetainsAuthoredMetadataAndRejectedIdentity()
    local module, _, callbacks = capture()
    local row = {
        node = {
            owner = "aphrodite",
            resolution = {
                kind = "traitOffer",
                offer = {
                    kind = "traits",
                    selected = "option2",
                    rejected = "option1",
                    options = {
                        { key = "AphroditeCastBoon", rarity = "Epic", effectiveLevel = 4 },
                        { key = "AphroditeSpecialBoon", rarity = "Rare", effectiveLevel = 2 },
                        { key = "AphroditeSprintBoon", rarity = "Common", effectiveLevel = 1 },
                    },
                },
            },
        },
    }
    local loot = {
        __runPlannerTimelineRow = row,
        UpgradeOptions = {
            { ItemName = "AphroditeSpecialBoon" },
            { ItemName = "AphroditeCastBoon" },
            { ItemName = "AphroditeSprintBoon" },
        },
    }
    local screen = { BlockedIndexes = { 2 } }
    local seen = {}
    timeline.attach(module, stub(), function() return {} end, function() end)

    for index = 1, 3 do
        callbacks.CreateUpgradeChoiceButton(nil, {}, function(_, _, itemIndex, itemData)
            seen[itemIndex] = {
                blocked = screen.BlockedIndexes[1], key = itemData.ItemName,
                rarity = itemData.Rarity, level = itemData.StackNum,
            }
            return {}
        end, screen, loot, index, loot.UpgradeOptions[index], {})
    end

    lu.assertEquals(screen.BlockedIndexes, { 2 })
    lu.assertEquals(seen, {
        { blocked = 2, key = "AphroditeSpecialBoon", rarity = "Rare", level = 2 },
        { blocked = 2, key = "AphroditeCastBoon", rarity = "Epic", level = 4 },
        { blocked = 2, key = "AphroditeSprintBoon", rarity = "Common", level = 1 },
    })
end

function TestHookCompositionV10.testIncidentalConsumableDoesNotClaimTheIncomingRewardTransaction()
    local module, _, callbacks = capture()
    local completed = {}
    local node = {
        owner = "hammer",
        producerLifecycleKey = "RoomReward",
        reward = { rewardType = "WeaponUpgrade" },
        roles = {
            { role = "self", lifecyclePoint = "roomRewardPickup", gameName = "WeaponUpgrade" },
        },
    }
    local active = {
        occurrence = {
            overview = {
                incomingReward = { producerLifecycleKey = "RoomReward", rewardType = "WeaponUpgrade" },
            },
        },
        bindings = {
            producer = { ["RoomReward\0WeaponUpgrade"] = { node = node } },
            native = {},
        },
    }
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row, verified)
        completed[#completed + 1] = { row = row, verified = verified }
    end
    timeline.attach(module, session, function() return {} end, function() end)

    local consolation = { Name = "RoomRewardConsolationPrize" }
    callbacks.UseConsumableItem(nil, {}, function() return true end, consolation, {}, {})
    callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, consolation, {})

    lu.assertEquals(completed, {})
    lu.assertNil(active.bindings.native[consolation])
end

function TestHookCompositionV10.testDirectConsumableLevelResolutionForcesAndCompletesThePublishedTarget()
    local module, _, callbacks = capture()
    local target = { Name = "ZeusWeaponBoon", StackNum = 2 }
    local other = { Name = "ApolloSpecialBoon", StackNum = 4 }
    local row = {
        node = { owner = "pom-slice", kind = "shopPurchase", offerKey = "Minor", roles = {} },
        detail = {
            gameName = "GiftDrop",
            levelResolution = {
                offeredTargets = {}, selectedTarget = target.Name, levelCount = 1,
            },
        },
    }
    row.node.roles = { row.detail }
    local item = {
        Name = "StoreRewardRandomStack", __runPlannerOfferKey = "Minor",
        UseFunctionArgs = { Thread = true, NumTraits = 1, NumStacks = 9 },
    }
    row.detail.gameName = item.Name
    local active = {
        occurrence = { overview = {} },
        bindings = { offer = { Minor = row }, native = { [item] = row } },
    }
    local completions = {}
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, completedRow, verified, expected, observed)
        completions[#completions + 1] = {
            row = completedRow, verified = verified, expected = expected, observed = observed,
        }
    end
    features.attach(module, session, function() return {} end, function() end)
    timeline.attach(module, session, function() return {} end, function() end)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { target, other } } }
    callbacks.HandleStorePurchase(nil, {}, function(_, button)
        callbacks.UseConsumableItem(nil, {}, function(nativeItem)
            callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, _G.CurrentRun, nativeItem, {})
            local threadedArgs = nativeItem.UseFunctionArgs
            callbacks.AddStackToTraits(nil, {}, function(source)
                lu.assertEquals(source.TraitName, target.Name)
                lu.assertEquals(source.NumStacks, 1)
                local realizedArgs = {}
                for key, value in pairs(source) do realizedArgs[key] = value end
                realizedArgs.Thread = false
                callbacks.AddStackToTraits(nil, {}, function(_, directArgs)
                    lu.assertEquals(directArgs.TraitName, target.Name)
                    lu.assertEquals(directArgs.NumStacks, 1)
                    target.StackNum = target.StackNum + directArgs.NumStacks
                end, {}, realizedArgs)
            end, threadedArgs)
        end, button.Data, {}, {})
    end, {}, { Data = item }, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(item.UseFunctionArgs, { Thread = true, NumTraits = 1, NumStacks = 9 })
    lu.assertEquals(target.StackNum, 3)
    lu.assertEquals(other.StackNum, 4)
    lu.assertEquals(#completions, 1)
    lu.assertEquals(completions[1].row, row)
    lu.assertTrue(completions[1].verified)
    lu.assertEquals(completions[1].observed, target.Name)
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
    rooms.attach(module, session, function() end, function() end)
    timeline.attach(module, session, function() end, function() end)
    features.attach(module, session, function() end, function() end)
    for _, name in ipairs({
        "ChooseStartingRoom", "StartRoom", "DoUnlockRoomExits", "LeaveRoom",
        "UseLoot", "UseConsumableItem", "AddStackToTraits", "HandleLootPickup",
        "ConvertMetaRewardPresentation", "CreateLoot", "UnwrapRandomLoot",
        "ArachneCostumeChoice", "NarcissusBenefitChoice", "MedeaCurseChoice", "CirceBlessingChoice",
        "IcarusBenefitChoice", "EchoChoice", "SpawnNemesisForRandomEvents", "CheckAvailableTextLines",
        "NemesisTradeChoice", "NPCRewardDropPreProcess", "NPCRewardDropPreProcessArgs", "NemesisDamageContestTimer",
        "AddRandomMetaUpgrades", "FillInShopOptions", "CreateStoreButtons", "RestockWorldItem",
        "SpawnStoreItemInWorld", "RemoveStoreItem", "HandleStorePurchase",
    }) do
        lu.assertNotNil(names[name], name)
    end
end

function TestHookCompositionV10.testMismatchStopsEnforcementWithoutBlockingNativeRoomFlow()
    local module, _, callbacks = capture()
    local session = stub()
    session.checkpoint = function() return nil end
    session.exit = function() return nil end
    rooms.attach(module, session, function()
        return { state = "desynchronized" }
    end, function() end)

    local starting = callbacks.ChooseStartingRoom(nil, {}, function()
        return { Name = "NativeOpening" }
    end, {}, {})
    local entered = callbacks.StartRoom(nil, {}, function()
        return "native-entry"
    end, {}, { Name = "NativeOpening" })
    local used = callbacks.UseExitDoor(nil, {}, function(door)
        return door.Name
    end, { Name = "NativeDoor" }, {})
    local left = callbacks.LeaveRoom(nil, {}, function()
        return "native-exit"
    end, {}, {})

    lu.assertEquals(starting, { Name = "NativeOpening" })
    lu.assertEquals(entered, "native-entry")
    lu.assertEquals(used, "NativeDoor")
    lu.assertEquals(left, "native-exit")
end
