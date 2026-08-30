local lu = require("luaunit")
local inbox = require("mods/inbox")
local protocol = require("mods/protocol")
local session = require("mods/session")
local fixtures = require("tests/harness/fixture_loader")
local json = require("mods/json")

TestSession = {}

local function planInbox(plan)
    return {
        load = function() return true, plan end,
    }
end

local function fixturePlan()
    local value = fixtures.decode()
    return assert(protocol.decode(value))
end

local function roomGame()
    return {
        RoomData = { F_Opening01 = { Name = "F_Opening01", RoomSetName = "F" } },
        LootData = { ApolloUpgrade = {} },
        CreateRoom = function(data) return { Name = data.Name, RoomSetName = "F", marker = data.__runPlannerExecutionRoomId } end,
    }
end

function TestSession.testStartNewRunFreezesOnlyAtStartAndRealizesOpening()
    local state = session.newState()
    local plan = fixturePlan()
    local currentRun = { CurrentRoom = { RoomSetName = "F" }, RewardPriorities = { "Other" } }
    session.startNewRun(state, { inbox = planInbox(plan), currentRun = currentRun, args = { StartingBiome = "F" } })
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.reason, "plan-frozen")
    lu.assertEquals(state.plan, plan)
    local room = session.chooseStartingRoom(state, currentRun, { StartingBiome = "F" }, roomGame())
    lu.assertEquals(room.marker, "golden-f-start")
end

function TestSession.testMissingLiveIdentifierBecomesFirstDesynchronization()
    local state = session.newState()
    session.startNewRun(state, { inbox = planInbox(fixturePlan()), currentRun = { CurrentRoom = { RoomSetName = "F" } }, args = { StartingBiome = "F" } })
    local game = roomGame()
    game.RoomData.F_Opening01 = nil
    lu.assertNil(session.chooseStartingRoom(state, {}, {}, game))
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "starting-room")
end

function TestSession.testRoomObservationAndRewardObservationAreSynchronized()
    local state = session.newState()
    local plan = fixturePlan()
    local currentRun = { CurrentRoom = { RoomSetName = "F" }, RewardPriorities = { "Other" } }
    session.startNewRun(state, { inbox = planInbox(plan), currentRun = currentRun, args = { StartingBiome = "F" } })
    local game = roomGame()
    local room = { Name = "F_Opening01", RoomSetName = "F" }
    session.observeRoom(state, currentRun, room)
    lu.assertEquals(state.reason, "room-entry-observed")
    local result = session.chooseRoomReward(state, currentRun, room, game, function(run, _room, store)
        lu.assertEquals(run.RewardPriorities[1], "Boon")
        lu.assertEquals(store, "RunProgress")
        return { Name = "Boon" }
    end, "RunProgress", {}, {})
    lu.assertEquals(result.kind, "handled")
    lu.assertTrue(state.rewardObserved)
    lu.assertEquals(currentRun.RewardPriorities, { "Other" })
    lu.assertEquals(room.ForceLootName, "ApolloUpgrade")
end

function TestSession.testWrongRewardStoreIsTheFirstContactMismatch()
    local state = session.newState()
    local currentRun = { CurrentRoom = { RoomSetName = "F" }, RewardPriorities = { "Other" } }
    session.startNewRun(state, { inbox = planInbox(fixturePlan()), currentRun = currentRun, args = { StartingBiome = "F" } })
    local room = { Name = "F_Opening01", RoomSetName = "F" }
    local result = session.chooseRoomReward(
        state,
        currentRun,
        room,
        roomGame(),
        function() return { Name = "Boon" } end,
        "WrongStore",
        {},
        {}
    )
    lu.assertEquals(result.kind, "failed")
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "reward-store")
    lu.assertEquals(state.firstMismatch.disposition, "conformanceDiscrepancy")
    lu.assertEquals(state.firstMismatch.triggeringAgency, "game")
end

function TestSession.testSelectedContinuationCompletesAndConflictingContinuationIsPlayerDivergence()
    local state = session.newState()
    session.startNewRun(state, {
        inbox = planInbox(fixturePlan()),
        currentRun = { CurrentRoom = { RoomSetName = "F" } },
        args = { StartingBiome = "F" },
    })
    local currentRun = { CurrentRoom = { RoomSetName = "F" } }
    session.observeRoom(state, currentRun, { Name = "F_Opening01", RoomSetName = "F" })
    local rewardRoom = { Name = "F_Opening01", RoomSetName = "F" }
    session.chooseRoomReward(
        state,
        currentRun,
        rewardRoom,
        roomGame(),
        function() return { Name = "Boon" } end,
        "RunProgress",
        {},
        {}
    )
    session.observeRoom(state, currentRun, { Name = "F_Combat02", RoomSetName = "F" })
    lu.assertEquals(state.state, "completed")
    lu.assertEquals(state.reason, "extent-complete")

    local diverged = session.newState()
    session.startNewRun(diverged, {
        inbox = planInbox(fixturePlan()),
        currentRun = { CurrentRoom = { RoomSetName = "F" } },
        args = { StartingBiome = "F" },
    })
    session.observeRoom(diverged, currentRun, { Name = "F_Opening01", RoomSetName = "F" })
    session.chooseRoomReward(
        diverged,
        currentRun,
        rewardRoom,
        roomGame(),
        function() return { Name = "Boon" } end,
        "RunProgress",
        {},
        {}
    )
    session.observeRoom(diverged, currentRun, { Name = "F_Combat03", RoomSetName = "F" })
    lu.assertEquals(diverged.state, "desynchronized")
    lu.assertEquals(diverged.firstMismatch.checkpoint, "next-room")
    lu.assertEquals(diverged.firstMismatch.disposition, "playerDivergence")
    lu.assertEquals(diverged.firstMismatch.triggeringAgency, "player")
    lu.assertEquals(session.status(diverged).disposition, "playerDivergence")
end

function TestSession.testFirstMismatchBlocksFurtherObservation()
    local state = session.newState()
    session.startNewRun(state, { inbox = planInbox(fixturePlan()), currentRun = { CurrentRoom = { RoomSetName = "F" } }, args = { StartingBiome = "F" } })
    session.observeRoom(state, {}, { Name = "WrongRoom", RoomSetName = "F" })
    local first = state.firstMismatch
    session.observeRoom(state, {}, { Name = "F_Opening01", RoomSetName = "F" })
    lu.assertEquals(state.firstMismatch, first)
    lu.assertEquals(state.state, "desynchronized")
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
