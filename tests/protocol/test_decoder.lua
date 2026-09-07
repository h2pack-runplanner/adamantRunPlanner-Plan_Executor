-- luacheck: globals TestProtocol
local lu = require("luaunit")
local json = require("mods/protocol/json")
local protocol = require("mods.protocol.decoder")
local rewards = require("mods.protocol.rewards")
local conformance = require("mods.protocol.conformance")

TestProtocol = {}
local root = "fixtures/execution-plan/"

function TestProtocol.testConformanceResolverProjectsNamedFactsAndRejectsUnknownOrDuplicateKinds()
    local state = assert(json.decode([[{
        "retainedEffects": {
            "steadyGrowth": [{"traitKey":"Trait"}],
            "keepsakes": {"currentKey":"Keepsake"},
            "stygianWell": {"sparkUses":1}
        },
        "chaos": {"active":[]},
        "rewardPriorities": ["boon"],
        "hexProgress": {"investedPathPoints":2},
        "forfeit": "inactive"
        ,"traits": {"elements": {"Aether":0,"Earth":0,"Air":0,"Fire":0,"Water":0}}
    }]]))
    local expected, errorMessage = conformance.resolve(assert(json.decode([[{
        "facts": [
            {"kind":"steadyGrowth"},
            {"kind":"chaos"},
            {"kind":"keepsakeEffects"},
            {"kind":"rewardPriorities"},
            {"kind":"pathOfStars"},
            {"kind":"forfeit"},
            {"kind":"stygianWell"},
            {"kind":"elementCounts"}
        ]
    }]])), state, "roomExitConformance")
    lu.assertNotNil(expected, errorMessage)
    lu.assertEquals(expected.steadyGrowth, state.retainedEffects.steadyGrowth)
    lu.assertEquals(expected.chaos, state.chaos)
    lu.assertEquals(expected.keepsakeEffects, state.retainedEffects.keepsakes)
    lu.assertEquals(expected.rewardPriorities, state.rewardPriorities)
    lu.assertEquals(expected.pathOfStars, state.hexProgress)
    lu.assertEquals(expected.forfeit, state.forfeit)
    lu.assertEquals(expected.stygianWell, state.retainedEffects.stygianWell)
    lu.assertEquals(expected.elementCounts, state.traits.elements)

    local unknown = conformance.resolve(assert(json.decode([[{
        "facts": [{"kind":"unknown"}]
    }]])), state, "roomExitConformance")
    lu.assertNil(unknown)
    local duplicate = conformance.resolve(assert(json.decode([[{
        "facts": [{"kind":"chaos"},{"kind":"chaos"}]
    }]])), state, "roomExitConformance")
    lu.assertNil(duplicate)
end

function TestProtocol.testSpellOfferWireRequiresCompleteTreeAndThreeOptions()
    local offer = assert(json.decode('{"kind":"traits","giver":"SpellDrop","selected":"option1","options":[{"key":"one"},{"key":"two"},{"key":"three"}],"hexTree":{"layoutKey":"Lung","rareTalentKeys":["rare"],"epicTalentKeys":["epic"]}}'))
    lu.assertNotNil(rewards.traitOffer(offer, "spell"))
    local missing = assert(json.decode('{"kind":"traits","giver":"SpellDrop","selected":"option1","options":[{"key":"one"},{"key":"two"},{"key":"three"}]}'))
    lu.assertNil(rewards.traitOffer(missing, "spell"))
    local short = assert(json.decode('{"kind":"traits","giver":"SpellDrop","selected":"option1","options":[{"key":"one"}],"hexTree":{"layoutKey":"Lung","rareTalentKeys":["rare"],"epicTalentKeys":["epic"]}}'))
    lu.assertNil(rewards.traitOffer(short, "spell"))
    local foreign = assert(json.decode('{"kind":"traits","giver":"Zeus","selected":"option1","options":[{"key":"one"},{"key":"two"},{"key":"three"}],"hexTree":{"layoutKey":"Lung","rareTalentKeys":["rare"],"epicTalentKeys":["epic"]}}'))
    lu.assertNil(rewards.traitOffer(foreign, "spell"))
end

local function decode(name)
    local file = assert(io.open(root .. name .. ".execution.json", "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    return value
end

local function decodeWithIndependentJsonModule(name)
    local independentJson = assert(loadfile("src/mods/protocol/json.lua"))()
    local file = assert(io.open(root .. name .. ".execution.json", "rb"))
    local value = assert(independentJson.decode(file:read("*a")))
    file:close()
    lu.assertFalse(rawequal(independentJson.null, json.null))
    return value
end

local function refreshFingerprint(plan)
    plan.planFingerprint = protocol.fingerprint({
        format = plan.format, protocolVersion = plan.protocolVersion,
        catalogVersion = plan.catalogVersion, projectId = plan.projectId,
        routeKey = plan.routeKey, startingLoadout = plan.startingLoadout, startingKeepsake = plan.startingKeepsake,
        extent = plan.extent, selectedOccurrenceIds = plan.selectedOccurrenceIds, resources = plan.resources,
        occurrences = plan.occurrences,
    })
end

local function automatic(plan)
    for _, occurrence in ipairs(plan.occurrences) do
        for _, transaction in ipairs(occurrence.timeline.transactions) do
            if transaction.kind == "automatic" then return transaction end
        end
    end
end

local function window(kind)
    if kind == "encounterEnd" or kind == "bossDefeated" then
        return { kind = kind, phaseKey = "phase" }
    end
    if kind == "postOutgoing" then return { kind = kind } end
    return { kind = "standard", phase = kind or "beforeCombat" }
end

local function reward()
    return { rewardType = "boon", producerLifecycleKey = "pickup" }
end

local function role()
    return {
        role = "self",
        disposition = "normal",
        lifecyclePoint = "pickup",
        kind = "trait",
        gameName = "ZeusWeaponBoon",
    }
end

local function traitOffer()
    return {
        kind = "traits",
        giver = "Zeus",
        options = {
            { key = "one", baseRarity = "Common", rarity = "Rare" },
            { key = "two" },
            { key = "three" },
        },
        selected = "option1",
    }
end

local objectMeta = getmetatable(assert(json.decode("{}")))
local arrayMeta = getmetatable(assert(json.decode("[]")))
local arrayFields = {
    biomeKeys = true,
    selectedOccurrenceIds = true,
    occurrences = true,
    unmodeledEncounterKeys = true,
    encounterPhases = true,
    requiredObjects = true,
    transactions = true,
    dependencies = true,
    obligations = true,
    roles = true,
    options = true,
    arcana = true,
    arcanaKeys = true,
}

local function tagged(value, field, forceArray)
    if type(value) ~= "table" or json.isNull(value) then return value end
    if getmetatable(value) == nil then
        local isArray = forceArray or arrayFields[field] or #value > 0
        setmetatable(value, isArray and arrayMeta or objectMeta)
    end
    for key, item in pairs(value) do tagged(item, key, false) end
    return value
end

local function minimalPlan(transactions)
    local obligations = {}
    for _, transaction in ipairs(transactions) do
        obligations[#obligations + 1] = { owner = transaction.owner, checkpoint = "exitUsable" }
    end
    local plan = tagged({
        format = "run-planner-execution",
        protocolVersion = 29,
        catalogVersion = "0.55.0-anvil-of-fates",
        projectId = "test-project",
        planFingerprint = "00000000",
        routeKey = "Underworld",
        startingLoadout = {
            weaponKey = "WeaponStaffSwing", aspectKey = "BaseStaffAspect", arcana = {},
            fear = { configuredRanks = {}, effectiveRanks = {} },
        },
        startingKeepsake = { keepsakeKey = "None" },
        extent = { kind = "configuredPrefix", biomeKeys = { "F" }, terminalBiomeKey = "F" },
        selectedOccurrenceIds = { "opening" },
        resources = { occurrences = { {
            occurrenceId = "opening",
            pointDispositions = {
                Pickaxe = "native", Exorcism = "native", Shovel = "native", Fishing = "native",
            },
        } } },
        occurrences = {
            {
                id = "opening",
                owner = "opening-owner",
                biomeKey = "F",
                gameName = "F_Opening01",
                kind = "opening",
                overview = { encounterPhases = {}, requiredObjects = {} },
                timeline = { transactions = transactions, dependencies = {}, obligations = obligations },
                doors = { kind = "terminal", owner = "doors-owner" },
            },
        },
    })
    refreshFingerprint(plan)
    return plan
end

local function minimalShrinePlan()
    local plan = minimalPlan({})
    plan.occurrences[1].overview.hermesShrine = tagged({
        offers = {
            {
                generationKey = "initial:first", optionKey = "Heal", rewardType = "HealBigDrop",
                slotIndex = 1, purchase = { roomDelay = 2, rushed = true },
                deliverySourceKey = "hermesShrineDelivery:source:first",
            },
            {
                generationKey = "initial:secondLeft", optionKey = "Health", rewardType = "MaxHealthDrop",
                slotIndex = 2,
            },
            {
                generationKey = "initial:secondRight", optionKey = "Mana", rewardType = "MaxManaDrop",
                slotIndex = 3,
            },
        },
        travelDealRefill = {
            sourceGenerationKey = "initial:first", slotIndex = 1,
            optionKey = "Armor", rewardType = "ArmorDrop",
            purchase = { roomDelay = 8, rushed = false },
            deliverySourceKey = "hermesShrineDelivery:source:refill",
        },
    })
    refreshFingerprint(plan)
    return plan
end

function TestProtocol.testHermesShrinePurchaseRequiresDeliverySourcePair()
    local mutations = {
        function(plan)
            plan.occurrences[1].overview.hermesShrine.offers[1].deliverySourceKey = nil
        end,
        function(plan)
            plan.occurrences[1].overview.hermesShrine.offers[1].purchase = nil
        end,
        function(plan)
            plan.occurrences[1].overview.hermesShrine.travelDealRefill.deliverySourceKey = nil
        end,
        function(plan)
            plan.occurrences[1].overview.hermesShrine.travelDealRefill.purchase = nil
        end,
    }
    for _, mutate in ipairs(mutations) do
        local plan = minimalShrinePlan()
        mutate(plan)
        refreshFingerprint(plan)
        lu.assertNil(protocol.decode(plan))
    end
end

function TestProtocol.testArtificerRoleCarriesSourceOwnedReplacement()
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "artificer", lifecyclePoint = "pickup",
            kind = "trait", gameName = "MetaCurrencyDrop",
            replacement = { reward = reward(), gameName = "RoomRewardConsolationPrize" },
        } },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].roles[1].replacement.gameName,
        "RoomRewardConsolationPrize")

    value.occurrences[1].timeline.transactions[1].roles[1].disposition = "normal"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testSeaStarResultIsAClosedNormalSourceField()
    local value = minimalPlan({ {
        kind = "acquisition", owner = "source", sourceOwner = "source", reward = reward(),
        producerLifecycleKey = "pickup", roles = { role() }, window = window(),
    } })
    local source = value.occurrences[1].timeline.transactions[1].roles[1]
    source.seaStarResult = { kind = "noProc" }
    tagged(source.seaStarResult, "seaStarResult", false)
    refreshFingerprint(value)
    lu.assertNotNil(protocol.decode(value))
    source.seaStarResult = { kind = "random" }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
    source.seaStarResult = { kind = "proc" }
    tagged(source.seaStarResult, "seaStarResult", false)
    source.disposition = "artificer"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
    source.disposition = "normal"
    source.producer = { kind = "seaStarDuplicate", sourceOwner = "source", sourceRole = "self" }
    tagged(source.producer, "producer", false)
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
    source.producer = nil
    local transaction = value.occurrences[1].timeline.transactions[1]
    transaction.kind = "shopPurchase"
    transaction.offerKey = "offer"
    transaction.rewardType = "boon"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testNaturalSelectionTargetsDecodeAsOneBoundedNestedResult()
    local offer = traitOffer()
    offer.options[1].naturalSelectionTargets = { "one", "two", "one" }
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup",
            kind = "trait", gameName = "ZeusUpgrade", traitOffer = offer,
        } },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].roles[1].traitOffer.options[1]
        .naturalSelectionTargets, { "one", "two", "one" })

    value.occurrences[1].timeline.transactions[1].roles[1].traitOffer.options[1]
        .naturalSelectionTargets = {}
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testTargetedAcquisitionTargetBelongsOnlyToItsSelectedOption()
    local offer = traitOffer()
    offer.options[1].targetTraitKey = "ApolloSprintBoon"
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))

    offer.options[1].targetTraitKey = 3
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].targetTraitKey = nil
    offer.options[2].targetTraitKey = "ApolloSprintBoon"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
end

function TestProtocol.testConcaveStoneDispositionDecodesOnlyOnItsSelectedSourceOption()
    local offer = traitOffer()
    offer.options[1].concaveStoneResult = { kind = "proc", optionKey = "option2" }
    offer.options[2].targetTraitKey = "ApolloSprintBoon"
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup",
            kind = "trait", gameName = "ZeusUpgrade", traitOffer = offer,
        } },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].roles[1].traitOffer.options[1]
        .concaveStoneResult.optionKey, "option2")
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].roles[1].traitOffer.options[2]
        .targetTraitKey, "ApolloSprintBoon")

    offer.options[1].concaveStoneResult.optionKey = "option1"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    offer.options[1].concaveStoneResult = nil
    offer.options[2].targetTraitKey = nil
    offer.options[2].concaveStoneResult = { kind = "noProc" }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testCirceResolutionIsClosedAndBelongsOnlyToTheSelectedCirceOption()
    local offer = traitOffer()
    offer.giver = "Circe"
    offer.options[1].circeResolution = {
        kind = "promoteArcana", arcanaKeys = { "CastCount", "CardDraw" },
    }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))

    offer.options[1].circeResolution.arcanaKeys = { "CastCount", "CardDraw", "ChanneledCast" }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution.arcanaKeys = { "CastCount", "CastCount" }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution = { kind = "disableFear", vowKey = "EnemyDamageShrineUpgrade" }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution.extra = true
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].circeResolution = nil
    offer.options[2].circeResolution = { kind = "activateArcana", arcanaKeys = { "CardDraw" } }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[2].circeResolution = nil
    offer.options[1].circeResolution = { kind = "activateArcana", arcanaKeys = { "CardDraw" } }
    offer.giver = "Zeus"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
end

function TestProtocol.testIcarusHammerTargetBelongsOnlyToSelectedLatestModel()
    local offer = traitOffer()
    offer.giver = "Icarus"
    offer.options[1].key = "UpgradeHammerBoon"
    offer.options[1].icarusHammerTarget = "StaffDoubleAttackTrait"
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))

    offer.options[1].icarusHammerTarget = 3
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].icarusHammerTarget = "StaffDoubleAttackTrait"
    offer.options[1].key = "IcarusUpgradeBoon"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].key = "UpgradeHammerBoon"
    offer.giver = "Circe"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.giver = "Icarus"
    offer.options[1].icarusHammerTarget = nil
    offer.options[2].icarusHammerTarget = "StaffDoubleAttackTrait"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
end

function TestProtocol.testEchoVolatileResultsBelongOnlyToTheirSelectedOuterRows()
    local offer = traitOffer()
    offer.giver = "Echo"
    offer.options[1].key = "EchoLastRunBoon"
    offer.options[1].echoLastRunBoon = {
        options = {
            {
                giver = "Hera", key = "HeraWeaponBoon", rarity = "Rare",
                lootHistorySource = "HeraUpgrade",
            },
            { giver = "Zeus", key = "ZeusSpecialBoon", rarity = "Epic" },
        },
        selected = "option2",
    }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].echoLastRunBoon.options[2].allTogetherResult = {
        earth = "Earth", fire = "Fire", air = "Air", water = "Water",
    }
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].echoLastRunBoon.options[2].allTogetherResult = nil
    offer.options[1].echoLastRunBoon.options[1].allTogetherResult = {
        earth = "Earth", fire = "Fire", air = "Air", water = "Water",
    }
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].echoLastRunBoon.options[1].allTogetherResult = nil
    offer.options[1].echoLastRunBoon.options[1].lootHistorySource = 7
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.options[1].echoLastRunBoon.options[1].lootHistorySource = "HeraUpgrade"
    offer.selected = "option2"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))

    offer.selected = "option1"
    offer.options[1].echoLastRunBoon = nil
    offer.options[1].key = "EchoDoubleLevelBoon"
    offer.options[1].echoPomTarget = "ZeusWeaponBoon"
    lu.assertNotNil(rewards.traitOffer(tagged(offer), "offer"))
    offer.giver = "Icarus"
    lu.assertNil(rewards.traitOffer(tagged(offer), "offer"))
end

function TestProtocol.testTimePieceDispositionIsNotPublished()
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "timePiece", lifecyclePoint = "pickup",
            kind = "trait", gameName = "MetaCurrencyDrop",
        } },
        window = window(),
    } })
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testPoolSalesAreNotExecutionTransactions()
    local value = minimalPlan({ {
        kind = "poolSale",
        owner = "sale",
        window = window("postOutgoing"),
        slotKey = "left",
        traitKey = "trait",
    } })
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testEveryPublishedTransactionHasExactlyOneObligation()
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "source",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { role() },
        window = window(),
    } })
    lu.assertNotNil(protocol.decode(value))

    value.occurrences[1].timeline.obligations = {}
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = minimalPlan(value.occurrences[1].timeline.transactions)
    value.occurrences[1].timeline.obligations[2] = {
        owner = "source", checkpoint = "exitUsable",
    }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testLegacyProtocolVectorsAreRejected()
    for _, name in ipairs({ "f-opening", "fg", "fg-ixion-chaos", "fg-anomaly", "automatic-boss" }) do
        local plan = decode(name)
        plan.protocolVersion = 24
        plan.resources = nil
        refreshFingerprint(plan)
        lu.assertNil(protocol.decode(plan))
    end
end

function TestProtocol.testProtocolRejectsLegacyVectorsFromAnIndependentDecoderModule()
    local plan = decodeWithIndependentJsonModule("f-opening")
    plan.protocolVersion = 24
    plan.resources = nil
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testCurrentProtocolRequiresCompleteOrderedRouteResourcePolicyAndRejectsLegacyOverview()
    local plan = minimalPlan({})
    lu.assertNotNil(protocol.decode(plan))

    plan.resources = nil
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.occurrences[1].overview.resources = {}
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.resources.occurrences[1].pointDispositions.Pickaxe = "selected"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.resources.occurrences[1].postExitElementCounts = {}
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = minimalPlan({})
    plan.occurrences[1].overview.unmodeledEncounterKeys = { "Empty" }
    plan.occurrences[1].overview.encounterPhases = { { slotKey = "Encounter", encounterKey = "Empty", kind = "nonCombat" } }
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = decodeWithIndependentJsonModule("f-opening")
    plan.occurrences[1].diagnostics.roomEntered.replace.traits.elements.Water = nil
    lu.assertNil(protocol.decode(plan))

    plan = decodeWithIndependentJsonModule("f-opening")
    plan.occurrences[1].diagnostics.roomEntered.replace.traits.elements.Unknown = 0
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testFieldsFixturePublishesBoundedDistinctPlacementFacts()
    local plan = decode("underworld-fgh")
    local fieldsOccurrence
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    lu.assertNotNil(fieldsOccurrence)
    lu.assertTrue(#fieldsOccurrence.overview.fields.cagePoints >= 2)
    lu.assertTrue(#fieldsOccurrence.overview.fields.cagePoints <= 3)
    lu.assertNotNil(protocol.decode(plan))

    plan = decode("underworld-fgh")
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.kind == "FieldsEncounter" then
            occurrence.overview.fields = nil
            break
        end
    end
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = decode("underworld-fgh")
    fieldsOccurrence = nil
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    table.remove(fieldsOccurrence.overview.fields.cagePoints)
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = decode("underworld-fgh")
    fieldsOccurrence = nil
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    fieldsOccurrence.overview.fields.optionalRewards[1].pointId =
        fieldsOccurrence.overview.fields.cagePoints[1].pointId
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testFieldsFixtureRequiresCanonicalOrderedCageSlots()
    local plan = decode("underworld-fgh")
    local fieldsOccurrence
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    lu.assertNotNil(fieldsOccurrence)
    local fields = fieldsOccurrence.overview.fields
    fields.cagePoints[1].slotKey, fields.cagePoints[2].slotKey =
        fields.cagePoints[2].slotKey, fields.cagePoints[1].slotKey
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))

    plan = decode("underworld-fgh")
    fieldsOccurrence = nil
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.overview.fields ~= nil then
            fieldsOccurrence = occurrence
            break
        end
    end
    lu.assertNotNil(fieldsOccurrence)
    fieldsOccurrence.overview.fields.cagePoints[1].slotKey = "cage4"
    refreshFingerprint(plan)
    lu.assertNil(protocol.decode(plan))
end

function TestProtocol.testDoorCageRewardsMatchTheirReferencedFieldsTarget()
    local function fieldsTarget(plan)
        local fieldsOccurrence
        for _, occurrence in ipairs(plan.occurrences) do
            if occurrence.kind == "FieldsEncounter" then
                fieldsOccurrence = occurrence
                break
            end
        end
        lu.assertNotNil(fieldsOccurrence)
        for _, source in ipairs(plan.occurrences) do
            if source.doors.kind == "batch" then
                for _, target in ipairs(source.doors.targets) do
                    if target.room.id == fieldsOccurrence.id then return target end
                end
            end
        end
        error("fixture lacks a door target for the Fields occurrence")
    end

    local missing = decode("underworld-fgh")
    fieldsTarget(missing).cageRewards = nil
    refreshFingerprint(missing)
    lu.assertNil(protocol.decode(missing))

    local short = decode("underworld-fgh")
    local shortTarget = fieldsTarget(short)
    table.remove(shortTarget.cageRewards)
    refreshFingerprint(short)
    lu.assertNil(protocol.decode(short))

    local illegal = decode("underworld-fgh")
    local occurrencesById = {}
    for _, occurrence in ipairs(illegal.occurrences) do occurrencesById[occurrence.id] = occurrence end
    local nonFieldsTarget
    for _, source in ipairs(illegal.occurrences) do
        if source.doors.kind == "batch" then
            for _, target in ipairs(source.doors.targets) do
                if occurrencesById[target.room.id].kind ~= "FieldsEncounter" then
                    nonFieldsTarget = target
                    break
                end
            end
        end
        if nonFieldsTarget ~= nil then break end
    end
    lu.assertNotNil(nonFieldsTarget)
    nonFieldsTarget.cageRewards = {}
    refreshFingerprint(illegal)
    lu.assertNil(protocol.decode(illegal))
end

function TestProtocol.testOpaqueOwnerReferencesAreLocalAndLaterContactsAreRejected()
    local value = decode("f-opening")
    local room = value.occurrences[1]
    room.timeline.dependencies[1] = { owner = "missing", afterOwner = room.timeline.transactions[1].owner }
    lu.assertNil(protocol.decode(value))
    value = decode("f-opening")
    value.occurrences[1].roomExitConformance = { facts = { { kind = "echoShopDuplicate" } } }
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testNestedSemanticOwnersUseTheOwnerSpecificBound()
    local owner = string.rep("o", 420)
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = owner,
        sourceOwner = owner,
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { role() },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(plan.occurrences[1].timeline.transactions[1].owner, owner)

    value.occurrences[1].timeline.transactions[1].owner = string.rep("o", 2049)
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testForcedShortageTraitOfferSelectsAnExistingOption()
    local offer = traitOffer()
    offer.options = { { key = "one" } }
    offer.selected = "option1"
    local value = minimalPlan({ {
        kind = "acquisition",
        owner = "acquisition",
        sourceOwner = "source",
        reward = reward(),
        producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup",
            kind = "trait", gameName = "AllElementalBoon", traitOffer = offer,
        } },
        window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)

    offer.selected = "option2"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testAllTogetherRequiresFourExplicitDirectGrantOutcomes()
    local offer = traitOffer()
    offer.options[1].allTogetherResult = {
        earth = "ElementalDamageBoon", fire = "ElementalBaseDamageBoon",
        air = "ElementalDamageFloorBoon", water = json.null,
    }
    local value = minimalPlan({ {
        kind = "acquisition", owner = "acquisition", sourceOwner = "source",
        reward = reward(), producerLifecycleKey = "pickup",
        roles = { {
            role = "self", disposition = "normal", lifecyclePoint = "pickup",
            kind = "trait", gameName = "HeraUpgrade", traitOffer = offer,
        } }, window = window(),
    } })
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertTrue(json.isNull(plan.occurrences[1].timeline.transactions[1].roles[1]
        .traitOffer.options[1].allTogetherResult.water))

    offer.options[1].allTogetherResult.water = nil
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testRecomputedFingerprintCannotHideClosedUnionViolations()
    local value = decode("automatic-boss")
    local transaction = automatic(value)
    transaction.source = "not-valid-on-judgment"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = decode("f-opening")
    value.occurrences[1].overview.unknown = true
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = decode("f-opening")
    value.occurrences[1].overview.effectNeutralRequiredReward = false
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = decode("f-opening")
    value.startingKeepsake.equipResults = { experimentalHammer = { kind = "selected" } }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = decode("f-opening")
    value.occurrences[1].diagnostics.roomEntered.replace.counters.routeEncounterDepth = "one"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testEveryTimelineTransactionUnionDecodes()
    local transactions = {
        {
            kind = "acquisition",
            owner = "acquisition",
            sourceOwner = "source",
            reward = reward(),
            producerLifecycleKey = "pickup",
            roles = { role() },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "trait-offer",
            phaseKey = "phase",
            resolution = { kind = "traitOffer", offer = traitOffer() },
            window = window("encounterEnd"),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-free-item",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = {
                    kind = "freeItem",
                    itemGameName = "EmptyMaxHealthDrop",
                },
            },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-gold",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "goldTrade", response = "accept" },
            },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-damage",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "damageTrade", response = "decline" },
            },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-trait",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "traitTrade", traitKey = "trait", response = "accept" },
            },
            window = window(),
        },
        {
            kind = "encounterInteraction",
            owner = "nemesis-contest",
            phaseKey = "phase",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "damageContest", result = "success" },
            },
            window = window(),
        },
        {
            kind = "automatic",
            owner = "growth",
            effect = "steadyGrowth",
            phaseKey = "phase",
            source = "source",
            target = "target",
            window = window("encounterEnd"),
        },
        {
            kind = "automatic",
            owner = "embryo",
            effect = "transcendentEmbryo",
            phaseKey = "phase",
            source = "source",
            target = "target",
            rarity = "Rare",
            blessingValues = { damageBonus = 0.7 },
            window = window("encounterEnd"),
        },
        {
            kind = "automatic",
            owner = "judgment",
            effect = "judgment",
            phaseKey = "phase",
            arcanaKeys = { "one", "two" },
            rarity = "Rare",
            window = window("bossDefeated"),
        },
        {
            kind = "automatic",
            owner = "figurine",
            effect = "crystalFigurine",
            phaseKey = "phase",
            arcanaKeys = { "three" },
            rarity = "Epic",
            window = window("bossDefeated"),
        },
        {
            kind = "shopPurchase",
            owner = "shop",
            window = window("postOutgoing"),
            offerKey = "offer",
            rewardType = "boon",
            sourceOwner = "source",
            reward = reward(),
            producerLifecycleKey = "purchase",
            roles = { role() },
        },
        {
            kind = "wellPurchase",
            owner = "well",
            window = window("postOutgoing"),
            offerKey = "item",
            generationKey = "initial:healing",
            effect = "lastStand",
            extendedDirectPurchase = false,
        },
        {
            kind = "wellRefill",
            owner = "refill",
            window = window("postOutgoing"),
            generationKey = "travelDealRefill",
            offerKey = "item",
            effect = "neutral",
        },
        {
            kind = "keepsakeChange",
            owner = "rack",
            window = window("postOutgoing"),
            keepsakeKey = "hammer",
            equipResults = {
                experimentalHammer = { kind = "selected", traitKey = "hammerTrait" },
            },
        },
        {
            kind = "keepsakeReplay",
            owner = "echo-replay",
            window = window("beforeCombat"),
            keepsakeKey = "hammer",
            equipResults = {
                experimentalHammer = { kind = "exhausted" },
            },
        },
        {
            kind = "fountainUse",
            owner = "fountain",
            window = window("postOutgoing"),
            interactionKey = "fountain",
            aromaticPhialTarget = "trait",
        },
    }
    local plan, errorMessage = protocol.decode(minimalPlan(transactions))
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(#plan.occurrences[1].timeline.transactions, #transactions)
end

function TestProtocol.testFountainUseRequiresItsPublishedInteractionContact()
    local value = minimalPlan({ {
        kind = "fountainUse",
        owner = "fountain",
        window = window("postOutgoing"),
        interactionKey = "fountain",
    } })
    lu.assertNotNil(protocol.decode(value))

    value.occurrences[1].timeline.transactions[1].interactionKey = nil
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value.occurrences[1].timeline.transactions[1].interactionKey = "other"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testAnvilResultExistsOnlyOnThePurchasedAnvilTransaction()
    local transaction = {
        kind = "shopPurchase",
        owner = "anvil",
        window = window("postOutgoing"),
        offerKey = "Anvil",
        rewardType = "ChaosWeaponUpgrade",
        sourceOwner = "source",
        reward = { rewardType = "ChaosWeaponUpgrade", producerLifecycleKey = "Q_WorldShop" },
        producerLifecycleKey = "Q_WorldShop",
        roles = {},
        anvilResult = {
            kind = "anvilOfFates",
            removedTraitKey = json.null,
            addedTraitKeys = { "HammerA", "HammerB" },
        },
    }
    lu.assertNotNil(protocol.decode(minimalPlan({ transaction })))

    transaction.anvilResult = nil
    lu.assertNil(protocol.decode(minimalPlan({ transaction })))

    transaction.rewardType = "MaxHealthDrop"
    transaction.anvilResult = {
        kind = "anvilOfFates",
        removedTraitKey = json.null,
        addedTraitKeys = { "HammerA", "HammerB" },
    }
    lu.assertNil(protocol.decode(minimalPlan({ transaction })))
end

function TestProtocol.testKeepsakeReplayIsAClosedBeforeCombatEquipTransaction()
    local value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("beforeCombat"),
        keepsakeKey = "hammer",
        equipResults = { experimentalHammer = { kind = "exhausted" } },
    } })
    lu.assertNotNil(protocol.decode(value))

    value.occurrences[1].timeline.transactions[1].equipResults = nil
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("beforeCombat"),
        keepsakeKey = "hammer",
        equipResults = { jeweledPom = { traitKey = "PomTrait" } },
    } })
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("beforeCombat"),
        keepsakeKey = "hammer",
        equipResults = {
            experimentalHammer = { kind = "exhausted" },
            transcendentEmbryo = { blessingKey = "Blessing", blessingValues = {} },
        },
    } })
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("postOutgoing"),
        keepsakeKey = "hammer",
        equipResults = { experimentalHammer = { kind = "exhausted" } },
    } })
    lu.assertNil(protocol.decode(value))

    value = minimalPlan({ {
        kind = "keepsakeReplay",
        owner = "echo-replay",
        window = window("beforeCombat"),
        keepsakeKey = "hammer",
        equipResults = { experimentalHammer = { kind = "exhausted" } },
        extra = true,
    } })
    lu.assertNil(protocol.decode(value))
end

function TestProtocol.testEncounterPhaseAcceptsOnlyTheOptionalFigLeafDecision()
    local value = minimalPlan({})
    value.occurrences[1].overview.encounterPhases[1] = tagged(
        { slotKey = "phase", encounterKey = "Encounter", kind = "combat", figLeafSkip = false },
        "phaseRow"
    )
    refreshFingerprint(value)
    local plan, errorMessage = protocol.decode(value)
    lu.assertNotNil(plan, errorMessage)
    lu.assertFalse(plan.occurrences[1].overview.encounterPhases[1].figLeafSkip)

    local invalidValue = minimalPlan({})
    invalidValue.occurrences[1].overview.encounterPhases[1] = tagged(
        { slotKey = "phase", encounterKey = "Encounter", kind = "combat", figLeafSkip = "false" },
        "phaseRow"
    )
    refreshFingerprint(invalidValue)
    local invalid, invalidError = protocol.decode(invalidValue)
    lu.assertNil(invalid)
    lu.assertStrContains(invalidError, "encounterPhases[1].figLeafSkip")
end
