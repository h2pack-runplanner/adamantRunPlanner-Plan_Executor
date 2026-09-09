-- Native-carrier preparation for ordinary boon screens.
-- This module owns only the frozen offer result; native code owns generation,
-- menu behavior, trait application, replacement, and rarification clicks.
local ordinary = {}
local json = type(import) == "function" and import("mods/protocol/json.lua") or require("mods.protocol.json")
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local encounterTraitOfferCarriers = nativeBindings.timeline.encounterTraitOfferCarriers

local function nativeName(value)
    return type(value) == "table" and (value.Name or value.ItemName or value.LootName) or nil
end

local function normalRole(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        if role.gameName == contact.gameName and role.disposition == "normal"
            and role.traitOffer ~= nil then
            return role
        end
    end
    return nil
end

function ordinary.isNormalPayload(payload)
    local detail = type(payload) == "table" and payload.detail or nil
    if type(detail) == "table" then
        return detail.disposition == "normal" and detail.traitOffer ~= nil
    end
    local transaction = type(payload) == "table" and payload.transaction or nil
    local resolution = type(transaction) == "table" and transaction.resolution or nil
    return type(transaction) == "table" and transaction.kind == "encounterInteraction"
        and type(resolution) == "table"
        and resolution.kind == "traitOffer" and resolution.offer ~= nil
end

function ordinary.normalRole(transaction, contact)
    return normalRole(transaction, contact)
end

function ordinary.encounterTraitOffer(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "encounterInteraction" then return nil end
    local resolution = transaction.resolution
    local offer = type(resolution) == "table" and resolution.kind == "traitOffer" and resolution.offer or nil
    local giver = type(offer) == "table" and offer.giver or nil
    return giver ~= nil and encounterTraitOfferCarriers[contact.gameName] == giver or nil
end

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
    if not ordinary.isNormalPayload(payload) then return nil end
    if offer.kind == "fallbackGold" then return offer end
    return offer.kind == "traits" and offer or nil
end

function ordinary.isCarrier(loot, offer)
    if type(loot) ~= "table" or type(offer) ~= "table" then return false end
    if offer.kind == "fallbackGold" then return loot.GodLoot == true or loot.Name == "HermesUpgrade" end
    local encounterGiver = encounterTraitOfferCarriers[nativeName(loot)]
    return loot.GodLoot == true or loot.Name == "HermesUpgrade" or loot.Name == "WeaponUpgrade"
        or encounterGiver ~= nil and encounterGiver == offer.giver
end

function ordinary.isNativeCarrier(loot)
    return type(loot) == "table" and (loot.GodLoot == true or loot.Name == "HermesUpgrade"
        or loot.Name == "WeaponUpgrade")
end

function ordinary.isEncounterTraitOfferCarrier(loot)
    return encounterTraitOfferCarriers[nativeName(loot)] ~= nil
end

-- Native declarations must admit every exact authored row before the adapter
-- overwrites positional menu entries. An unavailable exact row is a contact
-- mismatch rather than a substitution.
function ordinary.nativeRowsAvailable(offer)
    if type(offer) ~= "table" or offer.kind == "fallbackGold" then return true end
    local declarations = _G.TraitData
    for _, option in ipairs(offer.options or {}) do
        local key = option and option.key
        local declaration = key and declarations[key]
        if declaration == nil then return false end
        if _G.IsTraitEligible(declaration) ~= true then return false end
    end
    return true
end

function ordinary.optionKey(payload, index)
    local offer = ordinary.offer(payload)
    if offer == nil or offer.kind == "fallbackGold" then return nil end
    local option = offer.options and offer.options[index]
    if option == nil then return nil end
    return option.key
end

function ordinary.selectedKey(payload)
    local offer = ordinary.offer(payload)
    if offer and offer.kind == "fallbackGold" then return "FallbackGold" end
    local index = offer and optionIndex(offer.selected)
    return index and ordinary.optionKey(payload, index) or nil
end

function ordinary.optionForKey(payload, key)
    local offer = ordinary.offer(payload)
    for _, option in ipairs(offer and offer.options or {}) do
        if option.key == key then return option end
    end
    return nil
end

function ordinary.optionForOptionKey(payload, optionKey)
    local offer = ordinary.offer(payload)
    local index = offer and optionIndex(optionKey)
    return index and offer.options and offer.options[index] or nil
end

function ordinary.allTogetherResult(payload)
    local offer = ordinary.offer(payload)
    local index = offer and optionIndex(offer.selected)
    local option = index and offer.options and offer.options[index] or nil
    return option and option.allTogetherResult or nil
end

function ordinary.allTogetherResultForKey(payload, key)
    local option = ordinary.optionForKey(payload, key)
    return option and option.allTogetherResult or nil
end

function ordinary.naturalSelectionTargets(payload)
    local offer = ordinary.offer(payload)
    local index = offer and optionIndex(offer.selected)
    local option = index and offer.options and offer.options[index] or nil
    return option and option.naturalSelectionTargets or nil
end

function ordinary.naturalSelectionTargetsForKey(payload, key)
    local option = ordinary.optionForKey(payload, key)
    return option and option.naturalSelectionTargets or nil
end

function ordinary.targetTraitKeyForKey(payload, key)
    local option = ordinary.optionForKey(payload, key)
    return option and option.targetTraitKey or nil
end

function ordinary.concaveStoneResult(payload)
    local offer = ordinary.offer(payload)
    local index = offer and optionIndex(offer.selected)
    local option = index and offer.options and offer.options[index] or nil
    return option and option.concaveStoneResult or nil
end

function ordinary.isNull(value)
    return json.isNull(value)
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
        row.ItemName = ordinary.optionKey(payload, index)
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
    local rejected = ordinary.optionKey(payload, optionIndex(offer.rejected))
    local index = physicalIndex(loot, rejected)
    if index ~= nil then screen.BlockedIndexes = { index } end
end

return ordinary
