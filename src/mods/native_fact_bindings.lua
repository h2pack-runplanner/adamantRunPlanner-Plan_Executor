-- Closed translation boundary between planner semantic fact keys and the
-- native Hades II carriers that expose them. Game identities already carried
-- by the plan (room, reward, trait, and item names) deliberately do not appear
-- here, nor do planner-only owners, exit keys, lifecycle keys, or slot keys.
return {
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
    keepsakeEquipContacts = {
        experimentalHammer = "GiveDurationHammer",
        jeweledPom = "GiveRandomHadesBoonAndBoostBoons",
        transcendentEmbryo = "ChaosBlessingBonus",
    },
}
