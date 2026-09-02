-- Closed translation boundary between planner semantic fact keys and the
-- native Hades II carriers that expose them. Game identities already carried
-- by the plan (room, reward, trait, and item names) deliberately do not appear
-- here, nor do planner-only owners, exit keys, lifecycle keys, or slot keys.
return {
    overview = {
        logicalRoomAcquisitions = {
            InfernalContractBoon = true,
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
            figurine = "BossMetaUpgradeKeepsake",
        },
    },
    keepsakeEquipContacts = {
        experimentalHammer = "GiveDurationHammer",
        jeweledPom = "GiveRandomHadesBoonAndBoostBoons",
        transcendentEmbryo = "ChaosBlessingBonus",
    },
}
