-- luacheck: globals TestRoomEntryHooks
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local roomHooks = require("mods.room.hooks")
local roomCoordinatorModule = require("mods.room.coordinator")
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local roomFeatureHooks = require("mods.room.features.hooks")
local support = require("tests.harness.hook_composition")
local capture, stub = support.capture, support.stub
local attachRewardHooks = support.attachRewardHooks
local navigationEntryStub = support.navigationEntryStub

TestRoomEntryHooks = {}

function TestRoomEntryHooks.testRoomSessionStartsBeforeNativeFeatureSpawns()
    local module, _, callbacks = capture()
    local entered, proved = false, false
    local occurrence = { id = "opening", gameName = "F_Opening01" }
    local additional = { room = { id = "chaos", gameName = "Chaos_01" } }
    local session = stub()
    local route = {
        expected = function() return occurrence end,
        enter = function(_, id, gameName)
            lu.assertEquals(id, "opening")
            lu.assertEquals(gameName, "F_Opening01")
            return occurrence
        end,
    }
    local roomSession = {
        enter = function(_, enteredOccurrence)
            lu.assertEquals(enteredOccurrence, occurrence)
            entered = true
            return true
        end,
        additional = function()
            if entered then return additional.room, additional end
            return nil
        end,
        proveEntry = function(_, nativeRoom)
            proved = true
            lu.assertEquals(nativeRoom.__runPlannerExecutionRoomId, "opening")
            return true
        end,
    }
    local state = { state = "synchronized", route = {} }
    local featureScope = roomFeatureHooks.attach(module, session, function() return state end, function() end,
        roomSession)
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, featureScope, navigationEntryStub)

    local nativeRoom = { Name = "F_Opening01", __runPlannerExecutionRoomId = "opening" }
    local eligible
    callbacks.StartRoom(nil, {}, function()
        callbacks.HandleSecretSpawns(nil, {}, function()
            eligible = callbacks.IsSecretDoorEligible(nil, {}, function() return false end, {}, nativeRoom)
        end, {})
    end, {}, nativeRoom)

    lu.assertTrue(entered)
    lu.assertTrue(proved)
    lu.assertTrue(eligible)
end

function TestRoomEntryHooks.testCreateRoomReappliesForcedAndSuppressedResourceOutcomes()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening", gameName = "F_Opening01",
        overview = {
            encounterPhases = {}, requiredObjects = {}, additional = {},
            resources = {
                { acquisitionRole = "ore", grantedTraitKey = "FireEssence", contributions = {} },
            },
        },
    }
    local plan = { occurrencesById = { opening = occurrence } }
    local state = {
        state = "synchronized", plan = plan,
        room = roomCoordinatorModule.new(plan, function() end, {}),
    }
    local priorGame = _G.game
    _G.game = { RoomData = { F_Opening01 = { Name = "F_Opening01" } } }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        {}, roomCoordinatorModule, nil, navigationEntryStub)

    local result = callbacks.CreateRoom(nil, {}, function(roomData)
        lu.assertTrue(roomData.PickaxePointSuccess)
        lu.assertFalse(roomData.FishingPointSuccess)
        return {
            Name = roomData.Name,
            PickaxePointSuccess = false,
            FishingPointSuccess = true,
        }
    end, { Name = "F_Opening01", __runPlannerExecutionRoomId = "opening" }, {})
    _G.game = priorGame

    lu.assertTrue(result.PickaxePointSuccess)
    lu.assertFalse(result.FishingPointSuccess)
    lu.assertEquals(result.__runPlannerExecutionRoomId, "opening")
end

function TestRoomEntryHooks.testIncomingRewardProofRemainsNavigationOwnedAtRoomEntry()
    local module, _, callbacks = capture()
    local occurrence = { id = "opening", gameName = "F_Opening01" }
    local state = { state = "synchronized", route = {} }
    local mismatch, roomProof
    local session = stub()
    session.mismatch = function(_, errorValue)
        mismatch = errorValue
        state.state = "desynchronized"
    end
    local route = {
        expected = function() return occurrence end,
        enter = function() return occurrence end,
    }
    local roomSession = {
        enter = function() return true end,
        proveEntry = function() roomProof = true; return true end,
    }
    local navigationEntry = {
        realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
        proveIncomingReward = function()
            return nil, { kind = "incomingReward", expected = "Boon", observed = "WeaponUpgrade" }
        end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, nil, navigationEntry)

    callbacks.StartRoom(nil, {}, function() return true end, {}, {
        Name = "F_Opening01", __runPlannerExecutionRoomId = "opening",
    })

    lu.assertEquals(mismatch.kind, "incomingReward")
    lu.assertNil(roomProof)
end

function TestRoomEntryHooks.testZagreusContractRemainsAnAdditionalDoorDuringNormalDoorProof()
    local module, _, callbacks = capture()
    local additional = {
        owner = "contract-exit", kind = "zagreusContract",
        room = { id = "contract", gameName = "C_Boss01" },
    }
    local occurrence = {
        id = "shop", overview = { additional = { additional } },
        doors = { kind = "batch", targets = {
            { room = { id = "one", gameName = "F_One" } },
            { room = { id = "two", gameName = "F_Two" } },
        } },
    }
    local contractOccurrence = {
        id = "contract", gameName = "C_Boss01",
        overview = { encounterPhases = {}, requiredObjects = {} },
    }
    local state = { state = "synchronized", route = {}, plan = { occurrencesById = {
        shop = occurrence, contract = contractOccurrence, one = {}, two = {},
    } } }
    local active = { occurrence = occurrence }
    local mismatch
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local roomSession = {
        current = function() return active end,
        additional = function()
            return additional, contractOccurrence
        end,
        realize = function(_, target)
            return { Name = target.gameName, GenusName = target.gameName,
                __runPlannerExecutionRoomId = target.id }
        end,
        realizeFeatures = function(_, nativeRoom) return nativeRoom end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local route = {
        current = function() return active.occurrence end,
        reportDestination = function() return true end,
    }
    local featureScope = roomFeatureHooks.attach(module, session, function() return state end, function() end,
        roomSession)
    local navigationEntry = navigation.attach(module, session, function() return state end, function() end,
        route, roomSession)
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, featureScope, navigationEntry)

    local contractRoom
    local contractDoor = { ObjectId = 3 }
    callbacks.SpawnZagContract(nil, {}, function()
        contractRoom = callbacks.CreateRoom(nil, {}, function(roomData) return roomData end,
            { Name = "C_Boss01" }, {})
        callbacks.AssignRoomToExitDoor(nil, {}, function(door, createdRoom)
            door.Room = createdRoom
        end, contractDoor, contractRoom)
    end, {}, {})
    lu.assertEquals(contractRoom.__runPlannerExecutionAdditionalOwner, "contract-exit")
    lu.assertEquals(contractRoom.__runPlannerExecutionAdditionalKind, "zagreusContract")
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalOwner, "contract-exit")
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalKind, "zagreusContract")

    local priorMap, priorCollapse, priorGame = _G.MapState, _G.CollapseTableOrdered, _G.game
    local oneDoor, twoDoor = { Room = { Name = "F_One" } }, { Room = { Name = "F_Two" } }
    _G.MapState = { OfferedExitDoors = { oneDoor, twoDoor, contractDoor } }
    _G.CollapseTableOrdered = function(value) return value end
    _G.game = { RoomData = { F_One = {}, F_Two = {} } }
    callbacks.DoUnlockRoomExits(nil, {}, function() return true end, {}, {})
    _G.MapState, _G.CollapseTableOrdered, _G.game = priorMap, priorCollapse, priorGame

    lu.assertNil(mismatch)
    lu.assertNil(oneDoor.__runPlannerExecutionAdditionalKind)
    lu.assertNil(twoDoor.__runPlannerExecutionAdditionalKind)
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalKind, "zagreusContract")
end

function TestRoomEntryHooks.testEncounterForcingKeepsNativeSetupAndGeneration()
    local module, _, callbacks = capture()
    local declaration = { Name = "OpeningGeneratedF", Generated = true }
    local occurrence = {
        id = "opening",
        overview = { encounterPhases = { { slotKey = "Encounter", encounterKey = "OpeningGeneratedF" } } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { opening = occurrence } } }
    local active = { occurrence = occurrence }
    local session = stub()
    local boundEncounter
    local roomSession = {
        current = function() return active end,
        encounterAt = function(_, index) return active.occurrence.overview.encounterPhases[index] end,
        bindEncounter = function(_, native, slotKey)
            boundEncounter = { native = native, slotKey = slotKey }
            return active.occurrence.overview.encounterPhases[1]
        end,
        startEncounter = function() return true end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
        encounterIsFinal = function() return true end,
    }
    local priorGame, priorGlobalForce = _G.game, _G.ForceNextEncounter
    _G.game = { EncounterData = { OpeningGeneratedF = declaration } }
    _G.ForceNextEncounter = "DebugEncounter"
    encounterHooks.attach(module, session, function() return state end, function() end, roomSession)

    local run = { ForceNextEncounterData = { Name = "PriorEncounter" } }
    local nativeRoom = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseEncounter(nil, {}, function(currentRun, room, args)
        lu.assertEquals(currentRun.ForceNextEncounterData, declaration)
        lu.assertNil(_G.ForceNextEncounter)
        lu.assertEquals(room, nativeRoom)
        return { Name = declaration.Name, GeneratedWaves = true, Args = args }
    end, run, nativeRoom, { Source = "test" })

    lu.assertTrue(result.GeneratedWaves)
    lu.assertEquals(result.Args.Source, "test")
    lu.assertEquals(run.ForceNextEncounterData.Name, "PriorEncounter")
    lu.assertEquals(_G.ForceNextEncounter, "DebugEncounter")
    lu.assertEquals(boundEncounter.native, result)
    lu.assertEquals(boundEncounter.slotKey, "Encounter")
    _G.game, _G.ForceNextEncounter = priorGame, priorGlobalForce
end

function TestRoomEntryHooks.testRoomRewardForcingConsumesTheMatchingNativeBagEntry()
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
    attachRewardHooks(module, session, function() return state end, function() end)

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
            if callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                currentRun, room, reward, {}, {}) then
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

function TestRoomEntryHooks.testPublishedRewardStoreOverridesAStaleNativeStore()
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
    attachRewardHooks(module, session, function() return state end, function() end)

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

function TestRoomEntryHooks.testContractTraitAcquisitionDoesNotOwnTheNativeMetaRewardChoice()
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
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "contract", ForcedReward = "GemPointsBigDrop" }
    local result = callbacks.ChooseRoomReward(nil, {}, function()
        return "GemPointsBigDrop"
    end, {}, room, "MetaProgress", {}, {})

    lu.assertEquals(result, "GemPointsBigDrop")
    lu.assertEquals(mismatches, {})
end

function TestRoomEntryHooks.testEffectNeutralBossRewardUsesNativeForcedRewardChoice()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "boss",
        overview = { effectNeutralRequiredReward = true },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { boss = occurrence } } }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "boss", ForcedReward = "MixerFBossDrop" }
    local baseCalled = false
    local result = callbacks.ChooseRoomReward(nil, {}, function(_, nativeRoom)
        baseCalled = true
        return nativeRoom.ForcedReward
    end, {}, room, "RunProgress", {}, {})

    lu.assertTrue(baseCalled)
    lu.assertEquals(result, "MixerFBossDrop")
end

function TestRoomEntryHooks.testRewardSourceUsesTheTargetOccurrenceNotTheCurrentRoom()
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
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "target" }
    callbacks.SetupRoomReward(nil, {}, function(_, nativeRoom)
        nativeRoom.ForceLootName = "RandomUpgrade"
        return true
    end, {}, room, {}, {})

    lu.assertEquals(room.ForceLootName, "ZeusUpgrade")
end
