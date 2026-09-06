-- luacheck: globals TestRoomEntryHooks
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local roomHooks = require("mods.room.hooks")
local roomCoordinatorModule = require("mods.room.coordinator")
local routeSessionModule = require("mods.route.session")
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local roomFeatureHooks = require("mods.room.features.hooks")
local support = require("tests.harness.hook_composition")
local capture, stub = support.capture, support.stub
local attachRewardHooks = support.attachRewardHooks
local navigationEntryStub = support.navigationEntryStub
local unusedLoadoutScope = {
    synchronizeStartingRoom = function()
        error("starting-room loadout synchronization is outside this test")
    end,
}

TestRoomEntryHooks = {}

function TestRoomEntryHooks.testOpeningFinalizesLoadoutBeforeForcingNativeCreationFacts()
    local module, _, callbacks = capture()
    local transaction = {
        owner = "opening-reward", kind = "acquisition", offerKey = "opening-reward",
        window = { kind = "standard", phase = "beforeCombat" },
    }
    local occurrence = {
        id = "opening", gameName = "F_Opening01", biomeKey = "F",
        overview = {
            encounterPhases = { { slotKey = "Encounter", encounterKey = "OpeningGeneratedF" } },
            incomingReward = { rewardType = "WeaponUpgrade", source = "WeaponUpgrade" },
            requiredObjects = {}, additional = {}, resources = {},
        },
        transactionsByOwner = { [transaction.owner] = transaction },
        timeline = { transactions = { transaction }, dependencies = {}, obligations = {} },
        doors = { kind = "terminal" }, roomExitConformance = { facts = {} },
        conformanceExpected = {},
    }
    local plan = {
        occurrences = { occurrence }, occurrencesById = { opening = occurrence },
        selectedOccurrenceIds = { "opening" },
        resources = { occurrences = { {
            occurrenceId = "opening", pointDispositions = {
                Pickaxe = "suppress", Exorcism = "suppress", Shovel = "suppress", Fishing = "suppress",
            },
        } } },
    }
    local state = {
        state = "starting", plan = plan, route = routeSessionModule.new(plan), diagnostics = {},
    }
    state.room = roomCoordinatorModule.new(plan, function(errorValue)
        state.firstMismatch = errorValue
        state.state = "desynchronized"
    end)
    local session = stub()
    session.mismatch = function(_, errorValue)
        state.firstMismatch = errorValue
        state.state = "desynchronized"
    end
    local loadoutScope = {
        synchronizeStartingRoom = function()
            state.state = "synchronized"
            return true
        end,
    }
    local navigationEntry = navigation.attach(module, session, function() return state end, function() end,
        routeSessionModule, roomCoordinatorModule)
    roomHooks.attach(module, session, function() return state end, function() end,
        routeSessionModule, roomCoordinatorModule, nil, navigationEntry, loadoutScope)
    encounterHooks.attach(module, session, function() return state end, function() end,
        roomCoordinatorModule)

    local priorGame, priorForce = _G.game, _G.ForceNextEncounter
    local rewardBag = { { Name = "Boon" }, { Name = "WeaponUpgrade" } }
    local currentRun = { RewardPriorities = {}, RewardStores = { RunProgress = rewardBag } }
    _G.game = {
        RoomData = { F_Opening01 = { Name = "F_Opening01" } },
        EncounterData = { OpeningGeneratedF = { Name = "OpeningGeneratedF" } },
    }
    _G.game.CreateRoom = function(roomData, args)
        return callbacks.CreateRoom(nil, {}, function(created)
            -- Hostile native room creation attempts to replace every authored fact.
            created.PickaxePointSuccess = true
            created.FishingPointSuccess = true
            callbacks.SetupRoomReward(nil, {}, function(_, nativeRoom)
                nativeRoom.ForceLootName = "RandomUpgrade"
            end, currentRun, created, nil, {})
            created.ChosenRewardType = callbacks.ChooseRoomReward(nil, {},
                function(run, nativeRoom, store)
                    for index, reward in ipairs(run.RewardStores[store]) do
                        if callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                            run, nativeRoom, reward, {}, {}) then
                            table.remove(run.RewardStores[store], index)
                            return reward.Name
                        end
                    end
                end, currentRun, created, "RunProgress", {}, {})
            created.Encounter = callbacks.ChooseEncounter(nil, {}, function(run)
                return { Name = run.ForceNextEncounterData and run.ForceNextEncounterData.Name or "Wrong" }
            end, currentRun, created, args)
            return created
        end, roomData, args)
    end

    local nativeFallbackCalled = false
    local result = callbacks.ChooseStartingRoom(nil, {}, function()
        nativeFallbackCalled = true
        return { Name = "NativeOpening" }
    end, currentRun, {})
    lu.assertEquals(state.state, "synchronized")
    lu.assertFalse(nativeFallbackCalled)
    lu.assertEquals(result.Name, "F_Opening01")
    lu.assertEquals(result.ChosenRewardType, "WeaponUpgrade")
    lu.assertEquals(result.ForceLootName, "WeaponUpgrade")
    lu.assertEquals(rewardBag, { { Name = "Boon" } })
    lu.assertEquals(result.Encounter.Name, "OpeningGeneratedF")
    lu.assertFalse(result.PickaxePointSuccess)
    lu.assertFalse(result.FishingPointSuccess)
    lu.assertFalse(result.ExorcismPointSuccess)
    lu.assertFalse(result.ShovelPointSuccess)

    callbacks.StartRoom(nil, {}, function() return true end, currentRun, result)
    local active = roomCoordinatorModule.current(state)
    lu.assertNotNil(active)
    local handle = assert(roomCoordinatorModule.resolve(state, active,
        { kind = "offer", offerKey = "opening-reward" }))
    lu.assertTrue(roomCoordinatorModule.complete(state, handle))
    lu.assertNil(state.firstMismatch)
    _G.game, _G.ForceNextEncounter = priorGame, priorForce
end

function TestRoomEntryHooks.testOpeningLoadoutMismatchReturnsToUnblockedNativeSelection()
    local module, _, callbacks = capture()
    local state = { state = "starting" }
    local nativeRoom = { Name = "NativeOpening" }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        { expected = function() error("route must remain untouched") end }, {}, nil,
        navigationEntryStub, {
            synchronizeStartingRoom = function()
                state.state = "desynchronized"
                return false
            end,
        })

    local result = callbacks.ChooseStartingRoom(nil, {}, function() return nativeRoom end, {}, {})
    lu.assertEquals(result, nativeRoom)
    lu.assertEquals(state.state, "desynchronized")
end

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
        route, roomSession, featureScope, navigationEntryStub, unusedLoadoutScope)

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

function TestRoomEntryHooks.testCreateRoomReappliesOnlyPublishedResourceOverrides()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening", gameName = "F_Opening01",
        overview = {
            encounterPhases = {}, requiredObjects = {}, additional = {},
        },
    }
    local plan = { occurrencesById = { opening = occurrence }, resources = { occurrences = { {
        occurrenceId = "opening", pointDispositions = {
            Pickaxe = "force", Exorcism = "native", Shovel = "native", Fishing = "suppress",
        },
    } } } }
    local state = {
        state = "synchronized", plan = plan,
        room = roomCoordinatorModule.new(plan, function() end, {}),
    }
    local priorGame = _G.game
    _G.game = { RoomData = { F_Opening01 = { Name = "F_Opening01" } } }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        {}, roomCoordinatorModule, nil, navigationEntryStub, unusedLoadoutScope)

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
    lu.assertNil(result.ExorcismPointSuccess)
    lu.assertNil(result.ShovelPointSuccess)
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
        proveOutgoingDoors = function() return true end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, nil, navigationEntry, unusedLoadoutScope)

    callbacks.StartRoom(nil, {}, function() return true end, {}, {
        Name = "F_Opening01", __runPlannerExecutionRoomId = "opening",
    })

    lu.assertEquals(mismatch.kind, "incomingReward")
    lu.assertNil(roomProof)
end

function TestRoomEntryHooks.testZagreusContractRemainsAnAdditionalDoorDuringExitProof()
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
    }
    local featureScope = roomFeatureHooks.attach(module, session, function() return state end, function() end,
        roomSession)
    local navigationEntry = navigation.attach(module, session, function() return state end, function() end,
        route, roomSession)
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, featureScope, navigationEntry, unusedLoadoutScope)

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
    local proved, errorValue = navigationEntry.proveOutgoingDoors(state, {})
    _G.MapState, _G.CollapseTableOrdered, _G.game = priorMap, priorCollapse, priorGame

    lu.assertNil(mismatch)
    lu.assertTrue(proved, errorValue)
    lu.assertNil(oneDoor.__runPlannerExecutionAdditionalKind)
    lu.assertNil(twoDoor.__runPlannerExecutionAdditionalKind)
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalKind, "zagreusContract")
end

function TestRoomEntryHooks.testLeaveRoomProvesDoorsBeforeClosingTheRoomSession()
    local module, _, callbacks = capture()
    local state = { state = "synchronized", route = {} }
    local mismatch, closed, advanced, nativeCalled
    local session = stub()
    session.mismatch = function(_, errorValue)
        mismatch = errorValue
        state.state = "desynchronized"
    end
    local route = {
        exit = function() advanced = true; return true end,
        expected = function() return {} end,
    }
    local roomSession = {
        close = function() closed = true; return true end,
    }
    local navigationEntry = {
        realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
        proveIncomingReward = function() return true end,
        proveOutgoingDoors = function()
            return nil, { kind = "reward", expected = "Boon", observed = "WeaponUpgrade" }
        end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, nil, navigationEntry, unusedLoadoutScope)

    local result = callbacks.LeaveRoom(nil, {}, function()
        nativeCalled = true
        return "native-exit"
    end, {}, {})

    lu.assertEquals(result, "native-exit")
    lu.assertEquals(mismatch.kind, "reward")
    lu.assertNil(closed)
    lu.assertNil(advanced)
    lu.assertTrue(nativeCalled)
end

function TestRoomEntryHooks.testLeaveRoomAdvancesAfterNativeLeaveReturns()
    local module, _, callbacks = capture()
    local first = { id = "one", gameName = "F_One" }
    local second = { id = "two", gameName = "F_Two" }
    local plan = {
        selectedOccurrenceIds = { "one", "two" },
        occurrencesById = { one = first, two = second },
    }
    local cursor = routeSessionModule.new(plan)
    assert(routeSessionModule.enter(cursor, "one", "F_One"))
    local nativeCalled, closed = false, false
    local state = { state = "synchronized", route = cursor }
    local session = stub()
    session.mismatch = function(_, errorValue)
        state.state, state.firstMismatch = "desynchronized", errorValue
    end
    local roomSession = {
        close = function() closed = true; return true end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        routeSessionModule, roomSession, nil, navigationEntryStub, unusedLoadoutScope)
    local result = callbacks.LeaveRoom(nil, {}, function()
        lu.assertTrue(closed)
        lu.assertEquals(routeSessionModule.current(cursor), first)
        lu.assertEquals(routeSessionModule.next(cursor), second)
        nativeCalled = true
        return "native-exit"
    end, {}, {})
    lu.assertEquals(result, "native-exit")
    lu.assertTrue(nativeCalled)
    lu.assertNil(routeSessionModule.current(cursor))
    lu.assertEquals(routeSessionModule.expected(cursor), second)
end

function TestRoomEntryHooks.testLeaveRoomDoesNotRetainDepartingCursorAfterNestedMismatch()
    local module, _, callbacks = capture()
    local first = { id = "one", gameName = "F_One" }
    local second = { id = "two", gameName = "F_Two" }
    local plan = {
        selectedOccurrenceIds = { "one", "two" },
        occurrencesById = { one = first, two = second },
    }
    local cursor = routeSessionModule.new(plan)
    assert(routeSessionModule.enter(cursor, "one", "F_One"))
    local state = { state = "synchronized", route = cursor }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        routeSessionModule, { close = function() return true end }, nil,
        navigationEntryStub, unusedLoadoutScope)

    callbacks.LeaveRoom(nil, {}, function()
        lu.assertEquals(routeSessionModule.current(cursor), first)
        state.state = "desynchronized"
    end, {}, {})

    lu.assertNil(routeSessionModule.current(cursor))
    lu.assertEquals(routeSessionModule.expected(cursor), second)
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

function TestRoomEntryHooks.testEncounterChoiceUsesStampedDestinationInsteadOfActiveSourceRoom()
    local module, _, callbacks = capture()
    local source = {
        id = "source", gameName = "F_Source",
        overview = { encounterPhases = { { slotKey = "Encounter", encounterKey = "SourceEncounter" } } },
        transactionsByOwner = {}, timeline = { transactions = {}, dependencies = {}, obligations = {} },
    }
    local target = {
        id = "target", gameName = "F_Target",
        overview = { encounterPhases = { { slotKey = "Encounter", encounterKey = "TargetEncounter" } } },
        transactionsByOwner = {}, timeline = { transactions = {}, dependencies = {}, obligations = {} },
    }
    local plan = { occurrencesById = { source = source, target = target } }
    local state = {
        state = "synchronized", plan = plan,
        room = roomCoordinatorModule.new(plan, function() end, {}),
    }
    assert(roomCoordinatorModule.enter(state, source))
    local priorGame = _G.game
    _G.game = { EncounterData = {
        SourceEncounter = { Name = "SourceEncounter" },
        TargetEncounter = { Name = "TargetEncounter" },
    } }
    encounterHooks.attach(module, stub(), function() return state end, function() end,
        roomCoordinatorModule)

    local nativeRoom = { __runPlannerExecutionRoomId = "target" }
    local result = callbacks.ChooseEncounter(nil, {}, function(run)
        return { Name = run.ForceNextEncounterData.Name }
    end, {}, nativeRoom, {})
    _G.game = priorGame

    lu.assertEquals(result.Name, "TargetEncounter")
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

function TestRoomEntryHooks.testStartingRoomRewardRemainsNativeUntilLoadoutIsSynchronized()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening", gameName = "F_Opening01",
        overview = { incomingReward = { rewardType = "WeaponUpgrade" } },
    }
    local state = {
        state = "starting",
        plan = { occurrencesById = { opening = occurrence } },
    }
    local session = stub()
    session.current = function() return nil end
    attachRewardHooks(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = {},
        RewardStores = {
            RunProgress = { { Name = "Boon" }, { Name = "WeaponUpgrade" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, nativeRoom, rewardStoreName)
        local reward = table.remove(currentRun.RewardStores[rewardStoreName], 1)
        nativeRoom.ChosenRewardType = reward.Name
        return reward.Name
    end, run, room, "RunProgress", {}, {})

    lu.assertEquals(result, "Boon")
    lu.assertEquals(room.ChosenRewardType, "Boon")
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "WeaponUpgrade" } })
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
        state = "synchronized",
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
