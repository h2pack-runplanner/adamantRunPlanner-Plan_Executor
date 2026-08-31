local lu = require("luaunit")
local chaos = require("mods/chaos")

TestChaos = {}

local function assertCurse(name, values, data)
    data.Name = name
    chaos.applyCurse(data, name, 4, values)
    lu.assertTrue(chaos.matchesCurse(data, name, 4, values))
end

local function assertBlessing(name, values, data)
    data.Name, data.Rarity = name, "Epic"
    chaos.applyBlessing(data, name, values)
    lu.assertTrue(chaos.matchesBlessing(data, name, "Epic", values))
end

function TestChaos.testEveryAuthoredCurseOperandUsesItsNativeProcessedField()
    assertCurse("ChaosHealthCurse", { healthPenalty = -24 }, {
        PropertyChanges = { {} },
    })
    assertCurse("ChaosSpeedCurse", { speedMultiplier = 0.52 }, {
        PropertyChanges = { {}, {} },
    })
    assertCurse("ChaosDamageCurse", { damageTaken = 0.37 }, {
        AddIncomingDamageModifiers = {},
    })
    for _, name in ipairs({ "ChaosPrimaryAttackCurse", "ChaosSecondaryAttackCurse" }) do
        assertCurse(name, { selfDamage = 5 }, { DamageOnFireWeapons = {} })
    end
    for _, name in ipairs({ "ChaosExAttackCurse", "ChaosCastCurse" }) do
        assertCurse(name, { selfDamage = 6 }, {
            OnWeaponFiredFunctions = { FunctionArgs = {} },
        })
    end
    assertCurse("ChaosDashCurse", { magickLoss = 14 }, {
        OnWeaponFiredFunctions = { FunctionArgs = {} },
    })
    assertCurse("ChaosStunCurse", { stunDuration = 0.85 }, {
        OnSelfDamagedFunction = { FunctionArgs = { DataProperties = {} } },
    })
end

function TestChaos.testEveryAuthoredBlessingOperandUsesItsNativeProcessedField()
    for _, name in ipairs({
        "ChaosWeaponBlessing",
        "ChaosSpecialBlessing",
        "ChaosCastBlessing",
    }) do
        assertBlessing(name, { damageBonus = 0.64 }, {
            AddOutgoingDamageModifiers = {},
        })
    end
    assertBlessing("ChaosExSpeedBlessing", {
        propertySpeed = 0.76,
        weaponSpeed = 0.78,
    }, {
        PropertyChanges = { {} },
        WeaponSpeedMultiplier = {},
    })
    assertBlessing("ChaosHealthBlessing", { health = 83 }, {
        PropertyChanges = { {} },
    })
    assertBlessing("ChaosManaBlessing", { magick = 72 }, {
        PropertyChanges = { {} },
    })
    assertBlessing("ChaosManaOverTimeBlessing", { magickPerSecond = 14 }, {
        SetupFunction = { Args = {} },
    })
    assertBlessing("ChaosRarityBlessing", { rareBonus = 0.73 }, {
        RarityBonus = {},
    })
    assertBlessing("ChaosMoneyBlessing", { moneyBonus = 1.35 }, {})
    assertBlessing("ChaosManaCostBlessing", { costReduction = 0.55 }, {
        ManaCostModifiers = {},
    })
    assertBlessing("ChaosDoorHealBlessing", { heal = 17 }, {})
    assertBlessing("ChaosHarvestBlessing", { doubleChance = 0.84 }, {})
end

function TestChaos.testOperandFreeIdentitiesRemainClosedAndUnknownDataFails()
    assertCurse("ChaosCommonCurse", {}, {})
    assertBlessing("ChaosElementalBlessing", {}, {})
    lu.assertError(chaos.applyCurse, {}, "UnknownCurse", 3, {})
    lu.assertError(chaos.applyBlessing, {}, "UnknownBlessing", {})
    lu.assertError(chaos.applyCurse, {}, "ChaosCommonCurse", 3, { surprise = 1 })
end

return TestChaos
