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
    lu.assertEquals(plan.rooms[1].outgoing.resolvedSharedRewardStoreKey, "MetaProgress")
end

function TestProtocol.testProducerFixtureDecodesFAndGPeerAndFixedTopology()
    local file = assert(io.open("test/fixtures/execution-plan/fg.execution.json", "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.extent.terminalBiomeKey, "G")
    local threeExitBatch, postboss
    for _, room in ipairs(plan.rooms) do
        if room.outgoing.kind == "batch" and #room.outgoing.targets == 3 then threeExitBatch = room end
        if room.gameName == "F_PostBoss01" then postboss = room end
    end
    lu.assertNotNil(threeExitBatch)
    lu.assertEquals(threeExitBatch.outgoing.targets[1].index, 1)
    lu.assertEquals(threeExitBatch.outgoing.targets[3].index, 3)
    lu.assertEquals(postboss.outgoing.kind, "fixed")
    lu.assertEquals(postboss.outgoing.target.gameName, "G_Intro")
end

local function mutationRejected(mutate)
    local value = fixtures.decode()
    mutate(value)
    local plan = protocol.decode(value)
    lu.assertNil(plan)
end

function TestProtocol.testClosedShapeRejectsUnsupportedAndCoercedValues()
    mutationRejected(function(value) value.extra = true end)
    mutationRejected(function(value) value.protocolVersion = 1 end)
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
    mutationRejected(function(value) value.rooms[1].trace[1].runState = nil end)
    mutationRejected(function(value) value.rooms[1].trace[1].owner = "another-owner" end)
end

function TestProtocol.testFixedAndBatchTargetReferencesRetainDecodedRoomIdentity()
    local file = assert(io.open("test/fixtures/execution-plan/fg.execution.json", "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    local fixed
    for _, room in ipairs(value.rooms) do
        if room.gameName == "F_PostBoss01" then fixed = room; break end
    end
    lu.assertNotNil(fixed)
    local originalName = fixed.outgoing.target.gameName
    fixed.outgoing.target.gameName = "G_Combat01"
    local rejected = protocol.decode(value)
    lu.assertNil(rejected)
    fixed.outgoing.target.gameName = originalName
    local batch = value.rooms[1]
    local originalBatchName = batch.outgoing.targets[1].room.gameName
    batch.outgoing.targets[1].room.gameName = "F_Combat03"
    rejected = protocol.decode(value)
    lu.assertNil(rejected)
    batch.outgoing.targets[1].room.gameName = originalBatchName
end

function TestProtocol.testDecodedPlanDoesNotAcceptArbitraryLuaTables()
    local value = fixtures.decode()
    value.rooms[1].outgoing.targets = {}
    setmetatable(value.rooms[1].outgoing.targets, nil)
    lu.assertNil(protocol.decode(value))
    lu.assertNil(protocol.decode(json.decode("[]")))
end

return TestProtocol
