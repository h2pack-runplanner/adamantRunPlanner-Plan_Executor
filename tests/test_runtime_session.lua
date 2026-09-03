-- luacheck: globals TestRuntimeSession
local lu = require("luaunit")
local runtime = require("mods/runtime_session")
local route = require("mods.route.session")
local room = require("mods.room.coordinator")
local timeline = require("mods.native_timeline_adapters")

TestRuntimeSession = {}

local contacts = {
    "traitEligibility", "storeInventoryGeneration", "storePurchase", "npcConsumableSelection",
}

local function occurrence(contact)
    return {
        id = "one", gameName = "F_Test", overview = { encounterPhases = {}, requiredObjects = {} },
        transactionsByOwner = {
            owner = {
                owner = "owner", kind = "acquisition", offerKey = "offer",
                window = { kind = "standard", phase = "beforeCombat" },
                runtimeFallbacks = {
                    {
                        availabilityContact = contact,
                        preferredKey = "preferred",
                        fallbackKey = "fallback",
                    },
                },
            },
        },
        timeline = { dependencies = {}, obligations = {} }, doors = { kind = "terminal" },
        roomExitConformance = { facts = {} }, conformanceExpected = {},
    }
end

local function state(contact)
    local row = occurrence(contact)
    local plan = { occurrences = { row }, occurrencesById = { one = row }, selectedOccurrenceIds = { "one" } }
    local value = { state = "synchronized", route = route.new(plan), room = room.new(plan, nil, {
        timelineIndex = timeline.index,
    }), diagnostics = {} }
    local entered = assert(route.enter(value.route, "one", "F_Test"))
    assert(room.enter(value, entered))
    return value
end

function TestRuntimeSession.testEveryFallbackContactAcceptsPreferredAndFallbackButNotNeither()
    for _, contact in ipairs(contacts) do
        local relation = {
            availabilityContact = contact, preferredKey = "preferred", fallbackKey = "fallback",
        }
        local preferred = state(contact)
        local owner = preferred.room.current.bindings.owner.owner
        local key, row = runtime.resolveFallback(preferred, owner, contact, relation,
            function(candidate) return candidate == "preferred" end, {})
        lu.assertEquals(key, "preferred")
        lu.assertTrue(runtime.complete(preferred, row, true))
        lu.assertTrue(preferred.room.current.completedOwners.owner)

        local fallback = state(contact)
        owner = fallback.room.current.bindings.owner.owner
        key, row = runtime.resolveFallback(fallback, owner, contact, relation,
            function(candidate) return candidate == "fallback" end, {})
        lu.assertEquals(key, "fallback")
        lu.assertTrue(runtime.complete(fallback, row, true))
        lu.assertTrue(fallback.room.current.completedOwners.owner)

        local neither = state(contact)
        owner = neither.room.current.bindings.owner.owner
        lu.assertNil(runtime.resolveFallback(neither, owner, contact, relation,
            function() return false end, {}))
        lu.assertEquals(neither.state, "desynchronized")
        lu.assertNil(neither.room.current.completedOwners.owner)
        lu.assertNil(room.current(neither))
    end
end

function TestRuntimeSession.testLaterRouteConformanceContactsAreRejectedAtStart()
    for _, kind in ipairs({ "echoShopDuplicate", "hermesShrineDeliveries" }) do
        local row = occurrence("storePurchase")
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

function TestRuntimeSession.testStartingPhaseExposesOnlyTheBoundedStartingOccurrence()
    local row = occurrence("storePurchase")
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
    local row = occurrence("storePurchase")
    local plan = { occurrences = { row }, occurrencesById = { one = row }, selectedOccurrenceIds = { "one" } }
    local value = { state = "synchronized", route = route.new(plan), room = room.new(plan, nil, {
        timelineIndex = timeline.index,
    }), diagnostics = {} }

    local prepared = room.prepare(value, row)
    lu.assertNotNil(prepared)
    prepared.bindings.destinationWitness = true

    local entered = assert(route.enter(value.route, "one", "F_Test"))
    lu.assertNotNil(room.enter(value, entered))
    lu.assertTrue(value.room.current.bindings.destinationWitness)
    lu.assertNil(value.room.prepared)
end
