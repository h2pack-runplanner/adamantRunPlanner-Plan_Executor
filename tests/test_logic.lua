local lu = require("luaunit")
local protocol = require("mods/protocol")
local session = require("mods/session")
local logic = require("mods/logic")
local fixtures = require("tests/harness/fixture_loader")

TestLogic = {}

local function fixturePlan()
    return assert(protocol.decode(fixtures.decode()))
end

local function gameFor(plan)
    local roomData = {}
    for _, room in ipairs(plan.rooms) do
        roomData[room.gameName] = roomData[room.gameName] or { Name = room.gameName, RoomSetName = room.biomeKey }
    end
    return {
        RoomData = roomData,
        LootData = { ApolloUpgrade = {} },
        CreateRoom = function(data)
            local copy = {}
            for key, value in pairs(data) do copy[key] = value end
            return copy
        end,
    }
end

local function applyRunState(run, snapshot)
    run.BiomeDepthCache = snapshot.counters.biomeDepthCache
    run.BiomeEncounterDepth = snapshot.counters.biomeEncounterDepth
    run.EncounterDepth = snapshot.counters.routeEncounterDepth
    run.RoomHistory = {}
    for index = 1, snapshot.counters.roomHistoryOrdinal do run.RoomHistory[index] = {} end
    run.RewardStores = {}
    for _, bag in ipairs(snapshot.bags) do
        run.RewardStores[bag.storeKey] = {}
        for index = 1, bag.remaining.count do run.RewardStores[bag.storeKey][index] = {} end
    end
end

function TestLogic.testGateBHooksRealizeBatchAndObserveSelectedRoom()
    local plan = fixturePlan()
    local state = session.newState()
    local wrapped, statusWrites = {}, {}
    local data = {
        inbox = { load = function() return true, plan end },
        session = {
            defineCache = function() end, get = function() return state end,
            startNewRun = session.startNewRun, chooseStartingRoom = session.chooseStartingRoom,
            status = session.status, observeRoom = session.observeRoom,
            chooseRoomReward = session.chooseRoomReward,
            chooseNextRoomData = session.chooseNextRoomData,
            prepareBatchRewardStore = session.prepareBatchRewardStore,
            observeExit = session.observeExit,
            commitExit = session.commitExit,
            observeBeforeRoomExit = session.observeBeforeRoomExit,
            prepareRewardSource = session.prepareRewardSource,
        },
    }
    local moduleRef = { hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }
    logic.attach(moduleRef, data)
    _G.game = gameFor(plan)
    local runtime = { status = { write = function(key, value) statusWrites[key] = value end } }
    local args = { StartingBiome = "F" }
    local currentRun
    local result = wrapped.StartNewRun(
        { isEnabled = function() return true end }, runtime,
        function(previousRun)
            currentRun = { CurrentRoom = { RoomSetName = "F" }, RewardPriorities = { "Other" }, previous = previousRun }
            applyRunState(currentRun, plan.rooms[1].trace[1].runState)
            currentRun.StartingRoom = wrapped.ChooseStartingRoom(nil, runtime, function() return { Name = "vanilla" } end, currentRun, args)
            return currentRun
        end, nil, args)
    lu.assertEquals(result, currentRun)
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(currentRun.StartingRoom.__runPlannerExecutionRoomId, "golden-f-start")

    local lifecycle = {}
    currentRun.CurrentRoom = currentRun.StartingRoom
    currentRun.CurrentRoom.RunOverrides = { BiomeDepthCache = 0 }
    -- Model the vanilla portion of StartRoom that runs before its nested
    -- preload seam.  The observer must see initialized cache values here,
    -- while the later encounter-start transition remains after observation.
    currentRun.BiomeDepthCache = currentRun.CurrentRoom.RunOverrides.BiomeDepthCache
    currentRun.BiomeEncounterDepth = nil
    currentRun.EncounterDepth = 1
    lifecycle[#lifecycle + 1] = "cache-initialized"
    wrapped.StartRoomPreLoadBinks(nil, runtime, function(argsValue)
        lifecycle[#lifecycle + 1] = "encounter-start"
        currentRun.BiomeEncounterDepth = 2
        return argsValue
    end, { Run = currentRun, Room = currentRun.StartingRoom, Encounter = {} })
    lu.assertTrue(state.diagnostics.roomEntered)
    lu.assertEquals(lifecycle, { "cache-initialized", "encounter-start" })
    lu.assertEquals(currentRun.BiomeEncounterDepth, 2)
    currentRun.CurrentRoom = currentRun.StartingRoom
    wrapped.ChooseRoomReward(nil, runtime, function() return { Name = "Boon" } end, result, currentRun.StartingRoom, "RunProgress", {}, {})
    local opening = plan.rooms[1]
    local doors = { { Name = opening.outgoing.targets[1].type } }
    local targetData = wrapped.ChooseNextRoomData(nil, runtime, function() error("base should not realize planner peer") end, result, {}, doors)
    lu.assertEquals(targetData.__runPlannerExecutionExitIndex, 1)
    doors[1].Room = targetData
    wrapped.DoUnlockRoomExits(nil, runtime, function(run, room) return room end, result, currentRun.StartingRoom)
    applyRunState(currentRun, plan.rooms[1].trace[2].runState)
    local observedSourceAtCommit = false
    local destinationCommittedBeforeLeaveReturns = false
    local updated = wrapped.LeaveRoom(nil, runtime, function(run, door)
        local updateResult = wrapped.UpdateRunHistoryCache(nil, runtime, function(liveRun, roomAdded)
            observedSourceAtCommit = state.currentRoomId == plan.rooms[1].id
            return "updated"
        end, run, plan.rooms[1].gameName)
        destinationCommittedBeforeLeaveReturns = state.currentRoomId == targetData.__runPlannerExecutionRoomId
        return updateResult
    end, result, doors[1])
    lu.assertEquals(updated, "updated")
    lu.assertTrue(observedSourceAtCommit)
    lu.assertTrue(destinationCommittedBeforeLeaveReturns)
    lu.assertTrue(state.diagnostics.beforeRoomExit)
    for _, room in ipairs(plan.rooms) do
        if room.id == targetData.__runPlannerExecutionRoomId then
            applyRunState(currentRun, room.trace[1].runState)
            break
        end
    end
    currentRun.CurrentRoom = targetData
    wrapped.StartRoomPreLoadBinks(nil, runtime, function(argsValue) return argsValue end, {
        Run = result,
        Room = targetData,
        Encounter = {},
    })
    lu.assertEquals(state.currentRoomId, "golden-f-b1-e1")
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(statusWrites.ExecutionSessionStatus, "synchronized: room-entry-observed")
end

function TestLogic.testStartOutsideLifecycleCannotFreezePlan()
    local plan = fixturePlan()
    local state = session.newState()
    local wrapped = {}
    local data = {
        inbox = { load = function() return true, plan end },
        session = {
            defineCache = function() end, get = function() return state end,
            startNewRun = session.startNewRun, chooseStartingRoom = session.chooseStartingRoom,
            status = session.status, observeRoom = session.observeRoom,
            chooseRoomReward = session.chooseRoomReward,
            chooseNextRoomData = session.chooseNextRoomData,
            prepareBatchRewardStore = session.prepareBatchRewardStore,
            observeExit = session.observeExit,
            commitExit = session.commitExit,
            observeBeforeRoomExit = session.observeBeforeRoomExit,
            prepareRewardSource = session.prepareRewardSource,
        },
    }
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, data)
    local fallback = 0
    wrapped.ChooseStartingRoom(nil, { status = {} }, function() fallback = fallback + 1; return {} end, { CurrentRoom = { RoomSetName = "F" } }, { StartingBiome = "F" })
    lu.assertEquals(fallback, 1)
    lu.assertFalse(state.initialized)
end

function TestLogic.testPreContactMismatchDelegatesToVanillaAndFreezesPlannerSuffix()
    local plan = fixturePlan()
    local state = session.newState()
    local wrapped = {}
    local data = {
        inbox = { load = function() return true, plan end },
        session = {
            defineCache = function() end, get = function() return state end,
            startNewRun = session.startNewRun, chooseStartingRoom = session.chooseStartingRoom,
            status = session.status, observeRoom = session.observeRoom,
            chooseRoomReward = session.chooseRoomReward,
            chooseNextRoomData = session.chooseNextRoomData,
            prepareBatchRewardStore = session.prepareBatchRewardStore,
            observeExit = session.observeExit, commitExit = session.commitExit,
            observeBeforeRoomExit = session.observeBeforeRoomExit,
            prepareRewardSource = session.prepareRewardSource,
        },
    }
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, data)
    local runtime = { status = { write = function() end } }
    local run = { CurrentRoom = { RoomSetName = "F" } }
    wrapped.StartNewRun({ isEnabled = function() return true end }, runtime, function() return run end, nil, { StartingBiome = "F" })
    local baseCalls = 0
    local result = wrapped.ChooseNextRoomData(nil, runtime, function()
        baseCalls = baseCalls + 1
        return "vanilla-room"
    end, run, {}, {})
    lu.assertEquals(result, "vanilla-room")
    lu.assertEquals(baseCalls, 1)
    lu.assertEquals(state.state, "desynchronized")
    local second = wrapped.ChooseNextRoomData(nil, runtime, function()
        baseCalls = baseCalls + 1
        return "vanilla-suffix"
    end, run, {}, {})
    lu.assertEquals(second, "vanilla-suffix")
    lu.assertEquals(baseCalls, 2)
end

return TestLogic
