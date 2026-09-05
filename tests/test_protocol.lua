-- luacheck: globals TestProtocol
local lu = require("luaunit")
local json = require("mods/json")
local protocol = require("mods/protocol")

TestProtocol = {}
local root = "test/fixtures/execution-plan/"

local function decode(name)
    local file = assert(io.open(root .. name .. ".execution.json", "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    return value
end

local function decodeWithIndependentJsonModule(name)
    local independentJson = assert(loadfile("src/mods/json.lua"))()
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
        extent = plan.extent, selectedOccurrenceIds = plan.selectedOccurrenceIds,
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
        protocolVersion = 17,
        catalogVersion = "0.54.0-required-boss-rewards",
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

function TestProtocol.testConcaveStoneDispositionDecodesOnlyOnItsSelectedSourceOption()
    local offer = traitOffer()
    offer.options[1].concaveStoneResult = { kind = "proc", optionKey = "option2" }
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

    offer.options[1].concaveStoneResult.optionKey = "option1"
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))

    offer.options[1].concaveStoneResult = nil
    offer.options[2].concaveStoneResult = { kind = "noProc" }
    refreshFingerprint(value)
    lu.assertNil(protocol.decode(value))
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

function TestProtocol.testAllGateA2VectorsDecodeAndExpandDiagnostics()
    for _, name in ipairs({ "f-opening", "fg", "fg-ixion-chaos", "fg-anomaly", "automatic-boss" }) do
        local plan, errorMessage = protocol.decode(decode(name))
        lu.assertNotNil(plan, errorMessage)
        lu.assertEquals(plan.protocolVersion, 17)
        lu.assertNotNil(plan.occurrences[1].diagnostics.roomEntered)
    end
end

function TestProtocol.testProtocolAcceptsTaggedNullsFromAnIndependentDecoderModule()
    local plan, errorMessage = protocol.decode(decodeWithIndependentJsonModule("f-opening"))
    lu.assertNotNil(plan, errorMessage)
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
            kind = "poolSale",
            owner = "sale",
            window = window("postOutgoing"),
            slotKey = "left",
            traitKey = "trait",
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
