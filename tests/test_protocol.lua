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

function TestProtocol.testV5AdditionalAndChaosOfferBoundariesAreStrict()
    mutationRejected(function(value) value.rooms[1].outgoing.additional = nil end)
    mutationRejected(function(value)
        local function object(fields) return setmetatable(fields, { __json_object = true }) end
        local target = value.rooms[2]
        value.rooms[1].outgoing.additional = setmetatable({ object({
            kind = "chaos", key = "chaos", owner = "manual-chaos",
            room = object({ id = target.id, biomeKey = target.biomeKey, gameName = target.gameName }),
            picked = false,
            ixionOrigin = object({ sourceBiomeKey = 3, sourceOccurrenceId = "source", generationKey = "ixion" }),
        }) }, { __json_array = true })
    end)

    local value = fixtures.decode()
    local offer = value.rooms[1].trace[2].roles[1].traitOffer
    offer.kind, offer.giver, offer.options = "chaos", "Chaos", nil
    local function object(fields) return setmetatable(fields, { __json_object = true }) end
    offer.curseOptions = setmetatable({
        object({ curseKey = "ChaosDamageCurse", requirementCount = 2 }),
        object({ curseKey = "ChaosDamageCurse", requirementCount = 3 }),
        object({ curseKey = "ChaosSpeedCurse", requirementCount = 4 }),
    }, { __json_array = true })
    offer.selected, offer.selectedCurseValues = "option2", object({ damageTaken = 0.4 })
    offer.blessingKey, offer.rarity, offer.blessingValues = "ChaosExSpeedBlessing", "Rare", object({
        weaponSpeed = 1.25, propertySpeed = 0.6,
    })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    local decoded = plan.rooms[1].trace[2].roles[1].traitOffer
    lu.assertEquals(decoded.curseOptions[1].curseKey, decoded.curseOptions[2].curseKey)
    lu.assertEquals(decoded.selectedCurseValues.damageTaken, 0.4)
    lu.assertEquals(decoded.blessingValues.weaponSpeed, 1.25)

    value.rooms[1].trace[2].roles[1].traitOffer.selectedCurseValues.damageTaken = 0 / 0
    lu.assertNil(protocol.decode(value))
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

function TestProtocol.testSemanticAddressClosureRejectsCrossRoomAndRoleMutations()
    mutationRejected(function(value)
        value.rooms[1].trace[2].sourceOwner = '["incomingReward","Underworld","F","other-occurrence"]'
    end)
    mutationRejected(function(value)
        value.rooms[1].trace[2].owner = '["acquisitionRole","Underworld","F","[\\"incomingReward\\",\\"Underworld\\",\\"F\\",\\"golden-f-start\\"]","other"]'
    end)
    mutationRejected(function(value)
        value.rooms[1].trace[2].roles[1].settlement.entry = '["acquisitionEntry","Underworld","F","wrong-site","source"]'
    end)
end

function TestProtocol.testMalformedRunStateMapsReturnDecodeErrorsInsteadOfAsserting()
    local value = fixtures.decode()
    value.rooms[1].trace[1].runState.traits.elements = { bad = "not-a-number" }
    local plan, errorMessage = protocol.decode(value)
    lu.assertNil(plan)
    lu.assertNotNil(errorMessage)
end

function TestProtocol.testRewardPrioritiesRetainDuplicateOrder()
    local value = fixtures.decode()
    value.rooms[1].trace[1].runState.rewardPriorities = setmetatable(
        { "Boon", "Boon" },
        { __json_array = true }
    )
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.rooms[1].trace[1].runState.rewardPriorities, { "Boon", "Boon" })
end

function TestProtocol.testTraceBoundMatchesTheProducerDecoder()
    local value = fixtures.decode()
    local first = value.rooms[1].trace[1]
    local trace = setmetatable({}, { __json_array = true })
    for index = 1, 65 do trace[index] = first end
    value.rooms[1].trace = trace
    local plan, errorMessage = protocol.decode(value)
    lu.assertNil(plan)
    lu.assertStrContains(errorMessage, "trace exceeds bound")
end

function TestProtocol.testShopTravelDealAndObjectTraceClosureMatchTheTypeScriptDecoder()
    local value = fixtures.decode()
    local shop
    for _, room in ipairs(value.rooms) do
        if room.contents.shop ~= nil then shop = room.contents.shop; break end
    end
    lu.assertNotNil(shop)
    shop.travelDealRefill = {
        sourceOfferKey = "not-a-slot", slotIndex = 0, optionKey = "RoomRewardHealDrop",
        reward = { rewardType = "MajorNonBoon", producerLifecycleKey = "Shop" },
    }
    lu.assertNil(protocol.decode(value))

    value = fixtures.decode()
    table.insert(value.rooms[1].trace, 2, {
        id = "bad-well", kind = "stygianWellPurchase",
        owner = '["roomAction","Underworld","F","golden-f-start","bad"]',
        generationKey = "initial:healing", offerKey = "HealDropRange",
    })
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testObjectOwnersAndRackResultsUseCanonicalStrings()
    local value = fixtures.decode()
    local fountain
    for _, room in ipairs(value.rooms) do
        for _, step in ipairs(room.trace) do
            if step.kind == "fountainUse" then fountain = step; break end
        end
        if fountain then break end
    end
    lu.assertNotNil(fountain)
    fountain.owner = fountain.owner:gsub('%[\\"useFountain\\"%]', '[\\"interactKeepsakeRack\\"]')
    lu.assertNil(protocol.decode(value))

    local function malformedRack(results)
        local candidate = fixtures.decode()
        local room = candidate.rooms[1]
        room.contents.keepsakeRack = { keepsakeKey = "TestKeepsake" }
        table.insert(room.trace, #room.trace, {
            id = "bad-rack", kind = "keepsakeRackChange",
            owner = '["roomAction","Underworld","F","golden-f-start","[\\"interactKeepsakeRack\\"]"]',
            keepsakeKey = "TestKeepsake", equipResults = results,
        })
        lu.assertNil(protocol.decode(candidate))
    end
    malformedRack({ jeweledPom = { traitKey = "PomTrait", rarity = 3 } })
    malformedRack({ experimentalHammer = { kind = "selected", traitKey = 2 } })
    malformedRack({ transcendentEmbryo = { blessingKey = false } })
end

return TestProtocol
