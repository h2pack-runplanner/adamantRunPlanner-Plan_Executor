-- luacheck: globals TestProtocol

local lu = require("luaunit")
local json = require("mods/json")
local protocol = require("mods/protocol")
local fixtures = require("tests/harness/fixture_loader")

TestProtocol = {}

function TestProtocol.testPositiveVectorsMatchProducerManifest()
    for _, name in ipairs({ "representative-f", "complete-underworld", "two-route-stress" }) do
        local value, entry = fixtures.decode(name)
        local plan, err = protocol.decode(value)
        lu.assertNotNil(plan, err)
        lu.assertEquals(plan.kind, "ready")
        lu.assertEquals(plan.protocolVersion, entry.executionProtocolVersion)
        lu.assertEquals(plan.catalogVersion, entry.catalogVersion)
        lu.assertEquals(plan.fingerprint, entry.fingerprint)
        lu.assertEquals(plan.routeKeys, entry.routeKeys)
        for index, route in ipairs(value.execution.routes) do
            lu.assertEquals(route.fingerprint, entry.routeFingerprints[index])
        end
    end
end

function TestProtocol.testProjectOnlyHasNoExecutionPlan()
    local value = fixtures.decode("project-only")
    local plan, err = protocol.decode(value)
    lu.assertNotNil(plan, err)
    lu.assertEquals(plan.kind, "project-only")
    lu.assertEquals(#plan.routeKeys, 0)
    lu.assertNil(plan.execution)
    lu.assertNil(plan.project)
end

local function rejectMutation(fileName, mutate)
    local value = fixtures.decode(fileName)
    mutate(value)
    local plan = protocol.decode(value)
    lu.assertNil(plan)
end

local function firstInstruction(value, kind, predicate)
    for _, route in ipairs(value.execution.routes) do
        for _, instruction in ipairs(route.instructions) do
            if instruction.kind == kind and (not predicate or predicate(instruction)) then
                return instruction
            end
        end
    end
    error("fixture did not contain instruction " .. tostring(kind))
end

function TestProtocol.testExecutionProductsRejectUnknownTagsAndOpenShapes()
    rejectMutation("two-route-stress", function(value)
        value.execution.routes[1].instructions[1].extra = true
    end)
    rejectMutation("representative-f", function(value)
        firstInstruction(value, "authored").incomingReward.producerKind = "future"
    end)
    rejectMutation("representative-f", function(value)
        firstInstruction(value, "authored").incomingReward.offer.payload.kind = "future"
    end)
    rejectMutation("representative-f", function(value)
        local room = firstInstruction(value, "authored", function(item)
            return item.incomingReward and item.incomingReward.producerKind == "shop"
        end)
        room.incomingReward.offer.rewardType = "Boon"
    end)
    rejectMutation("representative-f", function(value)
        firstInstruction(value, "authored", function(room) return room.shop ~= nil end).shop.extra = true
    end)
    rejectMutation("two-route-stress", function(value)
        local room = firstInstruction(value, "authored", function(item) return item.localRewards ~= nil end)
        room.localRewards[1].extra = true
    end)
    rejectMutation("two-route-stress", function(value)
        local room = firstInstruction(value, "authored", function(item) return item.rewardWheels ~= nil end)
        room.rewardWheels[1].pickedOfferIndex = 0
    end)
    rejectMutation("two-route-stress", function(value)
        local room = firstInstruction(value, "authored", function(item) return item.rewardWheels ~= nil end)
        room.rewardWheels[1].offers[1].picked = false
    end)
    rejectMutation("two-route-stress", function(value)
        local room = firstInstruction(value, "authored", function(item) return item.requiredObjects ~= nil end)
        room.requiredObjects[1].key = "future"
    end)
    rejectMutation("two-route-stress", function(value)
        local room = firstInstruction(value, "authored", function(item) return item.anomalyReplacement ~= nil end)
        room.anomalyReplacement.extra = true
    end)
    rejectMutation("two-route-stress", function(value)
        firstInstruction(value, "authored").origin.kind = "future"
    end)
    rejectMutation("two-route-stress", function(value)
        local room = firstInstruction(value, "localChild")
        room.generation = "future"
    end)
    rejectMutation("two-route-stress", function(value)
        firstInstruction(value, "completion").role = "future"
    end)
    rejectMutation("two-route-stress", function(value)
        local batch = firstInstruction(value, "batch")
        batch.targets[1].exit.kind = "unavailable"
    end)
    rejectMutation("two-route-stress", function(value)
        local batch = firstInstruction(value, "batch")
        batch.targets[1].exit.behavior = "future"
    end)
    rejectMutation("two-route-stress", function(value)
        local batch = firstInstruction(value, "batch")
        batch.targets[1].continuation = "future"
    end)
end

function TestProtocol.testContinuationClosureRejectsUnrelatedOrAmbiguousSelections()
    rejectMutation("representative-f", function(value)
        local batch = firstInstruction(value, "batch")
        batch.selectedContinuation.exitKey = "unrelated"
    end)
    rejectMutation("representative-f", function(value)
        local batch = firstInstruction(value, "batch")
        batch.selectedContinuation.instructionId = batch.parent.instructionId
    end)
    rejectMutation("representative-f", function(value)
        local batch = firstInstruction(value, "batch")
        table.insert(batch.targets, batch.targets[1])
    end)
    rejectMutation("two-route-stress", function(value)
        local batch = firstInstruction(value, "batch", function(item) return #item.additional > 0 end)
        local extra = batch.additional[1]
        batch.selectedContinuation = {
            kind = "additional",
            additionalExitKey = extra.key,
            instructionId = batch.targets[1].room.instructionId,
        }
    end)
end

function TestProtocol.testDuplicateBatchParentsRejectAtTheProtocolBoundary()
    rejectMutation("representative-f", function(value)
        local route = value.execution.routes[1]
        local original = firstInstruction(value, "batch")
        local duplicate = {}
        for key, item in pairs(original) do duplicate[key] = item end
        duplicate.id = "duplicate-batch-parent"
        table.insert(route.instructions, duplicate)
    end)
end

function TestProtocol.testJsonKindsAndProjectDiscardAreClosed()
    rejectMutation("representative-f", function(value)
        value.project = value.execution.routes
    end)
    rejectMutation("representative-f", function(value)
        value.project = json.null
    end)
    rejectMutation("representative-f", function(value)
        local batch = firstInstruction(value, "batch")
        batch.targets = value.execution.routes[1]
    end)
    local value = fixtures.decode("representative-f")
    local plan, err = protocol.decode(value)
    lu.assertNotNil(plan, err)
    lu.assertNil(plan.project)
    lu.assertNotNil(plan.execution)
end

function TestProtocol.testNegativeVersionVectorsRejectClosed()
    local cases = {
        { file = "unsupported-file-version.json", code = "unsupported-bundle-version" },
        { file = "unsupported-execution-protocol-version.json", code = "unsupported-execution-protocol-version" },
        { file = "malformed-envelope.json", code = "malformed-bundle" },
    }
    for _, case in ipairs(cases) do
        local file = assert(io.open(fixtures.fixtureDir .. "/" .. case.file, "rb"))
        local value = json.decode(file:read("*a")); file:close()
        local plan, err = protocol.decode(value)
        lu.assertNil(plan)
        if case.code == "malformed-bundle" then
            lu.assertStrContains(err, "bundle")
        else
            lu.assertEquals(err, case.code)
        end
    end
end

function TestProtocol.testMissingReferenceRecipeFailsClosed()
    local plan, err = protocol.decode(fixtures.materializeMissingReference())
    lu.assertNil(plan)
    lu.assertStrContains(err, "missing instruction")
end

function TestProtocol.testBatchDiscriminatorsAreClosedAndExact()
    local value = fixtures.decode("representative-f")
    local batch
    for _, instruction in ipairs(value.execution.routes[1].instructions) do
        if instruction.kind == "batch" then batch = instruction break end
    end
    batch.batchState.kind = "future"
    local plan, err = protocol.decode(value)
    lu.assertNil(plan)
    lu.assertStrContains(err, "unknown kind")

    value = fixtures.decode("representative-f")
    for _, instruction in ipairs(value.execution.routes[1].instructions) do
        if instruction.kind == "batch" then batch = instruction break end
    end
    batch.selectedContinuation.kind = "additional"
    local additionalPlan, additionalErr = protocol.decode(value)
    lu.assertNil(additionalPlan)
    lu.assertStrContains(additionalErr, "additionalExitKey")

    value = fixtures.decode("representative-f")
    for _, instruction in ipairs(value.execution.routes[1].instructions) do
        if instruction.kind == "batch" then batch = instruction break end
    end
    batch.selectedContinuation.additionalExitKey = "naturalChaos"
    local normalPlan, normalErr = protocol.decode(value)
    lu.assertNil(normalPlan)
    lu.assertStrContains(normalErr, "unknown field additionalExitKey")
end

function TestProtocol.testDecoderRejectsDuplicateKeysAndTrailingData()
    local value, err = json.decode('{"fileFormat":"run-planner-bundle","fileFormat":"x"}')
    lu.assertNil(value)
    lu.assertStrContains(err, "duplicate")
    value, err = json.decode("{} trailing")
    lu.assertNil(value)
    lu.assertStrContains(err, "trailing")
end

return TestProtocol
