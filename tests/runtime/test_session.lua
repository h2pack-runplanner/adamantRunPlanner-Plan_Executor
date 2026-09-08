-- luacheck: globals TestRuntimeSession
local lu = require("luaunit")
local route = require("mods.route.session")
local room = require("mods.room.coordinator")
local runtime = require("mods.runtime.session")
local timeline = require("mods.room.timeline.bindings")
local timelineSession = require("mods.room.timeline.session")
local protocol = require("mods.protocol.decoder")
local occurrenceProtocol = require("mods.protocol.occurrences")
local json = require("mods.protocol.json")

TestRuntimeSession = {}

local function fingerprintBody(plan)
    return {
        format = plan.format,
        protocolVersion = plan.protocolVersion,
        catalogVersion = plan.catalogVersion,
        projectId = plan.projectId,
        routeKey = plan.routeKey,
        startingLoadout = plan.startingLoadout,
        startingKeepsake = plan.startingKeepsake,
        extent = plan.extent,
        selectedOccurrenceIds = plan.selectedOccurrenceIds,
        resources = plan.resources,
        occurrences = plan.occurrences,
    }
end

local function occurrence()
    return {
        id = "one", gameName = "F_Test", overview = { encounterPhases = {}, requiredObjects = {} },
        transactionsByOwner = {
            owner = {
                owner = "owner", kind = "acquisition", offerKey = "offer",
                window = { kind = "standard", phase = "beforeCombat" },
            },
        },
        timeline = { dependencies = {}, obligations = {} }, doors = { kind = "terminal" },
        roomExitConformance = { facts = {} }, conformanceExpected = {},
    }
end

local function state()
    local row = occurrence()
    local plan = { occurrences = { row }, occurrencesById = { one = row }, selectedOccurrenceIds = { "one" } }
    local value = { state = "synchronized", route = route.new(plan), room = room.new(plan, nil, {
        timelineIndex = timeline.index,
    }), diagnostics = {} }
    local entered = assert(route.enter(value.route, "one", "F_Test"))
    assert(room.enter(value, entered))
    return value
end

function TestRuntimeSession.testLaterRouteConformanceContactsAreRejectedAtStart()
    for _, kind in ipairs({ "echoShopDuplicate", "hermesShrineDeliveries" }) do
        local row = occurrence()
        row.roomExitConformance = { facts = { { kind = kind } } }
        local plan = {
            kind = "ready", occurrences = { row }, occurrencesById = { one = row },
            selectedOccurrenceIds = { "one" },
        }
        local value = {}
        lu.assertNil(runtime.start(value, { load = function() return true, plan end }))
        lu.assertEquals(value.firstMismatch.observed, kind)
    end
end

function TestRuntimeSession.testRunStartMismatchPreservesTheInboxDecoderReason()
    local value = {}
    local fakeInbox = {
        load = function() return false, "malformed-plan" end,
        status = function()
            return { error = { code = "malformed-plan", message = "specific decoder rejection" } }
        end,
    }
    lu.assertNil(runtime.start(value, fakeInbox))
    lu.assertEquals(value.firstMismatch.observed, {
        code = "malformed-plan",
        message = "specific decoder rejection",
    })
end

function TestRuntimeSession.testAdmissionLoadsTheSelectedSlotAndFreezesItsPlan()
    local first = occurrence()
    first.gameName = "F_First"
    local second = occurrence()
    second.id, second.gameName = "two", "F_Second"
    local selected, plans = nil, { [3] = {
        kind = "ready", occurrences = { first }, occurrencesById = { one = first },
        selectedOccurrenceIds = { "one" },
    }, [4] = {
        kind = "ready", occurrences = { second }, occurrencesById = { two = second },
        selectedOccurrenceIds = { "two" },
    } }
    local inbox = {
        load = function(slot) selected = slot; return true, plans[slot] end,
        status = function() return {} end,
    }
    local value = {}
    lu.assertTrue(runtime.start(value, inbox, nil, 3))
    lu.assertEquals(selected, 3)
    lu.assertTrue(rawequal(value.plan, plans[3]))
end

function TestRuntimeSession.testInboxSlotSelectionCannotMutateAnAdmittedPlan()
    local row = occurrence()
    local plan = { kind = "ready", occurrences = { row }, occurrencesById = { one = row }, selectedOccurrenceIds = { "one" } }
    local selected = 1
    local inbox = {
        load = function(slot) selected = slot; return true, plan end,
        select = function(slot) selected = slot end,
        status = function() return {} end,
    }
    local value = {}
    lu.assertTrue(runtime.start(value, inbox, nil, 1))
    inbox.select(6)
    lu.assertEquals(selected, 6)
    lu.assertTrue(rawequal(value.plan, plan))
    lu.assertEquals(value.plan.occurrences[1].id, "one")
end

function TestRuntimeSession.testStartingPhaseExposesOnlyTheBoundedStartingOccurrence()
    local row = occurrence()
    local plan = {
        kind = "ready", occurrences = { row }, occurrencesById = { one = row },
        selectedOccurrenceIds = { "one" },
    }
    local value = {}
    lu.assertTrue(runtime.start(value, { load = function() return true, plan end }, "starting"))
    lu.assertEquals(value.state, "starting")
    lu.assertEquals(route.expected(value.route), row)
    lu.assertNil(room.current(value))
end

function TestRuntimeSession.testPreparedDestinationBindingsAreReusedWhenTheRoomStarts()
    local row = occurrence()
    local plan = { occurrences = { row }, occurrencesById = { one = row }, selectedOccurrenceIds = { "one" } }
    local value = { state = "synchronized", route = route.new(plan), room = room.new(plan, nil, {
        timelineIndex = timeline.index,
    }), diagnostics = {} }

    local prepared = room.prepare(value, row)
    lu.assertNotNil(prepared)
    local native = {}
    local handle = assert(room.resolve(value, prepared, { kind = "offer", offerKey = "offer" }))
    lu.assertTrue(rawequal(assert(room.bind(value, prepared, handle, native)), handle))
    local entered = assert(route.enter(value.route, "one", "F_Test"))
    lu.assertNotNil(room.enter(value, entered))
    lu.assertEquals(value.room.current.occurrence, row)
    lu.assertTrue(rawequal(room.bound(value, value.room.current, native), handle))
    lu.assertNil(value.room.prepared)
end

function TestRuntimeSession.testPreparedBindingsCannotLeakToAnotherOccurrence()
    local first = occurrence()
    local second = occurrence()
    second.id, second.gameName = "two", "F_Next"
    local plan = {
        occurrences = { first, second },
        occurrencesById = { one = first, two = second },
        selectedOccurrenceIds = { "one", "two" },
    }
    local value = { state = "synchronized", route = route.new(plan), room = room.new(plan, nil, {
        timelineIndex = timeline.index,
    }), diagnostics = {} }

    assert(room.prepare(value, second))
    local entered = assert(route.enter(value.route, "one", "F_Test"))
    lu.assertNotNil(room.enter(value, entered))
    lu.assertEquals(value.room.current.occurrence, first)
    lu.assertNil(value.room.prepared)
end

function TestRuntimeSession.testEntryProofFiresThePublishedRoomEnteredDeadline()
    local row = occurrence()
    row.timeline.obligations = { { owner = "owner", checkpoint = "roomEntered" } }
    local plan = { occurrences = { row }, occurrencesById = { one = row }, selectedOccurrenceIds = { "one" } }
    local value = { state = "synchronized", route = route.new(plan), room = room.new(plan, nil, {
        timelineIndex = timeline.index,
    }), diagnostics = {} }
    local entered = assert(route.enter(value.route, "one", "F_Test"))
    assert(room.enter(value, entered))
    lu.assertNil(room.proveEntry(value, { Name = "F_Test" }))
    lu.assertEquals(value.room.current.firstMismatch.checkpoint, "obligation:roomEntered")
end

function TestRuntimeSession.testStrictDecodeTransactionOrderDoesNotChangeRuntimeReadiness()
    local file = assert(io.open("fixtures/execution-plan/fg-ixion-chaos.execution.json", "rb"))
    local source = file:read("*a")
    file:close()
    local function reverseTransactions(plan)
        for _, row in ipairs(plan.occurrences) do
            local transactions = row.timeline.transactions
            for left = 1, math.floor(#transactions / 2) do
                local right = #transactions - left + 1
                transactions[left], transactions[right] = transactions[right], transactions[left]
            end
        end
        return plan
    end

    local raw = assert(json.decode(source))
    -- The strict occurrence decoder materializes derived fields while deriving
    -- the canonical wire fingerprint. Use an isolated decoded copy to derive
    -- the changed wire fingerprint, then decode a second untouched wire copy.
    local fingerprintSource = reverseTransactions(assert(json.decode(source)))
    local decodedRows = assert(occurrenceProtocol.decode(
        fingerprintSource.occurrences,
        fingerprintSource.selectedOccurrenceIds,
        "execution plan.occurrences"
    ))
    for _, row in ipairs(decodedRows) do
        row.transactionsByOwner = nil
        row.conformanceExpected = nil
    end
    local reversed = reverseTransactions(assert(json.decode(source)))
    reversed.planFingerprint = protocol.fingerprint(fingerprintBody(fingerprintSource))

    local decoded = assert(protocol.decode(raw))
    local reordered = assert(protocol.decode(reversed))
    for index, occurrenceRow in ipairs(decoded.occurrences) do
        local first = timelineSession.new(occurrenceRow, timeline.index(occurrenceRow))
        local secondRow = reordered.occurrences[index]
        local second = timelineSession.new(secondRow, timeline.index(secondRow))
        lu.assertEquals(first.prerequisites, second.prerequisites)
        lu.assertEquals(first.obligations, second.obligations)
    end
end
