-- luacheck: globals TestKeepsakeConformance
local lu = require("luaunit")
local conformance = require("mods.keepsakes.conformance")

TestKeepsakeConformance = {}

function TestKeepsakeConformance.testReadsAllMutableKeepsakeEffectsInOneSparseFact()
    local expected = {
        olympianSources = {},
        jeweledPom = {
            grantedTraitKey = "HadesTrait", active = true, levels = 4,
            acquisitionIdentity = "pom-acquisition",
        },
        experimentalHammers = {
            {
                traitKey = "OldHammer", remainingUses = 0,
                acquisitionIdentity = "old-hammer", active = false,
            },
            {
                traitKey = "LiveHammerA", remainingUses = 7,
                acquisitionIdentity = "hammer-a", active = true,
            },
            {
                traitKey = "LiveHammerB", remainingUses = 4,
                acquisitionIdentity = "hammer-b", active = true,
            },
        },
        phial = { status = "pending" },
        stone = { origin = "echo", status = "pending", rank = "Common" },
        transcendentEmbryo = {
            origin = "ordinary", rarity = "Common", progress = 0,
            markedBlessingKey = "ChaosWeaponBlessing",
            markedBlessingValues = { damageBonus = 0.1 },
            markedBlessingAcquisitionIdentity = "embryo-acquisition",
        },
    }
    local run = { Hero = { Traits = {
        { Name = "HadesAndPersephoneKeepsake", FatedBoonLevelBonus = 5 },
        { Name = "HadesTrait", GrantedTrait = true },
        { Name = "LiveHammerA", RemainingUses = 6, UsesAsEncounters = true, IsHammerTrait = true },
        { Name = "LiveHammerB", RemainingUses = 3, UsesAsEncounters = true, IsHammerTrait = true },
        { Name = "FountainRarityKeepsake", Uses = 1 },
        { Name = "UnpickedBoonKeepsake", Uses = 0, Rarity = "Epic" },
        { Name = "RandomBlessingKeepsake", CurrentRoom = 4, Rarity = "Rare" },
        {
            -- The marked blessing keeps its original rarity while Cherished
            -- Heirloom upgrades the source rarity used by the next result.
            Name = "ChaosWeaponBlessing", Rarity = "Common", FromChaosKeepsake = true,
            AddOutgoingDamageModifiers = { ValidWeaponMultiplier = 1.5 },
        },
    } }, TraitUses = {}, ExpiredKeepsakes = {} }

    local observed = conformance.read(run, { FatedStatus = "Fated" }, expected)
    lu.assertEquals(observed.jeweledPom, {
        grantedTraitKey = "HadesTrait", active = true, levels = 5,
        acquisitionIdentity = "pom-acquisition",
    })
    lu.assertEquals(observed.experimentalHammers, {
        {
            traitKey = "OldHammer", remainingUses = 0,
            acquisitionIdentity = "old-hammer", active = false,
        },
        {
            traitKey = "LiveHammerA", remainingUses = 6,
            acquisitionIdentity = "hammer-a", active = true,
        },
        {
            traitKey = "LiveHammerB", remainingUses = 3,
            acquisitionIdentity = "hammer-b", active = true,
        },
    })
    lu.assertEquals(observed.phial, { status = "pending" })
    lu.assertEquals(observed.stone, { origin = "echo", status = "consumed", rank = "Epic" })
    lu.assertEquals(observed.transcendentEmbryo, {
        origin = "ordinary", rarity = "Rare", progress = 4,
        markedBlessingKey = "ChaosWeaponBlessing",
        markedBlessingValues = { damageBonus = 0.5 },
        markedBlessingAcquisitionIdentity = "embryo-acquisition",
    })
end

function TestKeepsakeConformance.testActiveJeweledPomReadsTheNativeGrantedTrait()
    local expected = {
        jeweledPom = {
            grantedTraitKey = "ExpectedHadesTrait", active = true, levels = 3,
            acquisitionIdentity = "pom-acquisition",
        },
    }
    local missing = conformance.read({ Hero = { Traits = {
        { Name = "HadesAndPersephoneKeepsake", FatedBoonLevelBonus = 3 },
    } } }, { FatedStatus = "Fated" }, expected)
    lu.assertEquals(missing.jeweledPom.grantedTraitKey, "")

    local wrong = conformance.read({ Hero = { Traits = {
        { Name = "HadesAndPersephoneKeepsake", FatedBoonLevelBonus = 3 },
        { Name = "WrongHadesTrait", GrantedTrait = true },
    } } }, { FatedStatus = "Fated" }, expected)
    lu.assertEquals(wrong.jeweledPom.grantedTraitKey, "WrongHadesTrait")
end

function TestKeepsakeConformance.testInactiveJeweledPomRetainsGrantProvenanceAfterNativeCleanup()
    local expected = {
        jeweledPom = {
            grantedTraitKey = "RemovedHadesTrait", active = false, levels = 3,
            acquisitionIdentity = "pom-acquisition",
        },
    }
    local observed = conformance.read({ Hero = { Traits = {} } }, { FatedStatus = "Unfated" }, expected)
    lu.assertEquals(observed.jeweledPom.grantedTraitKey, "RemovedHadesTrait")
end

function TestKeepsakeConformance.testSameHammerIdentityCorrelatesTheLiveInstanceToNewestAcquisition()
    local expected = {
        experimentalHammers = {
            { traitKey = "Hammer", remainingUses = 0, acquisitionIdentity = "old", active = false },
            { traitKey = "Hammer", remainingUses = 5, acquisitionIdentity = "new", active = true },
        },
    }
    local observed = conformance.read({ Hero = { Traits = {
        { Name = "Hammer", RemainingUses = 3, UsesAsEncounters = true, IsHammerTrait = true },
    } } }, {}, expected)
    lu.assertEquals(observed.experimentalHammers, {
        { traitKey = "Hammer", remainingUses = 0, acquisitionIdentity = "old", active = false },
        { traitKey = "Hammer", remainingUses = 3, acquisitionIdentity = "new", active = true },
    })
end


function TestKeepsakeConformance.testUnexpectedLiveHammerRemainsVisibleToConformance()
    local expected = {
        experimentalHammers = {
            { traitKey = "ExpectedHammer", remainingUses = 2,
                acquisitionIdentity = "expected", active = true },
        },
    }
    local observed = conformance.read({ Hero = { Traits = {
        { Name = "ExpectedHammer", RemainingUses = 5, UsesAsEncounters = true, IsHammerTrait = true },
        { Name = "ExpectedHammer", RemainingUses = 2, UsesAsEncounters = true, IsHammerTrait = true },
        { Name = "UnrelatedDurationTrait", RemainingUses = 9, UsesAsEncounters = true },
    } } }, {}, expected)
    lu.assertEquals(#observed.experimentalHammers, 2)
    lu.assertEquals(observed.experimentalHammers[2], {
        traitKey = "ExpectedHammer",
        remainingUses = 5,
        acquisitionIdentity = "native-unmatched:ExpectedHammer:1",
        active = true,
    })
end

function TestKeepsakeConformance.testUnexpectedHammerKeyRemainsVisibleWithoutExpectedRows()
    local observed = conformance.read({ Hero = { Traits = {
        {
            Name = "UnexpectedHammer", RemainingUses = 5,
            UsesAsEncounters = true, IsHammerTrait = true,
        },
    } } }, {}, { experimentalHammers = {} })
    lu.assertEquals(observed.experimentalHammers, {
        {
            traitKey = "UnexpectedHammer",
            remainingUses = 5,
            acquisitionIdentity = "native-unmatched:UnexpectedHammer:1",
            active = true,
        },
    })
end

function TestKeepsakeConformance.testMissingPendingSourcesCannotEchoTheExpectedMutableStatus()
    local observed = conformance.read({ Hero = { Traits = {} } }, { FatedStatus = "Fated" }, {
        phial = { status = "pending" },
        stone = { origin = "ordinary", status = "pending", rank = "Epic" },
    })
    lu.assertEquals(observed.phial, { status = "consumed" })
    lu.assertEquals(observed.stone, { origin = "ordinary", status = "consumed" })
end
