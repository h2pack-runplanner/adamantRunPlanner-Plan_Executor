local lu = require("luaunit")
local json = require("mods/json")
local protocol = require("mods/protocol")
local fixtures = require("tests/harness/fixture_loader")

TestProtocol = {}

function TestProtocol.testProducerFixtureDecodesToReadyFOpening()
    local plan, errorMessage = protocol.decode(fixtures.decode())
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.kind, "ready")
    lu.assertEquals(plan.routeKey, "Underworld")
    lu.assertEquals(plan.rooms[1].gameName, "F_Opening01")
    lu.assertEquals(plan.rooms[1].contents.incomingReward.source, "ApolloUpgrade")
    lu.assertEquals(plan.rooms[1].outgoing.targets[1].index, 1)
end

local function mutationRejected(mutate)
    local value = fixtures.decode()
    mutate(value)
    local plan = protocol.decode(value)
    lu.assertNil(plan)
end

function TestProtocol.testClosedShapeRejectsUnsupportedAndCoercedValues()
    mutationRejected(function(value) value.extra = true end)
    mutationRejected(function(value) value.protocolVersion = 2 end)
    mutationRejected(function(value) value.catalogVersion = "old-catalog" end)
    mutationRejected(function(value) value.rooms[1].outgoing.targets[1].index = "1" end)
    mutationRejected(function(value) value.rooms[1].outgoing.targets[1].picked = 1 end)
    mutationRejected(function(value) value.rooms[1].outgoing.targets[1].index = 0 end)
    mutationRejected(function(value) value.rooms[1].outgoing.targets[1].index = 17 end)
    mutationRejected(function(value) value.rooms[1].outgoing.targets[1].extra = true end)
    mutationRejected(function(value) value.rooms[1].outgoing.targets[1].type = "" end)
    mutationRejected(function(value) value.rooms[1].outgoing.selectedExitKey = "missing" end)
    mutationRejected(function(value) value.rooms[1].outgoing.targets[1].picked = false end)
    mutationRejected(function(value) value.rooms[1].trace = {} end)
    mutationRejected(function(value) value.rooms[1].trace[1].owner = "another-owner" end)
end

function TestProtocol.testDecodedPlanDoesNotAcceptArbitraryLuaTables()
    local value = fixtures.decode()
    value.rooms[1].outgoing.targets = {}
    setmetatable(value.rooms[1].outgoing.targets, nil)
    lu.assertNil(protocol.decode(value))
    lu.assertNil(protocol.decode(json.decode("[]")))
end

return TestProtocol
