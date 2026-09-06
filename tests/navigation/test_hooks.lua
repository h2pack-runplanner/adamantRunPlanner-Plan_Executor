-- luacheck: globals TestNavigationHooks
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local routeSession = require("mods.route.session")
local support = require("tests.harness.hook_composition")
local capture, stub = support.capture, support.stub

TestNavigationHooks = {}

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
    navigation.attach(module, session, function() return state end, function() end,
        {
            current = function() return active.occurrence end,
            reportDestination = function() return true end,
        }, room)
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
    _G.MapState, _G.game, _G.CollapseTableOrdered = priorMap, priorGame, priorCollapse
    lu.assertEquals(selected.__runPlannerExecutionRoomId, "next")
    lu.assertNil(mismatch)
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
    navigation.attach(module, session, function() return state end, function() end,
        {
            current = function() return active.occurrence end,
            reportDestination = function() return true end,
        }, room)

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
    _G.MapState, _G.game, _G.CollapseTableOrdered = priorMap, priorGame, priorCollapse

    lu.assertNil(mismatch)
    lu.assertEquals(forcedRoom, "G_Combat08")
    lu.assertEquals(physicalDoor.Room.Name, "B_Combat01")
    lu.assertEquals(physicalDoor.Room.__runPlannerExecutionRoomId, "anomaly")
    lu.assertEquals(physicalDoor.Room.PrevRoomExitFunctionName, "ExitToAnomalyPresentation")
    lu.assertNil(currentRun.CurrentRoom.DoAnomalies)
end

function TestNavigationHooks.testDoorUseReportsSelectionWithoutAdvancingTheRouteCursor()
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
    local room = {
        current = function() return active end,
        checkpoint = function() return true end,
    }
    navigation.attach(module, stub(), function() return state end, function() end,
        routeSession, room)

    local door = { Room = { __runPlannerExecutionRoomId = "second" } }
    lu.assertEquals(callbacks.UseExitDoor(nil, {}, function() return "native" end, door, {}), "native")

    lu.assertEquals(routeState.index, 1)
    lu.assertEquals(routeState.currentOccurrence, first)
    lu.assertEquals(routeState.selectedDestinationId, "second")
    lu.assertEquals(active.occurrence, first)
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
    local selectedDestination
    local priorGame = _G.game
    _G.game = { RoomData = { F_Next = { GenusName = "F_Next" } } }
    navigation.attach(module, session, function() return state end, function() end,
        {
            current = function() return active.occurrence end,
            reportDestination = function(_, occurrenceId)
                selectedDestination = occurrenceId
                return true
            end,
        }, room)

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
    _G.MapState, _G.CollapseTableOrdered, _G.game = priorMap, priorCollapse, priorGame

    lu.assertNil(mismatch)
    lu.assertEquals(normalDoor.Room.__runPlannerExecutionRoomId, "next")
    lu.assertEquals(chaosDoor.Room.__runPlannerExecutionRoomId, "chaos")
    lu.assertEquals(selectedDestination, "chaos")
end
