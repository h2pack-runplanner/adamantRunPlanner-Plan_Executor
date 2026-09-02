-- luacheck: globals TestRoomSessionsV10
local lu = require("luaunit")
local room = require("mods/room_session")
local route = require("mods/route_session")

TestRoomSessionsV10 = {}

local function occurrence()
    local optional, required, dependent = "optional", "required", "dependent"
    return {
        id = "one", gameName = "F_Test", transactionsByOwner = {
            [optional] = { owner = optional, window = { kind = "standard", phase = "beforeCombat" } },
            [required] = { owner = required, window = { kind = "standard", phase = "beforeCombat" } },
            [dependent] = { owner = dependent, window = { kind = "standard", phase = "beforeCombat" } },
        },
        timeline = {
            dependencies = { { owner = dependent, afterOwner = optional } },
            obligations = { { owner = required, checkpoint = "roomExit" } },
        },
        roomExitConformance = { facts = { { kind = "forfeit" } } },
        conformanceExpected = { forfeit = "inactive" },
    }
end

function TestRoomSessionsV10.testOptionalOwnerDoesNotBlockClosureButBlocksItsDependent()
    local session = room.new(occurrence())
    lu.assertTrue(room.openWindow(session, "roomEntered"))
    lu.assertNil(room.complete(session, "dependent"))
    lu.assertEquals(session.firstMismatch.checkpoint, "transaction-prerequisite")
    lu.assertNil(session.completedOwners.dependent)
    local closeable = room.new(occurrence())
    room.openWindow(closeable, "roomEntered")
    lu.assertTrue(room.complete(closeable, "required"))
    lu.assertTrue(room.close(closeable, function() return "inactive" end))
end

function TestRoomSessionsV10.testConformanceMismatchIsAtomicAndBlocking()
    local session = room.new(occurrence())
    lu.assertTrue(room.complete(session, "required"))
    lu.assertNil(room.close(session, function() return "consumed" end))
    lu.assertFalse(session.closed)
    lu.assertEquals(session.firstMismatch.checkpoint, "room-exit-conformance:forfeit")
end

function TestRoomSessionsV10.testObligationAndDiagnosticRemainSeparate()
    local session = room.new(occurrence())
    lu.assertNil(room.checkpoint(session, "roomExit"))
    lu.assertEquals(session.firstMismatch.checkpoint, "obligation:roomExit")
    local routeState = route.new({ selectedOccurrenceIds = { "one" }, occurrencesById = { one = occurrence() } })
    lu.assertNotNil(route.enter(routeState, "one", "F_Test"))
    routeState.diagnostics[#routeState.diagnostics + 1] = { expected = "different", observed = "native" }
    lu.assertNil(routeState.firstMismatch)
end

function TestRoomSessionsV10.testTerminalPrefixIgnoresLaterRoomEntry()
    local state = route.new({ selectedOccurrenceIds = { "one" }, occurrencesById = { one = occurrence() } })
    lu.assertNotNil(route.enter(state, "one", "F_Test"))
    lu.assertTrue(room.complete(state.current, "required"))
    lu.assertTrue(route.exit(state, function() return "inactive" end))
    lu.assertTrue(route.enter(state, "unsupported", "H_Opening"))
end

function TestRoomSessionsV10.testBoundOwnerTypoMismatchesButDeclaredIncidentalDoesNot()
    local session = room.new(occurrence())
    lu.assertNil(room.complete(session, "requred"))
    lu.assertEquals(session.firstMismatch.checkpoint, "transaction-owner")
    local incidental = room.new(occurrence())
    lu.assertTrue(room.incidental(incidental))
    lu.assertNil(incidental.firstMismatch)
end

function TestRoomSessionsV10.testClosedRoomDisposesEveryPublicOperation()
    local session = room.new(occurrence())
    room.openWindow(session, "roomEntered")
    lu.assertTrue(room.complete(session, "required"))
    lu.assertTrue(room.close(session, function() return "inactive" end))
    lu.assertNil(room.openWindow(session, "afterCombat"))
    lu.assertNil(room.complete(session, "optional"))
    lu.assertNil(room.incidental(session))
    lu.assertNil(room.prove(session, "overview", true, true))
    lu.assertNil(room.checkpoint(session, "roomExit"))
end

function TestRoomSessionsV10.testEveryPublishedLifecycleWindowAndCheckpointIsUsable()
    local windows = {
        { kind = "standard", phase = "beforeCombat", open = "roomEntered" },
        { kind = "standard", phase = "afterCombat", open = "afterCombat" },
        { kind = "encounterEnd", phaseKey = "one", open = "encounterEnd:one" },
        { kind = "bossDefeated", phaseKey = "one", open = "bossDefeated:one" },
        { kind = "postOutgoing", open = "postOutgoing" },
    }
    for index, row in ipairs(windows) do
        local owner = "window-" .. index
        local entry = occurrence()
        entry.transactionsByOwner = { [owner] = { owner = owner, window = row } }
        entry.timeline = { dependencies = {}, obligations = {
            { owner = owner, checkpoint = "roomEntered" },
            { owner = owner, checkpoint = "outgoingGeneration" },
            { owner = owner, checkpoint = "exitUsable" },
            { owner = owner, checkpoint = "roomExit" },
        } }
        local session = room.new(entry)
        room.openWindow(session, row.open)
        lu.assertTrue(room.complete(session, owner))
        for _, checkpoint in ipairs({ "roomEntered", "outgoingGeneration", "exitUsable", "roomExit" }) do
            lu.assertTrue(room.checkpoint(session, checkpoint))
        end
    end
end

function TestRoomSessionsV10.testOutgoingGenerationDoesNotCloseTheAfterCombatWindow()
    local afterCombatOwner = "after-combat"
    local postOutgoingOwner = "post-outgoing"
    local entry = occurrence()
    entry.transactionsByOwner = {
        [afterCombatOwner] = {
            owner = afterCombatOwner,
            window = { kind = "standard", phase = "afterCombat" },
        },
        [postOutgoingOwner] = {
            owner = postOutgoingOwner,
            window = { kind = "postOutgoing" },
        },
    }
    entry.timeline = { dependencies = {}, obligations = {} }
    local session = room.new(entry)

    lu.assertTrue(room.openWindow(session, "afterCombat"))
    lu.assertTrue(room.openWindow(session, "postOutgoing"))
    lu.assertEquals(session.window, "afterCombat")
    lu.assertTrue(session.outgoingGenerated)
    lu.assertTrue(room.complete(session, afterCombatOwner))
    lu.assertTrue(room.complete(session, postOutgoingOwner))
end

function TestRoomSessionsV10.testRouteRefusesOverlapThenAdvancesExactlyOnce()
    local first, second = occurrence(), occurrence()
    second.id, second.gameName = "two", "F_Next"
    local plan = { selectedOccurrenceIds = { "one", "two" }, occurrencesById = { one = first, two = second } }
    local state = route.new(plan)
    lu.assertNotNil(route.enter(state, "one", "F_Test"))
    lu.assertNil(route.enter(state, "two", "F_Next"))
    lu.assertEquals(state.index, 1)
end

function TestRoomSessionsV10.testRouteAdvancesAcrossSelectedOccurrences()
    local first, second = occurrence(), occurrence()
    second.id, second.gameName = "two", "F_Next"
    local plan = {
        selectedOccurrenceIds = { "one", "two" },
        occurrencesById = { one = first, two = second },
    }
    local state = route.new(plan)
    lu.assertNotNil(route.enter(state, "one", "F_Test"))
    lu.assertTrue(room.complete(state.current, "required"))
    lu.assertTrue(route.exit(state, function() return "inactive" end))
    lu.assertEquals(state.index, 2)
    lu.assertNotNil(route.enter(state, "two", "F_Next"))
end
