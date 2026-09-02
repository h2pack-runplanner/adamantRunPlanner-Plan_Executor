-- luacheck: globals TestNativeAdapters
local lu = require("luaunit")
local adapters = require("mods/native_timeline_adapters")
local readers = require("mods/native_conformance")

TestNativeAdapters = {}

local contacts = {
    "traitEligibility", "storeInventoryGeneration", "storePurchase", "npcConsumableSelection",
}

local function occurrence(contact)
    return {
        overview = { shop = { offers = {} }, stygianWell = { offers = {} } },
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
    }
end

function TestNativeAdapters.testEveryClosedFallbackContactBindsOnePublishedOwner()
    for _, contact in ipairs(contacts) do
        local index = assert(adapters.index(occurrence(contact)))
        local relation = {
            availabilityContact = contact, preferredKey = "preferred", fallbackKey = "fallback",
        }
        local owner = adapters.offer(index, "offer")
        local key, row = adapters.resolveFallback(index, owner, contact, relation,
            function(candidate) return candidate == "preferred" end, {})
        lu.assertEquals(key, "preferred")
        lu.assertEquals(row.node.owner, "owner")

        index = assert(adapters.index(occurrence(contact)))
        owner = adapters.offer(index, "offer")
        key, row = adapters.resolveFallback(index, owner, contact, relation,
            function(candidate) return candidate == "fallback" end, {})
        lu.assertEquals(key, "fallback")
        lu.assertEquals(row.realizedKey, "fallback")

        index = assert(adapters.index(occurrence(contact)))
        owner = adapters.offer(index, "offer")
        lu.assertNil(adapters.resolveFallback(index, owner, contact, relation,
            function() return false end, {}))
    end
end

function TestNativeAdapters.testIndexesRejectAmbiguousPublishedKeys()
    local item = occurrence("traitEligibility")
    item.transactionsByOwner.other = {
        owner = "other", kind = "acquisition", offerKey = "offer",
        window = { kind = "standard", phase = "beforeCombat" },
    }
    local index, errorValue = adapters.index(item)
    lu.assertNil(index)
    lu.assertEquals(errorValue.checkpoint, "timeline-binding")
end

function TestNativeAdapters.testSameFallbackRelationCanBelongToDistinctOffers()
    local item = occurrence("traitEligibility")
    item.transactionsByOwner.other = {
        owner = "other", kind = "acquisition", offerKey = "other-offer",
        window = { kind = "standard", phase = "beforeCombat" },
        runtimeFallbacks = item.transactionsByOwner.owner.runtimeFallbacks,
    }
    local index = assert(adapters.index(item))
    local relation = item.transactionsByOwner.owner.runtimeFallbacks[1]
    local first = adapters.offer(index, "offer")
    local second = adapters.offer(index, "other-offer")
    local _, firstRow = adapters.resolveFallback(index, first, "traitEligibility", relation,
        function(candidate) return candidate == "preferred" end, {})
    local _, secondRow = adapters.resolveFallback(index, second, "traitEligibility", relation,
        function(candidate) return candidate == "fallback" end, {})
    lu.assertEquals(firstRow.node.owner, "owner")
    lu.assertEquals(secondRow.node.owner, "other")
end

function TestNativeAdapters.testOutcomeVerifiersRequirePublishedFields()
    local index = assert(adapters.index(occurrence("traitEligibility")))
    local row = adapters.offer(index, "offer", {})
    row.node.kind, row.node.generationKey, row.node.twistResultKey = "wellPurchase", "initial:left", "Twist"
    lu.assertTrue(adapters.verifyWell(row, "initial:left", "offer", "Twist"))
    row.realizedKey = "fallback"
    lu.assertTrue(adapters.verifyWell(row, "initial:left", "fallback", "Twist"))
    lu.assertEquals(adapters.effectiveOfferKey(row), "fallback")
    lu.assertFalse(adapters.verifyWell(row, "initial:right", "offer", "Twist"))
    row.node.kind, row.node.slotKey, row.node.traitKey = "poolSale", "slot", "trait"
    lu.assertTrue(adapters.verifyPool(row, "slot", "trait"))
    lu.assertFalse(adapters.verifyPool(row, "slot", "other"))
end

function TestNativeAdapters.testChaosSelectionVerifiesTheNativeCurseAndEmbeddedBlessingPair()
    local row = {
        node = {},
        detail = {
            traitOffer = {
                kind = "chaos",
                selected = "option1",
                curseOptions = { { curseKey = "ChaosRestrictBoonCurse", requirementCount = 3 } },
                selectedCurseValues = {},
                blessingKey = "ChaosSpecialBlessing",
                rarity = "Epic",
                blessingValues = { damageBonus = 1.2 },
            },
        },
    }
    local curse = {
        Name = "ChaosRestrictBoonCurse",
        RemainingUses = 3,
        OnExpire = {
            TraitData = {
                Name = "ChaosSpecialBlessing",
                Rarity = "Epic",
                AddOutgoingDamageModifiers = { ValidWeaponMultiplier = 2.2 },
            },
        },
    }

    lu.assertTrue(adapters.verifyTrait(row, "ChaosRestrictBoonCurse", { curse }))
    lu.assertFalse(adapters.verifyTrait(row, "ChaosSpecialBlessing", { curse }))
    curse.OnExpire.TraitData.Rarity = "Rare"
    lu.assertFalse(adapters.verifyTrait(row, "ChaosRestrictBoonCurse", { curse }))
end

function TestNativeAdapters.testMaterializationBindsTheExactPublishedRole()
    local item = occurrence("traitEligibility")
    item.transactionsByOwner.owner.roles = {
        { role = "loot", lifecyclePoint = "pickup", kind = "loot", gameName = "ApolloUpgrade" },
        { role = "resource", lifecyclePoint = "pickup", kind = "resource", gameName = "MetaCurrencyDrop" },
    }
    local index = assert(adapters.index(item))
    local producer = adapters.offer(index, "offer")
    local loot = adapters.materialized(index, producer, "ApolloUpgrade", {})
    local consumable = adapters.materialized(index, producer, "MetaCurrencyDrop", {})
    lu.assertEquals(loot.detail.role, "loot")
    lu.assertEquals(consumable.detail.role, "resource")
    lu.assertNil(adapters.materialized(index, producer, "UnknownDrop", {}))
end

function TestNativeAdapters.testProducedAcquisitionUsesItsPublishedSourceOwnerNotTimelineOwner()
    local item = occurrence("traitEligibility")
    item.transactionsByOwner.owner.sourceOwner = "incoming-reward"
    item.transactionsByOwner.owner.roles = {
        { role = "self", lifecyclePoint = "pickup", kind = "resource", gameName = "MetaCurrencyDrop" },
    }
    item.transactionsByOwner.child = {
        owner = "child-action",
        sourceOwner = "child-source",
        kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            {
                role = "source", lifecyclePoint = "pickup", kind = "consumable",
                gameName = "RoomRewardConsolationPrize",
                producer = {
                    kind = "artificerReplacement",
                    sourceOwner = "incoming-reward",
                    sourceRole = "self",
                },
            },
        },
    }
    local index = assert(adapters.index(item))
    local source = adapters.lookup(index, "owner", "owner")
    local child = adapters.produced(index, source, "self")
    lu.assertEquals(child.node.owner, "child-action")
    lu.assertEquals(child.detail.gameName, "RoomRewardConsolationPrize")
end

function TestNativeAdapters.testReachableReadersProjectNativeState()
    local run = { Hero = { Traits = {} }, RewardPriorities = { Boon = 1 } }
    lu.assertEquals(readers.read("steadyGrowth", run, nil, {}), {})
    lu.assertEquals(readers.read("chaos", run), { active = {}, matured = {} })
    local keepsakes = readers.read("keepsakeEffects", run, nil, {})
    lu.assertEquals(keepsakes.olympianSources, {})
    lu.assertEquals(keepsakes.experimentalHammers, {})
    lu.assertTrue(require("mods/json").isNull(keepsakes.figurine))
    lu.assertEquals(readers.read("rewardPriorities", run), { Boon = 1 })
    lu.assertEquals(readers.read("pathOfStars", run), {
        spellTraitKey = nil, layoutKey = nil, talentKeys = {}, closed = false,
        bankedPathPoints = 0, investedPathPoints = 0,
    })
    lu.assertEquals(readers.read("forfeit", run), "inactive")
    lu.assertEquals(readers.read("stygianWell", run), {
        sparkUses = 0, yarnUses = 0, hymnUses = 0, discountUses = {},
        emptySlotUses = {}, extendedUses = 0,
    })
    lu.assertNil(readers.read("echoShopDuplicate", run))
    lu.assertNil(readers.read("hermesShrineDeliveries", run))
end

function TestNativeAdapters.testKeepsakeReaderDerivesMutableFigurineStateFromNativeTraits()
    local expected = { figurine = { origin = "ordinary", status = "pending", rarity = "Epic" } }
    local run = {
        Hero = { Traits = { { Name = "BossMetaUpgradeKeepsake", Rarity = "Rare", RemainingUses = 1 } } },
        TemporaryMetaUpgrades = {},
    }
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).figurine, {
        origin = "ordinary", status = "pending", rarity = "Rare",
    })
    run.Hero.Traits[1].RemainingUses = 0
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).figurine, {
        origin = "ordinary", status = "consumed", rarity = "Rare",
    })
end

function TestNativeAdapters.testKeepsakeReaderUsesNativeCardAndTimePieceFields()
    local expected = {
        callingCard = { remainingCharges = 2 },
        timePiece = { remainingCharges = 2 },
    }
    local run = {
        Hero = { Traits = {
            { Name = "RarifyKeepsake", RarityUpgradeData = { Uses = 1 } },
            { Name = "GoldifyKeepsake", BoonConversionUses = 0 },
        } },
    }
    local observed = readers.read("keepsakeEffects", run, nil, expected)
    lu.assertEquals(observed.callingCard, { remainingCharges = 1 })
    lu.assertEquals(observed.timePiece, { remainingCharges = 0 })
end
