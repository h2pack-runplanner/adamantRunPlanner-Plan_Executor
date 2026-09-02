-- luacheck: globals TestRuntimeSession
local lu = require("luaunit")
local runtime = require("mods/runtime_session")
local route = require("mods/route_session")

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
    local value = { state = "synchronized", route = route.new(plan), diagnostics = {} }
    assert(runtime.enter(value, "one", "F_Test"))
    return value
end

function TestRuntimeSession.testEveryFallbackContactAcceptsPreferredAndFallbackButNotNeither()
    for _, contact in ipairs(contacts) do
        local relation = {
            availabilityContact = contact, preferredKey = "preferred", fallbackKey = "fallback",
        }
        local preferred = state(contact)
        local owner = preferred.route.current.bindings.owner.owner
        local key, row = runtime.resolveFallback(preferred, owner, contact, relation,
            function(candidate) return candidate == "preferred" end, {})
        lu.assertEquals(key, "preferred")
        lu.assertTrue(runtime.complete(preferred, row, true))
        lu.assertTrue(preferred.route.current.completedOwners.owner)

        local fallback = state(contact)
        owner = fallback.route.current.bindings.owner.owner
        key, row = runtime.resolveFallback(fallback, owner, contact, relation,
            function(candidate) return candidate == "fallback" end, {})
        lu.assertEquals(key, "fallback")
        lu.assertTrue(runtime.complete(fallback, row, true))
        lu.assertTrue(fallback.route.current.completedOwners.owner)

        local neither = state(contact)
        owner = neither.route.current.bindings.owner.owner
        lu.assertNil(runtime.resolveFallback(neither, owner, contact, relation,
            function() return false end, {}))
        lu.assertEquals(neither.state, "desynchronized")
        lu.assertNil(neither.route.current.completedOwners.owner)
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
