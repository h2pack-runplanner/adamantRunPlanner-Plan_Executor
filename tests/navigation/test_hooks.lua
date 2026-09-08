-- luacheck: globals TestNavigationHooks
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local routeSession = require("mods.route.session")
local support = require("tests.harness.hook_composition")
local capture, stub = support.capture, support.stub

TestNavigationHooks = {}

function TestNavigationHooks.testClockworkGoalUsesTheOrdinaryRewardSelectionWithoutHookingItsNativeLifecycle()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "clockwork-goal",
        overview = { incomingReward = { rewardType = "ClockworkGoal", producerLifecycleKey = "ClockworkGoalRoom" } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { [occurrence.id] = occurrence } } }
    local active = { occurrence = occurrence }
    local room = {
        current = function() return active end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    navigation.attach(module, stub(), function() return state end, function() end,
        { current = function() return occurrence end }, room)

    local run = { RewardStores = { TartarusRewards = {
        { Name = "RoomMoneyTripleDrop" }, { Name = "ClockworkGoal" },
    } } }
    local nativeRoom = { __runPlannerExecutionRoomId = occurrence.id }
    local chosen = callbacks.ChooseRoomReward(nil, {}, function(currentRun, roomValue, store)
        for index, reward in ipairs(currentRun.RewardStores[store]) do
            if callbacks.IsRoomRewardEligible(nil, {}, function() return false end,
                currentRun, roomValue, reward, {}, {}) then
                table.remove(currentRun.RewardStores[store], index)
                return reward.Name
            end
        end
    end, run, nativeRoom, "TartarusRewards", {}, {})

    lu.assertEquals(chosen, "ClockworkGoal")
    lu.assertEquals(run.RewardStores.TartarusRewards, { { Name = "RoomMoneyTripleDrop" } })
    lu.assertNil(callbacks.SpawnClockworkGoalReward)
end

function TestNavigationHooks.testDoorChoiceIsForcedDuringNativeGeneration()
    local module, _, callbacks = capture()
    local selected, mismatch
    local target = { room = { id = "next", gameName = "F_Next" }, reward = { rewardType = "Boon" } }
    local active = { occurrence = {
        overview = { additional = {} },
        doors = { kind = "batch", targets = { target } },
    } }
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local room = {
        current = function() return active end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local state = { state = "synchronized", plan = { occurrencesById = { next = {} } }, route = {} }
    local navigationScope = navigation.attach(module, session, function() return state end, function() end,
        { current = function() return active.occurrence end }, room)
    local priorMap, priorGame, priorCollapse = _G.MapState, _G.game, _G.CollapseTableOrdered
    local physicalDoor = { ObjectId = 101 }
    _G.MapState = { OfferedExitDoors = { [101] = physicalDoor } }
    _G.game = { RoomData = { F_Next = { GenusName = "F_Next" } } }
    _G.CollapseTableOrdered = function(values)
        lu.assertEquals(values[101], physicalDoor)
        return { physicalDoor }
    end
    callbacks.DoUnlockRoomExits(nil, {}, function()
        selected = callbacks.ChooseNextRoomData(nil, {}, function() return nil end, {}, {}, {})
        physicalDoor.Room = selected
        physicalDoor.RewardType = "Boon"
        return true
    end, {}, {})
    local proved, errorValue = navigationScope.proveOutgoingDoors(state, {})
    _G.MapState, _G.game, _G.CollapseTableOrdered = priorMap, priorGame, priorCollapse
    lu.assertEquals(selected.__runPlannerExecutionRoomId, "next")
    lu.assertNil(mismatch)
    lu.assertTrue(proved, errorValue)
    lu.assertEquals(physicalDoor.Room.__runPlannerExecutionRoomId, "next")
end

function TestNavigationHooks.testAnomalyDoorUsesNativeReplacementPresentation()
    local module, _, callbacks = capture()
    local anomaly = {
        id = "anomaly", gameName = "B_Combat01", biomeKey = "G",
        anomaly = { replacedRoomGameName = "G_Combat08", success = true },
        overview = { additional = {} },
    }
    local source = {
        id = "source", gameName = "G_Combat01", biomeKey = "G",
        overview = { additional = {} },
        doors = { kind = "batch", targets = {
            { room = { id = "anomaly", gameName = "B_Combat01" } },
        } },
    }
    local active = { occurrence = source }
    local mismatch
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local room = {
        current = function() return active end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local state = {
        state = "synchronized", route = {},
        plan = { occurrencesById = { anomaly = anomaly } },
    }
    local navigationScope = navigation.attach(module, session, function() return state end, function() end,
        { current = function() return active.occurrence end }, room)

    local physicalDoor = { ObjectId = 101 }
    local currentRun = { CurrentRoom = { Name = "G_Combat01" } }
    local forcedRoom
    local priorMap, priorGame, priorCollapse = _G.MapState, _G.game, _G.CollapseTableOrdered
    _G.MapState = { OfferedExitDoors = { [101] = physicalDoor } }
    _G.game = { RoomData = {
        G_Combat08 = { Name = "G_Combat08", AllowAnomalyReplacement = true },
        B_Combat01 = { Name = "B_Combat01" },
    } }
    _G.CollapseTableOrdered = function() return { physicalDoor } end

    local function nativeChoose(run, args, otherDoors)
        if args.ForceNextRoomSet == "Anomaly" then
            error("the nested Anomaly choice must be supplied by the planner hook")
        end
        forcedRoom = args.ForceNextRoom
        local selected = _G.game.RoomData[forcedRoom]
        if run.CurrentRoom.DoAnomalies and selected.AllowAnomalyReplacement then
            selected = callbacks.ChooseNextRoomData(
                nil, {}, nativeChoose, run, { ForceNextRoomSet = "Anomaly" }, otherDoors)
            selected.PrevRoomExitFunctionName = "ExitToAnomalyPresentation"
        end
        return selected
    end

    callbacks.DoUnlockRoomExits(nil, {}, function(run)
        physicalDoor.Room = callbacks.ChooseNextRoomData(nil, {}, nativeChoose, run, {}, {})
        return true
    end, currentRun, currentRun.CurrentRoom)
    local proved, errorValue = navigationScope.proveOutgoingDoors(state, currentRun)
    _G.MapState, _G.game, _G.CollapseTableOrdered = priorMap, priorGame, priorCollapse

    lu.assertNil(mismatch)
    lu.assertTrue(proved, errorValue)
    lu.assertEquals(forcedRoom, "G_Combat08")
    lu.assertEquals(physicalDoor.Room.Name, "B_Combat01")
    lu.assertEquals(physicalDoor.Room.__runPlannerExecutionRoomId, "anomaly")
    lu.assertEquals(physicalDoor.Room.PrevRoomExitFunctionName, "ExitToAnomalyPresentation")
    lu.assertNil(currentRun.CurrentRoom.DoAnomalies)
end

function TestNavigationHooks.testDoorUseDoesNotInterpretOrAdvanceTheRouteDestination()
    local module, _, callbacks = capture()
    local first = {
        id = "first", gameName = "F_First",
        overview = { additional = {} },
        doors = { kind = "fixed", target = { id = "second", gameName = "F_Second" } },
    }
    local second = { id = "second", gameName = "F_Second" }
    local plan = {
        selectedOccurrenceIds = { "first", "second" },
        occurrencesById = { first = first, second = second },
    }
    local routeState = routeSession.new(plan)
    lu.assertEquals(routeSession.enter(routeState, "first", "F_First"), first)
    local active = { occurrence = first }
    local state = { state = "synchronized", route = routeState, plan = plan }
    local checkpoint
    local room = {
        current = function() return active end,
        checkpoint = function(_, value) checkpoint = value; return true end,
    }
    navigation.attach(module, stub(), function() return state end, function() end,
        routeSession, room)

    local door = { Room = { __runPlannerExecutionRoomId = "unexpected" } }
    lu.assertEquals(callbacks.UseExitDoor(nil, {}, function() return "native" end, door, {}), "native")

    lu.assertEquals(routeState.index, 1)
    lu.assertEquals(routeState.currentOccurrence, first)
    lu.assertNil(routeState.firstMismatch)
    lu.assertEquals(checkpoint, "exitUsable")
    lu.assertEquals(active.occurrence, first)
end

function TestNavigationHooks.testDoorMismatchIsDeferredUntilExitProof()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening", overview = { additional = {} },
        doors = { kind = "batch", targets = {
            { room = { id = "next", gameName = "F_Next" }, reward = { rewardType = "Boon" } },
        } },
    }
    local active = { occurrence = occurrence }
    local state = {
        state = "synchronized", route = {},
        plan = { occurrencesById = { next = {} } },
    }
    local mismatch
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local room = {
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local scope = navigation.attach(module, session, function() return state end, function() end,
        { current = function() return active.occurrence end }, room)
    local physicalDoor = { ObjectId = 101 }
    local priorMap, priorGame, priorCollapse = _G.MapState, _G.game, _G.CollapseTableOrdered
    _G.MapState = { OfferedExitDoors = { [101] = physicalDoor } }
    _G.game = { RoomData = { F_Next = { GenusName = "F_Next" } } }
    _G.CollapseTableOrdered = function() return { physicalDoor } end

    callbacks.DoUnlockRoomExits(nil, {}, function()
        physicalDoor.Room = callbacks.ChooseNextRoomData(nil, {}, function() return nil end, {}, {}, {})
        physicalDoor.RewardType = "WeaponUpgrade"
        return true
    end, {}, {})
    lu.assertNil(mismatch)
    local proved, errorValue = scope.proveOutgoingDoors(state, {})
    _G.MapState, _G.game, _G.CollapseTableOrdered = priorMap, priorGame, priorCollapse

    lu.assertNil(proved)
    lu.assertEquals(errorValue.kind, "reward")
end

function TestNavigationHooks.testChaosDoorIsExcludedAfterNormalDoorGeneration()
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
    local mismatch
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local room = {
        current = function() return active end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local state = {
        state = "synchronized", route = {},
        plan = { occurrencesById = { next = {}, chaos = {} } },
    }
    local priorGame = _G.game
    _G.game = { RoomData = { F_Next = { GenusName = "F_Next" } } }
    local navigationScope = navigation.attach(module, session, function() return state end, function() end,
        { current = function() return active.occurrence end }, room)

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
    callbacks.UseExitDoor(nil, {}, function() return true end, chaosDoor, {})
    local proved, errorValue = navigationScope.proveOutgoingDoors(state, {})
    _G.MapState, _G.CollapseTableOrdered, _G.game = priorMap, priorCollapse, priorGame

    lu.assertNil(mismatch)
    lu.assertTrue(proved, errorValue)
    lu.assertEquals(normalDoor.Room.__runPlannerExecutionRoomId, "next")
    lu.assertEquals(chaosDoor.Room.__runPlannerExecutionRoomId, "chaos")
end

function TestNavigationHooks.testEphyraHubForcesTheCompletePhysicalBoardBeforeNativeAssignment()
    local module, _, callbacks = capture()
    local target = {
        id = "main", gameName = "N_Combat01", biomeKey = "N",
        overview = { incomingReward = {
            rewardType = "Boon", source = "ApolloUpgrade", resolvedStoreKey = "HubRewards",
        } },
    }
    local source = {
        id = "prehub", gameName = "N_PreHub01", biomeKey = "N",
        overview = { hub = {
            room = { gameName = "N_Hub" },
            slots = { {
                slotKey = "combat01", physicalDoorId = 101,
                room = { id = "main", biomeKey = "N", gameName = "N_Combat01" },
                reward = target.overview.incomingReward,
            } },
            finalHandoff = { id = "preboss", biomeKey = "N", gameName = "N_PreBoss01" },
        } },
    }
    local plan = {
        selectedOccurrenceIds = { "main" },
        occurrencesById = { prehub = source, main = target },
    }
    local state = { state = "synchronized", plan = plan, route = routeSession.new(plan) }
    local room = { checkpoint = function() end, window = function() end }
    navigation.attach(module, stub(), function() return state end, function() end, routeSession, room)

    local priorMap, priorGame, priorRun, priorCollapse =
        _G.MapState, _G.game, _G.CurrentRun, _G.CollapseTableOrdered
    local plannedDoor, unplannedDoor = { ObjectId = 101 }, { ObjectId = 102 }
    local hubRoom = { Name = "N_Hub", UnavailableDoors = {} }
    _G.MapState = { OfferedExitDoors = { [101] = plannedDoor } }
    _G.game = { RoomData = {
        N_Hub = { PredeterminedDoorRooms = { [101] = "N_Combat01", [102] = "N_Combat02" } },
        N_Combat01 = { Name = "N_Combat01" },
    } }
    _G.CurrentRun = {
        CurrentRoom = hubRoom,
        RewardStores = { HubRewards = { { Name = "WeaponUpgrade" }, { Name = "Boon" } } },
    }
    _G.CollapseTableOrdered = function() return { plannedDoor } end

    callbacks.ChooseAvailableN_HubDoors(nil, {}, function(roomValue)
        roomValue.UnavailableDoors[101] = true
        roomValue.DoorsChosen = true
    end, hubRoom, {})
    callbacks.DoUnlockRoomExits(nil, {}, function(run)
        local nativeTarget = { Name = "N_Combat01" }
        nativeTarget.ChosenRewardType = callbacks.ChooseRoomReward(nil, {},
            function(currentRun, candidate, store)
                for _, reward in ipairs(currentRun.RewardStores[store]) do
                    if callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                        currentRun, candidate, reward, {}, {}) then return reward.Name end
                end
            end, run, nativeTarget, "HubRewards", {}, { Door = plannedDoor })
        callbacks.AssignRoomToExitDoor(nil, {}, function(door, assigned)
            lu.assertEquals(assigned.__runPlannerExecutionRoomId, "main")
            door.Room, door.RewardType = assigned, assigned.ChosenRewardType
            run.CurrentRoom.OfferedRewards = {
                [door.ObjectId] = { Type = assigned.ChosenRewardType, ForceLootName = assigned.ForceLootName },
            }
        end, plannedDoor, nativeTarget)
    end, _G.CurrentRun, hubRoom)

    lu.assertNil(hubRoom.UnavailableDoors[101])
    lu.assertTrue(hubRoom.UnavailableDoors[102])
    lu.assertEquals(plannedDoor.Room.ChosenRewardType, "Boon")
    lu.assertEquals(plannedDoor.Room.ForceLootName, "ApolloUpgrade")
    lu.assertEquals(_G.CurrentRun.CurrentRoom.OfferedRewards[101], {
        Type = "Boon", ForceLootName = "ApolloUpgrade",
    })
    _G.MapState, _G.game, _G.CurrentRun, _G.CollapseTableOrdered =
        priorMap, priorGame, priorRun, priorCollapse
end

function TestNavigationHooks.testEphyraLocalSlotsUseNativeCounterAndForceGeneratedRoomReward()
    local module, _, callbacks = capture()
    local child = {
        id = "side", gameName = "N_Sub01", biomeKey = "N",
        overview = { incomingReward = {
            rewardType = "MaxHealthDropSmall", resolvedStoreKey = "SubRoomRewards",
        } },
    }
    local main = {
        id = "main", gameName = "N_Combat02", biomeKey = "N",
        overview = { additional = {}, localSlots = {
            {
                slotKey = "side1", physicalDoorId = 201, generation = "generated",
                room = { id = "side", biomeKey = "N", gameName = "N_Sub01" },
                reward = child.overview.incomingReward,
            },
            { slotKey = "side2", physicalDoorId = 202, generation = "notGenerated" },
        } },
        doors = { kind = "terminal" },
    }
    local plan = {
        selectedOccurrenceIds = { "main", "side" },
        occurrencesById = { main = main, side = child },
    }
    local cursor = routeSession.new(plan)
    assert(routeSession.enter(cursor, "main", "N_Combat02"))
    local state = { state = "synchronized", plan = plan, route = cursor }
    local room = {
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local scope = navigation.attach(module, stub(), function() return state end, function() end,
        routeSession, room)

    local priorMap, priorGame, priorRun, priorCollapse =
        _G.MapState, _G.game, _G.CurrentRun, _G.CollapseTableOrdered
    local generatedDoor = {
        ObjectId = 201, ChooseRoomArgs = { ForceNextRoomSet = "N_SubRooms" },
    }
    local returnDoor = { ObjectId = 999 }
    local nativeMain = { Name = "N_Combat02", __runPlannerExecutionRoomId = "main" }
    _G.CurrentRun = {
        CurrentRoom = nativeMain, NumSubRoomsSpawned = 0,
        RewardStores = { SubRoomRewards = { { Name = "MaxManaDropSmall" }, { Name = "MaxHealthDropSmall" } } },
    }
    _G.MapState = { OfferedExitDoors = { [201] = generatedDoor, [999] = returnDoor } }
    _G.game = { RoomData = {
        N_Sub01 = { Name = "N_Sub01" },
        N_SubWrong = { Name = "N_SubWrong" },
    } }
    _G.CollapseTableOrdered = function() return { generatedDoor, returnDoor } end

    callbacks.CheckN_SubRoomDoorUnavailable(nil, {}, function(_, args)
        lu.assertEquals(args.AboveMinAvailableChance, 1)
        _G.CurrentRun.NumSubRoomsSpawned = _G.CurrentRun.NumSubRoomsSpawned + 1
    end, generatedDoor, { AboveMinAvailableChance = 0.3 })
    local disabledBaseCalled = false
    callbacks.CheckN_SubRoomDoorUnavailable(nil, {}, function()
        disabledBaseCalled = true
    end, { ObjectId = 202 }, { AboveMinAvailableChance = 0.3 })
    callbacks.DoUnlockRoomExits(nil, {}, function(run)
        local nativeTarget = callbacks.ChooseNextRoomData(nil, {}, function()
            return { Name = "N_SubWrong" }
        end, run, generatedDoor.ChooseRoomArgs, { generatedDoor, returnDoor })
        nativeTarget.ChosenRewardType = callbacks.ChooseRoomReward(nil, {},
            function(currentRun, candidate, store)
                for _, reward in ipairs(currentRun.RewardStores[store]) do
                    if callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                        currentRun, candidate, reward, {}, {}) then return reward.Name end
                end
            end, run, nativeTarget, "SubRoomRewards", {}, { Door = generatedDoor })
        callbacks.AssignRoomToExitDoor(nil, {}, function(door, assigned)
            lu.assertEquals(assigned.__runPlannerExecutionRoomId, "side")
            door.Room, door.RewardType = assigned, assigned.ChosenRewardType
        end, generatedDoor, nativeTarget)
    end, _G.CurrentRun, nativeMain)
    local proved, errorValue = scope.proveOutgoingDoors(state, _G.CurrentRun)

    lu.assertFalse(disabledBaseCalled)
    lu.assertEquals(_G.CurrentRun.NumSubRoomsSpawned, 1)
    lu.assertTrue(nativeMain.UnavailableDoors[202])
    lu.assertEquals(generatedDoor.Room.Name, "N_Sub01")
    lu.assertEquals(generatedDoor.Room.__runPlannerExecutionRoomId, "side")
    lu.assertEquals(generatedDoor.Room.ChosenRewardType, "MaxHealthDropSmall")
    lu.assertTrue(proved, errorValue)
    _G.MapState, _G.game, _G.CurrentRun, _G.CollapseTableOrdered =
        priorMap, priorGame, priorRun, priorCollapse
end
