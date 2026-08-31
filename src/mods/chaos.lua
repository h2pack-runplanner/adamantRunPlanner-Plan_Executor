-- Closed TrialUpgrade processed-trait adapter. These are native Hades II
-- fields, not a planner expression language: unknown identities or operands
-- fail before the choice is presented.
local chaos = {}

local operandFreeCurses = {
    ChaosNoMoneyCurse = true,
    ChaosDeathWeaponCurse = true,
    ChaosManaFocusCurse = true,
    ChaosTimeCurse = true,
    ChaosMetaUpgradeCurse = true,
    ChaosHiddenRoomRewardCurse = true,
    ChaosCommonCurse = true,
    ChaosRestrictBoonCurse = true,
}

local operandFreeBlessings = {
    ChaosElementalBlessing = true,
    ChaosSpeedBlessing = true,
    ChaosOmegaDamageBlessing = true,
    ChaosLastStandBlessing = true,
}

local function value(values, key)
    local result = values and values[key]
    if type(result) ~= "number" then error("unsupported Chaos operand " .. tostring(key), 0) end
    return result
end

local function assertKeys(values, expected, label)
    local remaining = {}
    for key in pairs(values or {}) do remaining[key] = true end
    for _, key in ipairs(expected) do
        value(values, key)
        remaining[key] = nil
    end
    local unexpected = next(remaining)
    if unexpected ~= nil then error("unsupported " .. label .. " operand " .. tostring(unexpected), 0) end
end

local function same(left, right)
    return type(left) == "number" and math.abs(left - right) < 0.0000001
end

function chaos.applyCurse(data, curseKey, requirementCount, values)
    data.RemainingUses = requirementCount
    if curseKey == "ChaosHealthCurse" then
        assertKeys(values, { "healthPenalty" }, curseKey)
        data.PropertyChanges[1].ChangeValue = value(values, "healthPenalty")
    elseif curseKey == "ChaosSpeedCurse" then
        assertKeys(values, { "speedMultiplier" }, curseKey)
        data.PropertyChanges[2].ChangeValue = value(values, "speedMultiplier")
    elseif curseKey == "ChaosDamageCurse" then
        assertKeys(values, { "damageTaken" }, curseKey)
        data.AddIncomingDamageModifiers.ValidWeaponMultiplier = 1 + value(values, "damageTaken")
    elseif curseKey == "ChaosPrimaryAttackCurse" or curseKey == "ChaosSecondaryAttackCurse" then
        assertKeys(values, { "selfDamage" }, curseKey)
        data.DamageOnFireWeapons.Damage = value(values, "selfDamage")
    elseif curseKey == "ChaosExAttackCurse" or curseKey == "ChaosCastCurse" then
        assertKeys(values, { "selfDamage" }, curseKey)
        data.OnWeaponFiredFunctions.FunctionArgs.Damage = value(values, "selfDamage")
    elseif curseKey == "ChaosDashCurse" then
        assertKeys(values, { "magickLoss" }, curseKey)
        data.OnWeaponFiredFunctions.FunctionArgs.Cost = value(values, "magickLoss")
    elseif curseKey == "ChaosStunCurse" then
        assertKeys(values, { "stunDuration" }, curseKey)
        data.OnSelfDamagedFunction.FunctionArgs.DataProperties.Duration = value(values, "stunDuration")
    elseif operandFreeCurses[curseKey] then
        assertKeys(values, {}, curseKey)
    else
        error("unsupported Chaos curse " .. tostring(curseKey), 0)
    end
    return data
end

function chaos.applyBlessing(data, blessingKey, values)
    if blessingKey == "ChaosWeaponBlessing" or blessingKey == "ChaosSpecialBlessing"
        or blessingKey == "ChaosCastBlessing" then
        assertKeys(values, { "damageBonus" }, blessingKey)
        data.AddOutgoingDamageModifiers.ValidWeaponMultiplier = 1 + value(values, "damageBonus")
    elseif blessingKey == "ChaosExSpeedBlessing" then
        assertKeys(values, { "propertySpeed", "weaponSpeed" }, blessingKey)
        data.PropertyChanges[1].ChangeValue = value(values, "propertySpeed")
        data.WeaponSpeedMultiplier.Value = value(values, "weaponSpeed")
    elseif blessingKey == "ChaosHealthBlessing" then
        assertKeys(values, { "health" }, blessingKey)
        data.PropertyChanges[1].ChangeValue = value(values, "health")
    elseif blessingKey == "ChaosManaBlessing" then
        assertKeys(values, { "magick" }, blessingKey)
        data.PropertyChanges[1].ChangeValue = value(values, "magick")
    elseif blessingKey == "ChaosManaOverTimeBlessing" then
        assertKeys(values, { "magickPerSecond" }, blessingKey)
        data.SetupFunction.Args.ManaRegenPerSecond = value(values, "magickPerSecond")
    elseif blessingKey == "ChaosRarityBlessing" then
        assertKeys(values, { "rareBonus" }, blessingKey)
        data.RarityBonus.Rare = value(values, "rareBonus")
    elseif blessingKey == "ChaosMoneyBlessing" then
        assertKeys(values, { "moneyBonus" }, blessingKey)
        data.MoneyMultiplier = 1 + value(values, "moneyBonus")
    elseif blessingKey == "ChaosManaCostBlessing" then
        assertKeys(values, { "costReduction" }, blessingKey)
        data.ManaCostModifiers.ManaCostMultiplier = 1 - value(values, "costReduction")
    elseif blessingKey == "ChaosDoorHealBlessing" then
        assertKeys(values, { "heal" }, blessingKey)
        data.DoorHealIgnorePenaltyFixed = value(values, "heal")
    elseif blessingKey == "ChaosHarvestBlessing" then
        assertKeys(values, { "doubleChance" }, blessingKey)
        data.DoubleToolRewardChance = value(values, "doubleChance")
    elseif operandFreeBlessings[blessingKey] then
        assertKeys(values, {}, blessingKey)
    else
        error("unsupported Chaos blessing " .. tostring(blessingKey), 0)
    end
    return data
end

local function curseValues(data, curseKey)
    if curseKey == "ChaosHealthCurse" then
        return { healthPenalty = data.PropertyChanges[1].ChangeValue }
    elseif curseKey == "ChaosSpeedCurse" then
        return { speedMultiplier = data.PropertyChanges[2].ChangeValue }
    elseif curseKey == "ChaosDamageCurse" then
        return { damageTaken = data.AddIncomingDamageModifiers.ValidWeaponMultiplier - 1 }
    elseif curseKey == "ChaosPrimaryAttackCurse" or curseKey == "ChaosSecondaryAttackCurse" then
        return { selfDamage = data.DamageOnFireWeapons.Damage }
    elseif curseKey == "ChaosExAttackCurse" or curseKey == "ChaosCastCurse" then
        return { selfDamage = data.OnWeaponFiredFunctions.FunctionArgs.Damage }
    elseif curseKey == "ChaosDashCurse" then
        return { magickLoss = data.OnWeaponFiredFunctions.FunctionArgs.Cost }
    elseif curseKey == "ChaosStunCurse" then
        return { stunDuration = data.OnSelfDamagedFunction.FunctionArgs.DataProperties.Duration }
    end
    return {}
end

local function blessingValues(data, blessingKey)
    if blessingKey == "ChaosWeaponBlessing" or blessingKey == "ChaosSpecialBlessing"
        or blessingKey == "ChaosCastBlessing" then
        return { damageBonus = data.AddOutgoingDamageModifiers.ValidWeaponMultiplier - 1 }
    elseif blessingKey == "ChaosExSpeedBlessing" then
        return {
            propertySpeed = data.PropertyChanges[1].ChangeValue,
            weaponSpeed = data.WeaponSpeedMultiplier.Value,
        }
    elseif blessingKey == "ChaosHealthBlessing" then
        return { health = data.PropertyChanges[1].ChangeValue }
    elseif blessingKey == "ChaosManaBlessing" then
        return { magick = data.PropertyChanges[1].ChangeValue }
    elseif blessingKey == "ChaosManaOverTimeBlessing" then
        return { magickPerSecond = data.SetupFunction.Args.ManaRegenPerSecond }
    elseif blessingKey == "ChaosRarityBlessing" then
        return { rareBonus = data.RarityBonus.Rare }
    elseif blessingKey == "ChaosMoneyBlessing" then
        return { moneyBonus = data.MoneyMultiplier - 1 }
    elseif blessingKey == "ChaosManaCostBlessing" then
        return { costReduction = 1 - data.ManaCostModifiers.ManaCostMultiplier }
    elseif blessingKey == "ChaosDoorHealBlessing" then
        return { heal = data.DoorHealIgnorePenaltyFixed }
    elseif blessingKey == "ChaosHarvestBlessing" then
        return { doubleChance = data.DoubleToolRewardChance }
    end
    return {}
end

local function sameValues(actual, expected)
    for key, expectedValue in pairs(expected or {}) do
        if not same(actual[key], expectedValue) then return false end
    end
    for key in pairs(actual) do
        if expected == nil or expected[key] == nil then return false end
    end
    return true
end

function chaos.matchesCurse(data, curseKey, requirementCount, values)
    return type(data) == "table" and data.Name == curseKey
        and data.RemainingUses == requirementCount
        and sameValues(curseValues(data, curseKey), values)
end

function chaos.matchesBlessing(data, blessingKey, rarity, values)
    return type(data) == "table" and data.Name == blessingKey and data.Rarity == rarity
        and sameValues(blessingValues(data, blessingKey), values)
end

function chaos.clock(data)
    if data.UsesAsEncounters then return "encounters" end
    if data.UsesAsRooms then return "locations" end
    if data.Name == "ChaosCommonCurse" or data.Name == "ChaosRestrictBoonCurse" then
        return "godBoonScreens"
    end
    return nil
end

return chaos
