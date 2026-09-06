-- luacheck: globals TestConformanceReaders
local lu = require("luaunit")
local readers = require("mods.room.conformance.readers")
local proof = require("mods.room.conformance.proof")
local nativeGame = require("tests.harness.native_game")

TestConformanceReaders = {}

function TestConformanceReaders:setUp()
    self.restoreNative = nativeGame.install({
        GetNumShrineUpgrades = nativeGame.noShrineUpgrades,
    })
end

function TestConformanceReaders:tearDown()
    self.restoreNative()
end

function TestConformanceReaders.testSupportBoundaryIsExactlyTheReachedFGFactSet()
    local active = {
        traitInventory = true,
        steadyGrowth = true,
        chaos = true,
        keepsakeEffects = true,
        rewardPriorities = true,
        pathOfStars = true,
        forfeit = true,
        stygianWell = true,
    }
    for kind in pairs(active) do lu.assertTrue(readers.supports(kind), kind) end
    for _, kind in ipairs({ "echoShopDuplicate", "hermesShrineDeliveries" }) do
        lu.assertFalse(readers.supports(kind), kind)
    end
end

function TestConformanceReaders.testTraitInventoryChecksOneAndThreeRemovalsButIgnoresUnmodeledTraits()
    local oneRemoval = {
        present = {
            { traitKey = "HammerTrait", rarity = "Legendary", hammerRank = "RankII" },
            { traitKey = "KeptTrait", rarity = "Rare", level = 2 },
        },
        absent = { "SoldOne" },
    }
    local expected = {
        present = {
            { traitKey = "HammerTrait", rarity = "Legendary", hammerRank = "RankII" },
            { traitKey = "KeptTrait", rarity = "Rare", level = 2 },
        },
        absent = { "SoldOne", "SoldThree", "SoldTwo" },
    }
    local run = { Hero = { Traits = {
        { Name = "HammerTrait", Rarity = "Legendary" },
        { Name = "KeptTrait", Rarity = "Rare", StackNum = 2 },
        { Name = "UnmodeledTrait", Rarity = "Common", StackNum = 9 },
    } } }
    local priorGetTraitCount = _G.GetTraitCount
    _G.GetTraitCount = function(hero, args)
        for _, trait in ipairs(hero.Traits) do
            if trait.Name == args.Name then return trait.StackNum or 1 end
        end
        return 0
    end
    lu.assertEquals(readers.read("traitInventory", run, nil, oneRemoval), oneRemoval)
    local observed = readers.read("traitInventory", run, nil, expected)
    lu.assertEquals(observed, expected)
    local occurrence = {
        roomExitConformance = { facts = { { kind = "traitInventory" } } },
        conformanceExpected = { traitInventory = expected },
    }
    lu.assertTrue(proof.prove(occurrence, function() return observed end))

    run.Hero.Traits[#run.Hero.Traits + 1] = { Name = "SoldTwo", Rarity = "Common" }
    local missingRemoval = readers.read("traitInventory", run, nil, expected)
    _G.GetTraitCount = priorGetTraitCount
    lu.assertNil(proof.prove(occurrence, function() return missingRemoval end))
end

function TestConformanceReaders.testTraitInventoryReadsTheEquippedNativeStackCountByName()
    local expected = {
        present = { { traitKey = "AphroditeSpecialBoon", rarity = "Epic", level = 4 } },
        absent = {},
    }
    local run = { Hero = { Traits = {
        { Name = "AphroditeSpecialBoon", Rarity = "Epic", StackNum = 1 },
    } } }
    local priorGetTraitCount = _G.GetTraitCount
    _G.GetTraitCount = function(hero, args)
        lu.assertEquals(hero, run.Hero)
        lu.assertEquals(args, { Name = "AphroditeSpecialBoon" })
        return 4
    end

    local observed = readers.read("traitInventory", run, nil, expected)
    _G.GetTraitCount = priorGetTraitCount

    lu.assertEquals(observed, expected)
end

function TestConformanceReaders.testReachableReadersProjectNativeState()
    local run = { Hero = { Traits = {} }, RewardPriorities = { Boon = 1 } }
    lu.assertEquals(readers.read("steadyGrowth", run, nil, {}), {})
    lu.assertEquals(readers.read("chaos", run), { active = {}, matured = {} })
    local keepsakes = readers.read("keepsakeEffects", run, nil, {})
    lu.assertEquals(keepsakes.olympianSources, {})
    lu.assertEquals(keepsakes.experimentalHammers, {})
    lu.assertTrue(require("mods/protocol/json").isNull(keepsakes.figurine))
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

function TestConformanceReaders.testPathReaderProjectsOnlyPublishedHighValueTalentsInCanonicalOrder()
    local run = {
        Hero = { SlottedSpell = {
            Name = "Polymorph",
            TraitName = "SpellPolymorphTrait",
            Talents = { Name = "Lung", {
                { Name = "CommonUnmodeledTalent", Rarity = "Common" },
                { Name = "EpicExpected", Rarity = "Epic" },
                { Name = "RareExpected", Rarity = "Rare" },
            } },
        } },
        NumTalentPoints = 2,
        InvestedTalentPoints = 4,
        AllSpellInvestedCache = false,
    }
    lu.assertEquals(readers.read("pathOfStars", run, nil, {
        talentKeys = { "RareExpected", "EpicExpected" },
    }), {
        spellTraitKey = "SpellPolymorphTrait", layoutKey = "Lung",
        talentKeys = { "RareExpected", "EpicExpected" }, closed = false,
        bankedPathPoints = 2, investedPathPoints = 4,
    })
end

function TestConformanceReaders.testStygianWellReaderRetainsIxionAndDurationStateExactlyOnce()
    local run = { Hero = { Traits = {
        { Name = "TemporaryForcedSecretDoorTrait", RemainingUses = 2 },
        { Name = "TemporaryDiscountTrait", RemainingUses = 4 },
    } } }
    lu.assertEquals(readers.read("stygianWell", run), {
        sparkUses = 2, yarnUses = 0, hymnUses = 0, discountUses = { 4 },
        emptySlotUses = {}, extendedUses = 0,
    })
end

function TestConformanceReaders.testKeepsakeReaderDerivesMutableFigurineStateFromNativeTraits()
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

function TestConformanceReaders.testKeepsakeReaderUsesNativeCardAndTimePieceFields()
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

function TestConformanceReaders.testKeepsakeReaderProjectsFigLeafUsesAndBiomeLatch()
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

function TestConformanceReaders.testKeepsakeReaderProjectsGorgonPendingConsumedAndExpired()
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

function TestConformanceReaders.testKeepsakeReaderUsesNativeOlympianSourceCharges()
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
