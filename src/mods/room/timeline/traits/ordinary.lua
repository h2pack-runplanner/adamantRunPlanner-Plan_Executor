-- Native-carrier preparation and terminal proof for ordinary boon screens.
-- This module owns only the frozen offer result; native code owns generation,
-- menu behavior, trait application, replacement, and rarification clicks.
local ordinary = {}

local function optionIndex(key)
    return type(key) == "string" and tonumber(key:match("(%d+)$")) or nil
end

local function copy(value)
    local result = {}
    for key, nested in pairs(value or {}) do result[key] = nested end
    return result
end

function ordinary.offer(payload)
    if type(payload) ~= "table" then return nil end
    local offer = payload.detail and payload.detail.traitOffer
        or payload.transaction and payload.transaction.resolution
            and payload.transaction.resolution.kind == "traitOffer"
            and payload.transaction.resolution.offer
    if type(offer) ~= "table" then return nil end
    if offer.kind == "fallbackGold" then return offer end
    return offer.kind == "traits" and offer or nil
end

function ordinary.isCarrier(loot, offer)
    if type(loot) ~= "table" or type(offer) ~= "table" then return false end
    if offer.kind == "fallbackGold" then return loot.GodLoot == true or loot.Name == "HermesUpgrade" end
    return loot.GodLoot == true or loot.Name == "HermesUpgrade" or loot.Name == "WeaponUpgrade"
end

function ordinary.isNativeCarrier(loot)
    return type(loot) == "table" and (loot.GodLoot == true or loot.Name == "HermesUpgrade"
        or loot.Name == "WeaponUpgrade")
end

function ordinary.realizedKey(payload, index)
    local offer = ordinary.offer(payload)
    if offer == nil or offer.kind == "fallbackGold" then return nil end
    local option = offer.options and offer.options[index]
    if option == nil then return nil end
    if payload.realizedKey and index == optionIndex(offer.selected) then return payload.realizedKey end
    return option.key
end

function ordinary.install(payload, loot)
    local offer = ordinary.offer(payload)
    if offer == nil or type(loot) ~= "table" then return false end
    if offer.kind == "fallbackGold" then
        loot.UpgradeOptions = { { Type = "Trait", ItemName = "FallbackGold", Rarity = "Common" } }
        return true
    end
    local rows = loot.UpgradeOptions or {}
    local installed = {}
    for index, option in ipairs(offer.options or {}) do
        -- Preserve the positional native carrier. Native button construction
        -- supplies declaration fields later, so never require a matching roll.
        local row = copy(rows[index])
        row.Type = row.Type or "Trait"
        row.ItemName = ordinary.realizedKey(payload, index)
        row.Rarity = option.baseRarity or option.rarity
        if option.replacement then
            row.TraitToReplace = option.replacement.replacedTraitKey
            row.OldRarity = option.replacement.oldRarity
            row.StackNum = nil
        else
            row.TraitToReplace, row.OldRarity = nil, nil
            row.StackNum = option.effectiveLevel
        end
        installed[index] = row
    end
    loot.UpgradeOptions = installed
    return true
end

local function physicalIndex(loot, key)
    for index, row in ipairs(loot and loot.UpgradeOptions or {}) do
        if row.ItemName == key then return index end
    end
    return nil
end

function ordinary.alignRejected(payload, screen, loot)
    local offer = ordinary.offer(payload)
    if offer == nil or offer.kind == "fallbackGold" or offer.rejected == nil
        or type(screen) ~= "table" then return end
    local rejected = ordinary.realizedKey(payload, optionIndex(offer.rejected))
    local index = physicalIndex(loot, rejected)
    if index ~= nil then screen.BlockedIndexes = { index } end
end

function ordinary.verify(payload, selected, traits)
    local offer = ordinary.offer(payload)
    if offer == nil then return false end
    if offer.kind == "fallbackGold" then
        if selected ~= "FallbackGold" then return false end
        for _, trait in pairs(traits or {}) do
            if type(trait) == "table" and (trait.Name == "FallbackGold" or trait.TraitName == "FallbackGold") then
                return true
            end
        end
        return false
    end
    local selectedIndex = optionIndex(offer.selected)
    local expected = selectedIndex and ordinary.realizedKey(payload, selectedIndex)
    if expected == nil or selected ~= expected then return false end
    local option = offer.options[selectedIndex]
    for _, trait in pairs(traits or {}) do
        if type(trait) == "table" and (trait.Name == expected or trait.TraitName == expected) then
            if option.rarity ~= nil and trait.Rarity ~= option.rarity then return false end
            if option.effectiveLevel ~= nil and trait.StackNum ~= option.effectiveLevel then return false end
            if option.replacement then
                for _, old in pairs(traits or {}) do
                    if type(old) == "table" and (old.Name == option.replacement.replacedTraitKey
                        or old.TraitName == option.replacement.replacedTraitKey) then return false end
                end
            end
            return true
        end
    end
    return false
end

return ordinary
