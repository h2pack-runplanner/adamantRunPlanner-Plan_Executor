-- luacheck: globals TestProtocolV11
local lu = require("luaunit")
local json = require("mods/json")
local protocol = require("mods/protocol")

TestProtocolV11 = {}
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

local function fallback(contact)
    return {
        preferredKey = "preferred",
        fallbackKey = "fallback",
        availabilityContact = contact,
    }
end

local function traitOffer()
    return {
        kind = "traits",
        giver = "Zeus",
        options = {
            { key = "one" },
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
    runtimeFallbacks = true,
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
    local plan = tagged({
        format = "run-planner-execution",
        protocolVersion = 11,
        catalogVersion = "0.54.0-required-boss-rewards",
        projectId = "test-project",
        planFingerprint = "00000000",
        routeKey = "Underworld",
        startingLoadout = { weaponKey = "WeaponStaffSwing", aspectKey = "BaseStaffAspect", arcana = {}, fear = { configuredRanks = {}, effectiveRanks = {} } },
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
                timeline = { transactions = transactions, dependencies = {}, obligations = {} },
                doors = { kind = "terminal", owner = "doors-owner" },
            },
        },
    })
    refreshFingerprint(plan)
    return plan
end

function TestProtocolV11.testAllGateA2VectorsDecodeAndExpandDiagnostics()
    for _, name in ipairs({ "f-opening", "fg", "fg-ixion-chaos", "fg-anomaly", "automatic-boss" }) do
        local plan, errorMessage = protocol.decode(decode(name))
        lu.assertNotNil(plan, errorMessage)
        lu.assertEquals(plan.protocolVersion, 11)
        lu.assertNotNil(plan.occurrences[1].diagnostics.roomEntered)
    end
end

function TestProtocolV11.testProtocolAcceptsTaggedNullsFromAnIndependentDecoderModule()
    local plan, errorMessage = protocol.decode(decodeWithIndependentJsonModule("f-opening"))
    lu.assertNotNil(plan, errorMessage)
end

function TestProtocolV11.testOpaqueOwnerReferencesAreLocalAndLaterContactsAreRejected()
    local value = decode("f-opening")
    local room = value.occurrences[1]
    room.timeline.dependencies[1] = { owner = "missing", afterOwner = room.timeline.transactions[1].owner }
    lu.assertNil(protocol.decode(value))
    value = decode("f-opening")
    value.occurrences[1].roomExitConformance = { facts = { { kind = "echoShopDuplicate" } } }
    lu.assertNil(protocol.decode(value))
end

function TestProtocolV11.testNestedSemanticOwnersUseTheOwnerSpecificBound()
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

function TestProtocolV11.testForcedShortageTraitOfferSelectsAnExistingOption()
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

function TestProtocolV11.testRecomputedFingerprintCannotHideClosedUnionViolations()
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

function TestProtocolV11.testEveryTimelineTransactionUnionDecodes()
    local transactions = {
        {
            kind = "acquisition",
            owner = "acquisition",
            sourceOwner = "source",
            reward = reward(),
            producerLifecycleKey = "pickup",
            roles = { role() },
            window = window(),
            runtimeFallbacks = { fallback("traitEligibility") },
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
                    runtimeFallbacks = { fallback("npcConsumableSelection") },
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
            runtimeFallbacks = { fallback("storePurchase") },
        },
        {
            kind = "wellPurchase",
            owner = "well",
            window = window("postOutgoing"),
            offerKey = "item",
            generationKey = "initial:healing",
            effect = "lastStand",
            extendedDirectPurchase = false,
            runtimeFallbacks = { fallback("storeInventoryGeneration") },
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
            aromaticPhialTarget = "trait",
        },
    }
    local plan, errorMessage = protocol.decode(minimalPlan(transactions))
    lu.assertNotNil(plan, errorMessage)
    lu.assertEquals(#plan.occurrences[1].timeline.transactions, #transactions)
end
