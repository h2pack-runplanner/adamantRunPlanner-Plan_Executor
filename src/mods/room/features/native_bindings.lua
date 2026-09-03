-- Native carriers used only by room-feature construction and proof.
return {
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
}
