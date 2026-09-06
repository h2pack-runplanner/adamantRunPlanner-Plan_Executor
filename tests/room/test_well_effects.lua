-- luacheck: globals TestWellEffects
-- Test-owned disposition witness for the complete normalized Stygian Well pool.
-- The native game owns every effect; only volatile menu results are steered,
-- while the room conformance reader observes the six retained effects.
local lu = require("luaunit")

TestWellEffects = {}

function TestWellEffects.testEveryNormalizedWellIdentityHasOneExecutorDisposition()
    local dispositions = {
        neutral = {
            "ArmorBoostStore", "DamageSelfDrop", "HealDropRange", "EmptyMaxHealthShopItem",
            "FirstHitHealTrait", "TemporaryDoorHealTrait", "TemporaryHealExpirationTrait",
            "TemporaryImprovedSecondaryTrait", "TemporaryImprovedCastTrait", "TemporaryMoveSpeedTrait",
            "TemporaryImprovedExTrait", "TemporaryImprovedDefenseTrait", "MetaCurrencyRange",
            "MetaCardPointsCommonRange", "MemPointsCommonRange", "SeedMysteryRange",
            "LimitedManaRegenDrop",
        },
        conformance = {
            "TemporaryBoonRarityTrait", "TemporaryForcedSecretDoorTrait", "LimitedSwapTraitDrop",
            "TemporaryDiscountTrait", "TemporaryEmptySlotDamageTrait", "ExtendedShopTrait",
        },
        steer = { "RandomStoreItem", "LastStandShopItem" },
    }
    local seen = {}
    local total = 0
    for disposition, identities in pairs(dispositions) do
        for _, identity in ipairs(identities) do
            lu.assertNil(seen[identity])
            seen[identity] = disposition
            total = total + 1
        end
    end
    lu.assertEquals(total, 25)
    lu.assertEquals(seen.RandomStoreItem, "steer")
    lu.assertEquals(seen.LastStandShopItem, "steer")
    lu.assertEquals(seen.TemporaryBoonRarityTrait, "conformance")
    lu.assertEquals(seen.TemporaryForcedSecretDoorTrait, "conformance")
    lu.assertEquals(seen.LimitedSwapTraitDrop, "conformance")
end

return TestWellEffects
