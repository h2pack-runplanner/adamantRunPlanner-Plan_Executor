-- luacheck: globals TestNativeAdapters
local lu = require("luaunit")
local adapters = require("mods/native_timeline_adapters")
local bindings = require("mods.room.timeline.bindings")
local timelineSession = require("mods.room.timeline.session")
local readers = require("mods.room.conformance.readers")

TestNativeAdapters = {}

local contacts = {
    "traitEligibility", "storeInventoryGeneration", "storePurchase", "npcConsumableSelection",
}

local function resolved(index, contact)
    return assert(bindings.resolve(index, contact))
end

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
        local index = assert(bindings.index(occurrence(contact)))
        local relation = {
            availabilityContact = contact, preferredKey = "preferred", fallbackKey = "fallback",
        }
        local owner = resolved(index, { kind = "offer", offerKey = "offer" })
        local key, row = adapters.resolveFallback(bindings.payload(owner), contact, relation,
            function(candidate) return candidate == "preferred" end, {})
        lu.assertEquals(key, "preferred")
        lu.assertEquals(row.transaction.owner, "owner")

        index = assert(bindings.index(occurrence(contact)))
        owner = resolved(index, { kind = "offer", offerKey = "offer" })
        key, row = adapters.resolveFallback(bindings.payload(owner), contact, relation,
            function(candidate) return candidate == "fallback" end, {})
        lu.assertEquals(key, "fallback")
        lu.assertEquals(row.realizedKey, "fallback")

        index = assert(bindings.index(occurrence(contact)))
        owner = resolved(index, { kind = "offer", offerKey = "offer" })
        lu.assertNil(adapters.resolveFallback(bindings.payload(owner), contact, relation,
            function() return false end, {}))
    end
end

function TestNativeAdapters.testIndexesRejectAmbiguousPublishedKeys()
    local item = occurrence("traitEligibility")
    item.transactionsByOwner.other = {
        owner = "other", kind = "acquisition", offerKey = "offer",
        window = { kind = "standard", phase = "beforeCombat" },
    }
    local index, errorValue = bindings.index(item)
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
    local index = assert(bindings.index(item))
    local relation = item.transactionsByOwner.owner.runtimeFallbacks[1]
    local first = resolved(index, { kind = "offer", offerKey = "offer" })
    local second = resolved(index, { kind = "offer", offerKey = "other-offer" })
    local _, firstRow = adapters.resolveFallback(bindings.payload(first), "traitEligibility", relation,
        function(candidate) return candidate == "preferred" end, {})
    local _, secondRow = adapters.resolveFallback(bindings.payload(second), "traitEligibility", relation,
        function(candidate) return candidate == "fallback" end, {})
    lu.assertEquals(firstRow.transaction.owner, "owner")
    lu.assertEquals(secondRow.transaction.owner, "other")
end

function TestNativeAdapters.testOutcomeVerifiersRequirePublishedFields()
    local index = assert(bindings.index(occurrence("traitEligibility")))
    local row = resolved(index, { kind = "offer", offerKey = "offer" })
    row.transaction.kind, row.transaction.generationKey = "wellPurchase", "initial:left"
    row.transaction.twistResultKey = "Twist"
    local payload = bindings.payload(row)
    lu.assertTrue(adapters.verifyWell(payload, "initial:left", "offer", "Twist"))
    row.realizedKey = "fallback"
    payload.realizedKey = "fallback"
    lu.assertTrue(adapters.verifyWell(payload, "initial:left", "fallback", "Twist"))
    lu.assertEquals(adapters.effectiveOfferKey(payload), "fallback")
    lu.assertFalse(adapters.verifyWell(payload, "initial:right", "offer", "Twist"))
    row.transaction.kind, row.transaction.slotKey, row.transaction.traitKey = "poolSale", "slot", "trait"
    lu.assertTrue(adapters.verifyPool(payload, "slot", "trait"))
    lu.assertFalse(adapters.verifyPool(payload, "slot", "other"))
end

function TestNativeAdapters.testChaosSelectionVerifiesTheNativeCurseAndEmbeddedBlessingPair()
    local row = {
        transaction = {},
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
    local index = assert(bindings.index(item))
    local producer = resolved(index, { kind = "offer", offerKey = "offer" })
    local loot = assert(bindings.resolve(index,
        { kind = "materialized", gameName = "ApolloUpgrade" }, producer))
    local consumable = assert(bindings.resolve(index,
        { kind = "materialized", gameName = "MetaCurrencyDrop" }, producer))
    lu.assertEquals(loot.detail.role, "loot")
    lu.assertEquals(consumable.detail.role, "resource")
    lu.assertNil(bindings.resolve(index, { kind = "materialized", gameName = "UnknownDrop" }, producer))
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
    local index = assert(bindings.index(item))
    local source = resolved(index, { kind = "offer", offerKey = "offer" })
    local child = bindings.resolve(index, { kind = "produced", role = "self" }, source)
    lu.assertEquals(child.transaction.owner, "child-action")
    lu.assertEquals(child.detail.gameName, "RoomRewardConsolationPrize")
end

function TestNativeAdapters.testTimelineClaimUsesPublishedOrderForIndependentCompatibleActions()
    local first = {
        owner = "first", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            { role = "first", lifecyclePoint = "roomExit", kind = "resource",
                gameName = "ElementalBoost", disposition = "normal" },
        },
    }
    local second = {
        owner = "second", kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            { role = "second", lifecyclePoint = "roomRewardPickup", kind = "resource",
                gameName = "ElementalBoost", disposition = "normal" },
        },
    }
    local claimOccurrence = {
        transactionsByOwner = { second = second, first = first },
        timeline = { transactions = { first, second }, dependencies = {}, obligations = {} },
    }
    local index = assert(bindings.index(claimOccurrence))
    local session = timelineSession.new(claimOccurrence, index)
    local function compatible(transaction, contact)
        for _, role in ipairs(transaction.roles or {}) do
            if role.gameName == contact.gameName then return role end
        end
    end
    local firstNative, secondNative = { Name = "ElementalBoost" }, { Name = "ElementalBoost" }
    local firstHandle, firstPayload = timelineSession.claimReady(session,
        { kind = "directPickup", gameName = "ElementalBoost" }, firstNative, compatible)
    lu.assertNotNil(firstHandle)
    lu.assertEquals(firstPayload.transaction.owner, "first")
    local secondHandle, secondPayload = timelineSession.claimReady(session,
        { kind = "directPickup", gameName = "ElementalBoost" }, secondNative, compatible)
    lu.assertNotNil(secondHandle)
    lu.assertEquals(secondPayload.transaction.owner, "second")
    lu.assertEquals(timelineSession.bound(session, firstNative), firstHandle)
    lu.assertEquals(timelineSession.bound(session, secondNative), secondHandle)
    lu.assertNil(timelineSession.claimReady(session,
        { kind = "directPickup", gameName = "UnknownDrop" }, { Name = "UnknownDrop" }, compatible))
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

function TestNativeAdapters.testStygianWellReaderRetainsIxionAndDurationStateExactlyOnce()
    local run = { Hero = { Traits = {
        { Name = "TemporaryForcedSecretDoorTrait", RemainingUses = 2 },
        { Name = "TemporaryDiscountTrait", RemainingUses = 4 },
    } } }
    lu.assertEquals(readers.read("stygianWell", run), {
        sparkUses = 2, yarnUses = 0, hymnUses = 0, discountUses = { 4 },
        emptySlotUses = {}, extendedUses = 0,
    })
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

function TestNativeAdapters.testKeepsakeReaderProjectsFigLeafUsesAndBiomeLatch()
    local expected = { figLeaf = { remainingUses = 2, activatedThisBiome = false } }
    local run = {
        Hero = { Traits = {
            {
                Name = "PersistentDionysusSkipKeepsake",
                RemainingUses = 2,
                ActivatedThisBiome = false,
            },
        } },
        CurrentRoom = { TraitUses = {} },
    }
    local observed = readers.read("keepsakeEffects", run, nil, expected)
    lu.assertEquals(observed.figLeaf, { remainingUses = 2, activatedThisBiome = false })

    run.Hero.Traits[1].RemainingUses = 1
    run.Hero.Traits[1].ActivatedThisBiome = true
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).figLeaf, {
        remainingUses = 1, activatedThisBiome = true,
    })

    run.Hero.Traits[1].ActivatedThisBiome = false
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).figLeaf, {
        remainingUses = 1, activatedThisBiome = false,
    })

    run.Hero.Traits = {}
    run.CurrentRoom.TraitUses.PersistentDionysusSkipKeepsake = 1
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).figLeaf, {
        remainingUses = 0, activatedThisBiome = true,
    })

    run.CurrentRoom.TraitUses = {}
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).figLeaf, {
        remainingUses = 0, activatedThisBiome = false,
    })

    run.Hero.Traits = {
        { Name = "PersistentDionysusSkipKeepsake", RemainingUses = 1, ActivatedThisBiome = false },
        { Name = "PersistentDionysusSkipKeepsake", RemainingUses = 3, ActivatedThisBiome = true },
    }
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).figLeaf, {
        remainingUses = 3, activatedThisBiome = true,
    })
end

function TestNativeAdapters.testKeepsakeReaderProjectsGorgonPendingConsumedAndExpired()
    local expected = { gorgon = { status = "pending", rarity = "Epic" } }
    local run = {
        Hero = { Traits = {
            {
                Name = "AthenaEncounterKeepsake", Slot = "Keepsake",
                RemainingUses = 1, Rarity = "Epic",
            },
        } },
        ExpiredKeepsakes = {},
    }
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).gorgon, {
        status = "pending", rarity = "Epic",
    })

    run.Hero.Traits[1].RemainingUses = 0
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).gorgon, {
        status = "consumed",
    })

    run.Hero.Traits[1].RemainingUses = 1
    run.ExpiredKeepsakes.AthenaEncounterKeepsake = true
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).gorgon, {
        status = "consumed",
    })

    run.ExpiredKeepsakes = {}
    run.Hero.Traits[1].Slot = nil
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).gorgon, {
        status = "expired",
    })

    run.Hero.Traits = {}
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).gorgon, {
        status = "expired",
    })
end

function TestNativeAdapters.testKeepsakeReaderUsesNativeOlympianSourceCharges()
    local expected = {
        olympianSources = {
            {
                keepsakeKey = "ForceApolloBoonKeepsake", providerKey = "Apollo", origin = "ordinary",
                acquisitionOrder = 3, remainingForceUses = 1, remainingRarificationUses = 1,
                maximumSourceRarityLevel = 3,
            },
        },
    }
    local run = {
        Hero = { Traits = { {
            Name = "ForceApolloBoonKeepsake", Uses = 1,
            RarityUpgradeData = { Uses = 0, LootName = "ApolloUpgrade", MaxRarity = 3 },
        } } },
    }
    lu.assertEquals(readers.read("keepsakeEffects", run, nil, expected).olympianSources, { {
        keepsakeKey = "ForceApolloBoonKeepsake", providerKey = "Apollo", origin = "ordinary",
        acquisitionOrder = 3, remainingForceUses = 1, remainingRarificationUses = 0,
        maximumSourceRarityLevel = 3,
    } })
end

function TestNativeAdapters.testEmbryoAutomaticComparisonIncludesExactBlessingValues()
    local row = {
        transaction = {
            kind = "automatic", effect = "transcendentEmbryo", target = "ChaosWeaponBlessing",
            rarity = "Epic", blessingValues = { damageBonus = 0.7 },
        },
    }
    lu.assertTrue(adapters.verifyAutomatic(row, {
        target = "ChaosWeaponBlessing", rarity = "Epic", blessingValues = { damageBonus = 0.7 },
    }))
    lu.assertFalse(adapters.verifyAutomatic(row, {
        target = "ChaosWeaponBlessing", rarity = "Epic", blessingValues = { damageBonus = 0.8 },
    }))
    lu.assertFalse(adapters.verifyAutomatic(row, {
        target = "ChaosWeaponBlessing", rarity = "Epic",
    }))
end
