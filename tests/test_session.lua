local lu = require("luaunit")
local json = require("mods/json")
local protocol = require("mods/protocol")
local session = require("mods/session")
local fixtures = require("tests/harness/fixture_loader")

TestSession = {}

local function planInbox(plan)
    return { load = function() return true, plan end }
end

local function fixturePlan(name)
    local file = assert(io.open(name or fixtures.fixturePath, "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    return assert(protocol.decode(value))
end

local function roomGame(plan)
    local roomData = {}
    for _, room in ipairs(plan.rooms) do
        roomData[room.gameName] = roomData[room.gameName] or { Name = room.gameName, RoomSetName = room.biomeKey }
    end
    return {
        RoomData = roomData,
        LootData = { ApolloUpgrade = {}, ZeusUpgrade = {} },
        CreateRoom = function(data)
            local copy = {}
            for key, value in pairs(data) do copy[key] = value end
            return copy
        end,
    }
end

local function start(plan, currentRun)
    local state = session.newState()
    currentRun = currentRun or { CurrentRoom = { RoomSetName = "F" } }
    session.startNewRun(state, {
        inbox = planInbox(plan), currentRun = currentRun, args = { StartingBiome = "F" },
    })
    return state, currentRun, roomGame(plan)
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
        local count = bag.remaining.count
        for index = 1, count do run.RewardStores[bag.storeKey][index] = {} end
    end
end

function TestSession.testStartNewRunFreezesOnlyAtStartAndRealizesOpening()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan, { CurrentRoom = { RoomSetName = "F" }, RewardPriorities = { "Other" } })
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.reason, "plan-frozen")
    lu.assertEquals(state.plan, plan)
    local room = session.chooseStartingRoom(state, currentRun, { StartingBiome = "F" }, game)
    lu.assertEquals(room.__runPlannerExecutionRoomId, "golden-f-start")
    lu.assertEquals(room.__runPlannerExecutionEncounterPhases[1].encounterKey, "OpeningGeneratedF")
    lu.assertEquals(room.LegalEncounters[1], "OpeningGeneratedF")
end

function TestSession.testMissingLiveIdentifierBecomesFirstDesynchronization()
    local plan = fixturePlan()
    local state, _, game = start(plan)
    game.RoomData.F_Opening01 = nil
    lu.assertNil(session.chooseStartingRoom(state, {}, {}, game))
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "starting-room")
end

function TestSession.testTwoDoorGenerationPreservesPhysicalOrderAndSelectedBranch()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    applyRunState(currentRun, plan.rooms[1].trace[1].runState)
    local opening = session.chooseStartingRoom(state, currentRun, {}, game)
    currentRun.CurrentRoom = opening
    session.observeRoom(state, currentRun, opening)
    local store = session.prepareBatchRewardStore(state, currentRun)
    lu.assertEquals(store.kind, "handled")
    lu.assertEquals(currentRun.NextRewardStoreName, "MetaProgress")
    local base = function(run) return { Name = "Boon", run = run } end
    local reward = session.chooseRoomReward(state, currentRun, opening, game, base, "RunProgress", {}, {})
    lu.assertEquals(reward.kind, "handled")
    local outgoing = plan.rooms[2].outgoing
    lu.assertEquals(outgoing.kind, "batch")
    local twoDoorRoom
    for _, candidate in ipairs(plan.rooms) do
        if candidate.outgoing.kind == "batch" and #candidate.outgoing.targets == 2 then twoDoorRoom = candidate; break end
    end
    lu.assertNotNil(twoDoorRoom)
    state.currentRoomId = twoDoorRoom.id
    currentRun.CurrentRoom = { Name = twoDoorRoom.gameName, RoomSetName = twoDoorRoom.biomeKey, __runPlannerExecutionRoomId = twoDoorRoom.id }
    local doors = {}
    for index, candidate in ipairs(twoDoorRoom.outgoing.targets) do doors[index] = { Name = candidate.type } end
    local first = session.chooseNextRoomData(state, currentRun, {}, doors, game)
    local second = session.chooseNextRoomData(state, currentRun, {}, doors, game)
    lu.assertEquals(first.kind, "handled")
    lu.assertEquals(second.kind, "handled")
    lu.assertEquals(first.roomData.__runPlannerExecutionExitIndex, 1)
    lu.assertEquals(second.roomData.__runPlannerExecutionExitIndex, 2)
    lu.assertEquals(first.roomData.__runPlannerExecutionRoomId, twoDoorRoom.outgoing.targets[1].room.id)
    lu.assertEquals(second.roomData.__runPlannerExecutionRoomId, twoDoorRoom.outgoing.targets[2].room.id)
end

function TestSession.testGeneratedPeersResolveRewardsWithoutAdvancingSource()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    local source = plan.rooms[2]
    lu.assertEquals(source.outgoing.kind, "batch")
    lu.assertEquals(#source.outgoing.targets, 2)
    state.currentRoomId = source.id
    currentRun.CurrentRoom = {
        Name = source.gameName, RoomSetName = source.biomeKey,
        __runPlannerExecutionRoomId = source.id,
    }
    local doors = {}
    for index, target in ipairs(source.outgoing.targets) do doors[index] = { Name = target.type } end
    local generated = {}
    for index = 1, 2 do
        generated[index] = session.chooseNextRoomData(state, currentRun, {}, doors, game)
        lu.assertEquals(generated[index].kind, "handled")
    end
    local selected = source.outgoing.targets[1]
    local boon = session.chooseRoomReward(
        state, currentRun, generated[1].roomData, game,
        function() return { Name = "Boon" } end, "RunProgress", {}, {}
    )
    lu.assertEquals(boon.kind, "handled")
    lu.assertEquals(generated[1].roomData.ForceLootName, "ZeusUpgrade")
    local sourceResult = session.prepareRewardSource(state, currentRun, generated[1].roomData)
    lu.assertEquals(sourceResult.kind, "handled")
    lu.assertEquals(generated[1].roomData.ForceLootName, "ZeusUpgrade")
    local minor = session.chooseRoomReward(
        state, currentRun, generated[2].roomData, game,
        function() return { Name = "MaxHealthDrop" } end, "RunProgress", {}, {}
    )
    lu.assertEquals(minor.kind, "handled")
    lu.assertEquals(state.currentRoomId, source.id)
    lu.assertEquals(selected.room.id, generated[1].roomData.__runPlannerExecutionRoomId)
end

function TestSession.testThreeDoorGenerationPreservesPhysicalOrder()
    local plan = fixturePlan("test/fixtures/execution-plan/fg.execution.json")
    local state, currentRun, game = start(plan)
    local source
    for _, candidate in ipairs(plan.rooms) do
        if candidate.outgoing.kind == "batch" and #candidate.outgoing.targets == 3 then source = candidate; break end
    end
    lu.assertNotNil(source)
    state.currentRoomId = source.id
    currentRun.CurrentRoom = { Name = source.gameName, RoomSetName = source.biomeKey, __runPlannerExecutionRoomId = source.id }
    local doors = {}
    for index, target in ipairs(source.outgoing.targets) do doors[index] = { Name = target.type } end
    for index = 1, 3 do
        local result = session.chooseNextRoomData(state, currentRun, {}, doors, game)
        lu.assertEquals(result.kind, "handled")
        lu.assertEquals(result.roomData.__runPlannerExecutionExitIndex, index)
    end
end

function TestSession.testSelectedAndUnpickedDoorIdentityControlsTraversal()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    local source = plan.rooms[2]
    state.currentRoomId = source.id
    currentRun.CurrentRoom = { Name = source.gameName, RoomSetName = source.biomeKey, __runPlannerExecutionRoomId = source.id }
    local outgoing = source.outgoing
    lu.assertEquals(outgoing.kind, "batch")
    local generatedRooms = {}
    local doors = {}
    for index, candidate in ipairs(outgoing.targets) do doors[index] = { Name = candidate.type } end
    for index, candidate in ipairs(outgoing.targets) do
        local generated = session.chooseNextRoomData(state, currentRun, {}, doors, game)
        generatedRooms[index] = generated.roomData
    end
    -- Use marked copies directly for the observation-only branch witness.
    local selected = outgoing.targets[1]
    local selectedDoor = { Name = selected.type, Room = generatedRooms[1] }
    session.observeExit(state, currentRun, selectedDoor)
    session.commitExit(state)
    lu.assertEquals(state.currentRoomId, selected.room.id)

    local diverged, run2 = start(plan)
    diverged.currentRoomId = source.id
    run2.CurrentRoom = { Name = source.gameName, RoomSetName = source.biomeKey, __runPlannerExecutionRoomId = source.id }
    local unpicked = outgoing.targets[2]
    session.observeExit(diverged, run2, { Name = unpicked.type, Room = generatedRooms[2] })
    lu.assertEquals(diverged.state, "desynchronized")
    lu.assertEquals(diverged.firstMismatch.disposition, "playerDivergence")
end

function TestSession.testFixedPrebossBossPostbossLinksAndTerminalCompletion()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    local preboss = plan.rooms[20]
    local boss = plan.rooms[22]
    local postboss = plan.rooms[23]
    state.currentRoomId = preboss.id
    currentRun.CurrentRoom = { Name = preboss.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = preboss.id }
    local bossData = session.chooseNextRoomData(state, currentRun, {}, nil, game)
    lu.assertEquals(bossData.kind, "handled")
    session.observeExit(state, currentRun, { Room = bossData.roomData })
    session.commitExit(state)
    lu.assertEquals(state.currentRoomId, boss.id)
    currentRun.CurrentRoom = { Name = boss.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = boss.id }
    local postData = session.chooseNextRoomData(state, currentRun, {}, nil, game)
    session.observeExit(state, currentRun, { Room = postData.roomData })
    session.commitExit(state)
    lu.assertEquals(state.currentRoomId, postboss.id)
    currentRun.CurrentRoom = { Name = postboss.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = postboss.id }
    session.observeExit(state, currentRun, { Room = nil })
    session.commitExit(state)
    lu.assertEquals(state.state, "completed")
end

function TestSession.testRunStateDiagnosticsCompareExactCountersAndBags()
    local plan = fixturePlan()
    local first = plan.rooms[1].trace[1].runState
    local exit = plan.rooms[1].trace[2].runState
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, first)
    local state = start(plan, run)
    session.observeRoom(state, run, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(state.state, "synchronized")
    lu.assertTrue(state.diagnostics.roomEntered)
    local opening = plan.rooms[1]
    local doors = { { Name = opening.outgoing.targets[1].type } }
    run.CurrentRoom = { Name = opening.gameName, RoomSetName = opening.biomeKey, __runPlannerExecutionRoomId = opening.id }
    local target = session.chooseNextRoomData(state, run, {}, doors, roomGame(plan))
    session.observeExit(state, run, { Name = doors[1].Name, Room = target.roomData })
    applyRunState(run, exit)
    session.observeBeforeRoomExit(state, run)
    lu.assertEquals(state.state, "synchronized")
    lu.assertTrue(state.diagnostics.beforeRoomExit)
    run.EncounterDepth = exit.counters.routeEncounterDepth + 1
    session.observeBeforeRoomExit(state, run)
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "beforeRoomExit")
end

function TestSession.testMissingRunStateValueIsAConformanceMismatch()
    local plan = fixturePlan()
    local snapshot = plan.rooms[1].trace[1].runState
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    run.EncounterDepth = nil
    local state = start(plan, run)
    session.observeRoom(state, run, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "roomEntered")
    lu.assertEquals(state.firstMismatch.disposition, "conformanceDiscrepancy")

    local missingBagRun = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(missingBagRun, snapshot)
    missingBagRun.RewardStores.MetaProgress = nil
    local missingBagState = start(plan, missingBagRun)
    session.observeRoom(missingBagState, missingBagRun, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(missingBagState.state, "desynchronized")
    lu.assertEquals(missingBagState.firstMismatch.checkpoint, "roomEntered")
    lu.assertEquals(missingBagState.firstMismatch.disposition, "conformanceDiscrepancy")
end

function TestSession.testFirstMismatchBlocksFurtherObservation()
    local state = start(fixturePlan())
    session.observeRoom(state, {}, { Name = "WrongRoom", RoomSetName = "F" })
    local first = state.firstMismatch
    lu.assertEquals(first.disposition, "conformanceDiscrepancy")
    session.observeRoom(state, {}, { Name = "F_Opening01", RoomSetName = "F" })
    lu.assertEquals(state.firstMismatch, first)
    lu.assertEquals(state.state, "desynchronized")
end

function TestSession.testForcedRewardAndFixedLinkMismatchesAreConformanceDiscrepancies()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    local opening = session.chooseStartingRoom(state, currentRun, {}, game)
    currentRun.CurrentRoom = opening
    local reward = session.chooseRoomReward(
        state, currentRun, opening, game,
        function() return { Name = "Boon" } end, "MetaProgress", {}, {}
    )
    lu.assertEquals(reward.kind, "failed")
    lu.assertEquals(state.firstMismatch.disposition, "conformanceDiscrepancy")

    local fixedState, fixedRun, fixedGame = start(plan)
    local preboss = plan.rooms[20]
    fixedState.currentRoomId = preboss.id
    fixedRun.CurrentRoom = {
        Name = preboss.gameName, RoomSetName = preboss.biomeKey,
        __runPlannerExecutionRoomId = preboss.id,
    }
    local boss = session.chooseNextRoomData(fixedState, fixedRun, {}, nil, fixedGame)
    lu.assertEquals(boss.kind, "handled")
    boss.roomData.__runPlannerExecutionRoomId = "wrong-fixed-room"
    session.observeExit(fixedState, fixedRun, { Room = boss.roomData })
    lu.assertEquals(fixedState.firstMismatch.disposition, "conformanceDiscrepancy")
end

function TestSession.testMalformedAndUnsupportedRunsRemainInactive()
    local cases = {
        { plan = nil, reason = "plan-unavailable:not-published" },
        { plan = { kind = "bad" }, reason = "unsupported-plan" },
    }
    for _, testCase in ipairs(cases) do
        local state = session.newState()
        local loader = testCase.plan == nil
            and { load = function() return false, "not-published" end }
            or planInbox(testCase.plan)
        session.startNewRun(state, { inbox = loader, currentRun = { CurrentRoom = { RoomSetName = "F" } }, args = { StartingBiome = "F" } })
        lu.assertEquals(state.state, "inactive")
        lu.assertEquals(state.reason, testCase.reason)
    end
end

return TestSession
