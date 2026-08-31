local lu = require("luaunit")
local json = require("mods/json")
local protocol = require("mods/protocol")
local fixtures = require("tests/harness/fixture_loader")

TestProtocol = {}

local function object(fields) return setmetatable(fields, { __json_object = true }) end
local function list(values) return setmetatable(values, { __json_array = true }) end
local function semanticAddress(...)
    local values = { ... }
    for index, value in ipairs(values) do
        values[index] = '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    end
    return "[" .. table.concat(values, ",") .. "]"
end

function TestProtocol.testProducerFixtureDecodesToReadyFOpening()
    local plan, errorMessage = protocol.decode(fixtures.decode())
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.kind, "ready")
    lu.assertEquals(plan.routeKey, "Underworld")
    lu.assertEquals(plan.startingKeepsake.keepsakeKey, "ManaOverTimeRefundKeepsake")
    lu.assertNil(plan.startingKeepsake.equipResults)
    lu.assertEquals(plan.rooms[1].gameName, "F_Opening01")
    lu.assertEquals(plan.rooms[1].contents.incomingReward.source, "ApolloUpgrade")
    lu.assertEquals(plan.rooms[1].outgoing.targets[1].index, 1)
    lu.assertEquals(plan.rooms[1].outgoing.resolvedSharedRewardStoreKey, "MetaProgress")
    local first = plan.rooms[1].trace[1]
    lu.assertEquals(first.frame, 0)
    lu.assertNil(first.id)
    lu.assertNil(first.runState)
    lu.assertTrue(first.replace.artificer.present)
    lu.assertNil(first.replace.artificer.value)
end

function TestProtocol.testFramesAreClosedSequentialAndRetainExplicitArtificerClear()
    local function rejected(mutate)
        local value = fixtures.decode()
        mutate(value)
        lu.assertNil(protocol.decode(value))
    end
    rejected(function(value) value.rooms[1].trace[1].replace.counters = nil end)
    rejected(function(value) value.rooms[1].trace[1].frame = 1 end)
    rejected(function(value) value.rooms[1].trace[#value.rooms[1].trace].frame = 0 end)
    rejected(function(value) value.rooms[1].trace[1].frame = 0.5 end)
    rejected(function(value) value.rooms[1].trace[1].replace.unknown = {} end)
    rejected(function(value) value.rooms[1].trace[1].replace.traits = {} end)

    local value = fixtures.decode()
    value.rooms[1].trace[#value.rooms[1].trace].replace.artificer = setmetatable(
        { usedCount = 1, remainingCount = 2 }, { __json_object = true })
    value.rooms[2].trace[1].replace.artificer = json.null
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    local introduced = plan.rooms[1].trace[#plan.rooms[1].trace]
    local cleared = plan.rooms[2].trace[1]
    lu.assertEquals(introduced.replace.artificer.value.remainingCount, 2)
    lu.assertTrue(cleared.replace.artificer.present)
    lu.assertNil(cleared.replace.artificer.value)
    lu.assertNotNil(plan.rooms[2].trace[1].replace)
end

function TestProtocol.testIncomingRewardAcquisitionDispositionIsDecodedExactly()
    local value = fixtures.decode()
    value.rooms[1].contents.incomingReward.acquisitionEnabled = false
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertFalse(plan.rooms[1].contents.incomingReward.acquisitionEnabled)
    value.rooms[1].contents.incomingReward.acquisitionEnabled = "false"
    lu.assertNil(protocol.decode(value))
end

local function firstResolvedEncounterInteraction(value)
    for _, room in ipairs(value.rooms) do
        for _, step in ipairs(room.trace) do
            if step.kind == "encounterInteraction" and step.resolution ~= nil then return step end
        end
    end
    error("fixture has no resolved encounter interaction")
end

local function decodeFixture(path)
    local file = assert(io.open(path, "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    return value
end

function TestProtocol.testEncounterResolutionClosedUnionsRejectCrossVariantFields()
    local value = decodeFixture("test/fixtures/execution-plan/fg.execution.json")
    local step = firstResolvedEncounterInteraction(value)
    step.resolution.outcome = { kind = "freeItem" }
    lu.assertNil(protocol.decode(value))

    value = decodeFixture("test/fixtures/execution-plan/fg.execution.json")
    step = firstResolvedEncounterInteraction(value)
    local offer = step.resolution.offer
    step.resolution = { kind = "nemesisRandomEvent", outcome = { kind = "freeItem" }, offer = offer }
    lu.assertNil(protocol.decode(value))

    value = decodeFixture("test/fixtures/execution-plan/fg.execution.json")
    step = firstResolvedEncounterInteraction(value)
    step.resolution = { kind = "nemesisRandomEvent", outcome = {
        kind = "goldTrade", response = "accept", traitKey = "ApolloWeaponBoon",
    } }
    lu.assertNil(protocol.decode(value))

    value = decodeFixture("test/fixtures/execution-plan/fg.execution.json")
    step = firstResolvedEncounterInteraction(value)
    step.resolution = { kind = "nemesisRandomEvent", outcome = {
        kind = "damageContest", result = "success", response = "accept",
    } }
    lu.assertNil(protocol.decode(value))
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
    lu.assertFalse(postboss.contents.stygianWell.interacted)
    lu.assertNil(postboss.contents.stygianWell.offers)
    lu.assertFalse(postboss.contents.purgingPool.interacted)
    lu.assertNil(postboss.contents.purgingPool.traits)
end

function TestProtocol.testFeatureInteractionClosesRuntimeRandomAndAuthoredInventory()
    local value = fixtures.decode()
    local postboss
    for _, room in ipairs(value.rooms) do
        if room.gameName == "F_PostBoss01" then postboss = room; break end
    end
    lu.assertNotNil(postboss)
    postboss.contents.stygianWell.interacted = true
    lu.assertNil(protocol.decode(value))

    value = fixtures.decode()
    for _, room in ipairs(value.rooms) do
        if room.gameName == "F_PostBoss01" then postboss = room; break end
    end
    postboss.contents.purgingPool.traits = setmetatable({}, { __json_array = true })
    lu.assertNil(protocol.decode(value))
end

local function mutationRejected(mutate)
    local value = fixtures.decode()
    mutate(value)
    local plan = protocol.decode(value)
    lu.assertNil(plan)
end

function TestProtocol.testClosedShapeRejectsUnsupportedAndCoercedValues()
    mutationRejected(function(value) value.extra = true end)
    mutationRejected(function(value) value.startingKeepsake = nil end)
    mutationRejected(function(value) value.startingKeepsake.keepsakeKey = "" end)
    mutationRejected(function(value)
        value.startingKeepsake.equipResults = object({
            experimentalHammer = object({ kind = "selected" }),
        })
    end)
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
    mutationRejected(function(value) value.rooms[1].trace[1].replace = nil end)
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

local function generatedArtificerAcquisition()
    local value = fixtures.decode()
    local room = value.rooms[1]
    local sourceOwner = room.trace[2].sourceOwner
    local occurrence = semanticAddress("occurrence", "Underworld", "F", room.id)
    local site = semanticAddress(
        "acquisitionSite",
        "Underworld",
        "F",
        occurrence,
        "artificerSource:" .. sourceOwner
    )
    local entry = semanticAddress(
        "acquisitionEntry",
        "Underworld",
        "F",
        site,
        "artificer:" .. sourceOwner .. ":self"
    )
    local step = object({
        kind = "acquireReward",
        owner = entry,
        sourceOwner = entry,
        reward = object({
            rewardType = "Boon",
            producerLifecycleKey = "RoomReward",
            source = "ZeusUpgrade",
        }),
        producerLifecycleKey = "RoomReward",
        roles = list({
            object({
                role = "source",
                disposition = "normal",
                producer = object({
                    kind = "artificerReplacement",
                    sourceOwner = sourceOwner,
                    sourceRole = "self",
                }),
                lifecyclePoint = "roomRewardPickup",
                kind = "consumable",
                gameName = "RoomRewardConsolationPrize",
                settlement = object({ site = site, entry = entry }),
            }),
        }),
    })
    table.insert(room.trace, 3, step)
    return value, step, site
end

function TestProtocol.testGeneratedAcquisitionUsesItsSourceActionAsOwner()
    local value, step, site = generatedArtificerAcquisition()
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.rooms[1].trace[3].owner, step.owner)
    lu.assertEquals(plan.rooms[1].trace[3].roles[1].role, "source")

    value, step = generatedArtificerAcquisition()
    step.owner = step.roles[1].producer.sourceOwner
    lu.assertNil(protocol.decode(value))

    value, step, site = generatedArtificerAcquisition()
    step.roles[1].settlement.entry = semanticAddress(
        "acquisitionEntry",
        "Underworld",
        "F",
        site,
        "different-generated-entry"
    )
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testMalformedRunStateMapsReturnDecodeErrorsInsteadOfAsserting()
    local value = fixtures.decode()
    value.rooms[1].trace[1].replace.traits.elements = { bad = "not-a-number" }
    local plan, errorMessage = protocol.decode(value)
    lu.assertNil(plan)
    lu.assertNotNil(errorMessage)
end

function TestProtocol.testRewardPrioritiesRetainDuplicateOrder()
    local value = fixtures.decode()
    value.rooms[1].trace[1].replace.rewardPriorities = setmetatable(
        { "Boon", "Boon" },
        { __json_array = true }
    )
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.rooms[1].trace[1].replace.rewardPriorities, { "Boon", "Boon" })
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

function TestProtocol.testWellGenerationKeyTypeErrorsAreReturnedWithoutThrowing()
    local function malformedGenerationKey(value)
        local candidate = decodeFixture("test/fixtures/execution-plan/fg-ixion-chaos.execution.json")
        local purchase
        for _, room in ipairs(candidate.rooms) do
            for _, step in ipairs(room.trace) do
                if step.kind == "stygianWellPurchase" then purchase = step; break end
            end
            if purchase then break end
        end
        lu.assertNotNil(purchase)
        purchase.generationKey = value
        local completed, plan, errorMessage = pcall(protocol.decode, candidate)
        lu.assertTrue(completed)
        lu.assertNil(plan)
        lu.assertNotNil(errorMessage)
    end

    malformedGenerationKey(2)
    malformedGenerationKey({ unexpected = true })
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
