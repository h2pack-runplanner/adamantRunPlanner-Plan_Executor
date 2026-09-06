-- Single declarative translation boundary between planner semantics and native
-- Hades II identities. This table contains names and carrier descriptions only;
-- hook behavior, eligibility, planner owners, and runtime state stay with their
-- feature modules.
return {
    navigation = {
        logicalRoomAcquisitions = {
            InfernalContractBoon = true,
        },
    },
    roomFeatures = {
        shopOptionCarriers = {
            BoostedRandomLoot = {
                name = "RandomLoot",
                argsMarkers = { "AddBoostedAnimation", "BoonRaritiesOverride" },
            },
        },
        resourceSuccessFields = {
            FireEssence = "PickaxePointSuccess",
            AirEssence = "ExorcismPointSuccess",
            EarthEssence = "ShovelPointSuccess",
            WaterEssence = "FishingPointSuccess",
        },
        features = {
            stygianWell = { carrier = "roomField", key = "WellShop" },
            purgingPool = { carrier = "roomField", key = "SellTraitShop" },
            keepsakeRack = { carrier = "obstacleUseFunction", key = "UseKeepsakeRack" },
            fountain = { carrier = "obstacleUseFunction", key = "UseHealthFountain" },
            shop = { carrier = "roomField", key = "StoreDataName" },
        },
    },
    conformance = {
        shrineUpgrades = {
            forfeit = "BoonSkipShrineUpgrade",
        },
        stygianWellTraits = {
            sparkUses = "TemporaryForcedSecretDoorTrait",
            yarnUses = "TemporaryBoonRarityTrait",
            hymnUses = "LimitedSwapBonusTrait",
            discountUses = "TemporaryDiscountTrait",
            emptySlotUses = "TemporaryEmptySlotDamageTrait",
            extendedUses = "ExtendedShopTrait",
        },
        keepsakeTraits = {
            timePiece = "GoldifyKeepsake",
            callingCard = "RarifyKeepsake",
            jeweledPom = "HadesAndPersephoneKeepsake",
            phial = "FountainRarityKeepsake",
            stone = "UnpickedBoonKeepsake",
            transcendentEmbryo = "RandomBlessingKeepsake",
            figurine = "BossMetaUpgradeKeepsake",
            figLeaf = "PersistentDionysusSkipKeepsake",
            gorgon = "AthenaEncounterKeepsake",
        },
    },
    keepsakeEffects = {
        equipContacts = {
            experimentalHammer = "GiveDurationHammer",
            jeweledPom = "GiveRandomHadesBoonAndBoostBoons",
            transcendentEmbryo = "ChaosBlessingBonus",
        },
    },
}
