local lu = require("luaunit")
local logic = require("mods/logic")
local protocol = require("mods/protocol")
local session = require("mods/session")
local fixtures = require("tests/harness/fixture_loader")

TestLogic = {}

local function fixturePlan()
    return assert(protocol.decode(fixtures.decode()))
end

function TestLogic.testStartNewRunInitializesBeforeVanillaNestedStartingRoom()
    local state = session.newState()
    local currentState = state
    local wrapped = {}
    local data = {
        inbox = { load = function() return true, fixturePlan() end },
        session = {
            defineCache = function() end,
            get = function() return currentState end,
            startNewRun = session.startNewRun,
            chooseStartingRoom = session.chooseStartingRoom,
            status = session.status,
            observeRoom = session.observeRoom,
            chooseRoomReward = session.chooseRoomReward,
        },
    }
    local moduleRef = {
        hooks = {
            wrap = function(name, _, callback) wrapped[name] = callback end,
        },
    }
    logic.attach(moduleRef, data)

    local roomCreates, vanillaStartingRoomCalls = 0, 0
    _G.game = {
        RoomData = { F_Opening01 = { Name = "F_Opening01", RoomSetName = "F" } },
        LootData = { ApolloUpgrade = {} },
        CreateRoom = function(roomData)
            roomCreates = roomCreates + 1
            return { Name = roomData.Name, RoomSetName = "F", marker = roomData.__runPlannerExecutionRoomId }
        end,
    }
    local statusWrites = {}
    local runtime = {
        status = {
            write = function(key, value) statusWrites[key] = value end,
        },
    }
    local args = { StartingBiome = "F" }
    local currentRun
    local result = wrapped.StartNewRun(
        { isEnabled = function() return true end },
        runtime,
        function(previousRun)
            currentRun = { CurrentRoom = { RoomSetName = "F" }, previous = previousRun }
            currentRun.StartingRoom = wrapped.ChooseStartingRoom(
                nil,
                runtime,
                function()
                    vanillaStartingRoomCalls = vanillaStartingRoomCalls + 1
                    return { Name = "vanilla" }
                end,
                currentRun,
                args
            )
            return currentRun
        end,
        nil,
        args
    )

    lu.assertEquals(result, currentRun)
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.reason, "plan-frozen")
    lu.assertEquals(roomCreates, 1)
    lu.assertEquals(vanillaStartingRoomCalls, 0)
    lu.assertEquals(currentRun.StartingRoom.marker, "golden-f-start")
    lu.assertEquals(statusWrites.ExecutionSessionStatus, "synchronized: plan-frozen")

    -- The terminal contact is also observed through the managed hook path,
    -- rather than requiring an out-of-band session completion call.
    wrapped.StartRoom(nil, runtime, function(run, room) return room end, result,
        { Name = "F_Opening01", RoomSetName = "F" })
    wrapped.ChooseRoomReward(
        nil,
        runtime,
        function() return { Name = "Boon" } end,
        result,
        { Name = "F_Opening01", RoomSetName = "F" },
        "RunProgress",
        {},
        {}
    )
    wrapped.StartRoom(nil, runtime, function(run, room) return room end, result,
        { Name = "F_Combat02", RoomSetName = "F" })
    lu.assertEquals(state.state, "completed")
    lu.assertEquals(statusWrites.ExecutionSessionStatus, "completed: extent-complete")

    -- A direct hook call outside StartNewRun cannot initialize or freeze a run.
    local standalone = session.newState()
    currentState = standalone
    local fallbackCalls = 0
    wrapped.ChooseStartingRoom(
        nil,
        runtime,
        function() fallbackCalls = fallbackCalls + 1; return { Name = "vanilla" } end,
        { CurrentRoom = { RoomSetName = "F" } },
        args
    )
    lu.assertFalse(standalone.initialized)
    lu.assertEquals(fallbackCalls, 1)
end

return TestLogic
