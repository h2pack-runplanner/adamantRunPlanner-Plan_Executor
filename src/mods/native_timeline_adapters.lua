-- Planner-visible outcome comparison for native hook groups. Exact
-- occurrence-local owner correlation lives in room/timeline/bindings.lua.
local timeline = {}

local function selectedOption(offer)
    if type(offer) ~= "table" then return nil end
    if offer.kind == "fallbackGold" then return { key = "FallbackGold" } end
    local index = type(offer.selected) == "string" and tonumber(offer.selected:match("(%d+)$")) or nil
    return index and offer.options and offer.options[index] or nil
end

local function copyRecord(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function optionKey(offer, index)
    local option = offer.options and offer.options[index]
    if option == nil then return nil end
    return option.key
end

function timeline.expectedTrait(row)
    if row == nil then return nil end
    local node, role = row.transaction, row.detail
    if role and role.traitOffer then return selectedOption(role.traitOffer), role.traitOffer end
    local resolution = node.resolution
    if resolution and resolution.kind == "traitOffer" then
        return selectedOption(resolution.offer), resolution.offer
    end
    return nil
end

function timeline.applyTraitOffer(row, lootData)
    local _, offer = timeline.expectedTrait(row)
    if offer == nil or type(lootData) ~= "table" then return false end
    if offer.kind == "fallbackGold" then
        lootData.UpgradeOptions = { { ItemName = "FallbackGold", Rarity = "Common" } }
        return true
    end
    if offer.kind ~= "traits" then return false end
    local existing = {}
    for _, candidate in ipairs(lootData.UpgradeOptions or {}) do
        if type(candidate) == "table" and candidate.ItemName ~= nil then
            existing[candidate.ItemName] = candidate
        end
    end
    lootData.UpgradeOptions = {}
    for index, option in ipairs(offer.options or {}) do
        local expectedOptionKey = optionKey(offer, index)
        local item = copyRecord(existing[expectedOptionKey])
        item.ItemName = expectedOptionKey
        if option.rarity ~= nil then item.Rarity = option.rarity end
        if option.effectiveLevel ~= nil then item.StackNum = option.effectiveLevel end
        item.TraitToReplace = option.replacement and option.replacement.replacedTraitKey or nil
        item.OldRarity = option.replacement and option.replacement.oldRarity or nil
        lootData.UpgradeOptions[index] = item
    end
    return true
end

function timeline.applyNpcTraitOffer(row, args)
    local _, offer = timeline.expectedTrait(row)
    if offer == nil or offer.kind ~= "traits" or type(args) ~= "table"
        or type(args.UpgradeOptions) ~= "table" then
        return false
    end
    local candidates = {}
    for _, candidate in ipairs(args.UpgradeOptions) do
        if type(candidate) == "table" and candidate.ItemName ~= nil then
            candidates[candidate.ItemName] = candidate
        end
    end
    for index in ipairs(offer.options or {}) do
        if candidates[optionKey(offer, index)] == nil then return false end
    end
    if not timeline.applyTraitOffer(row, args) then return false end
    for _, option in ipairs(args.UpgradeOptions) do
        option.GameStateRequirements = nil
        option.PriorityRequirements = nil
    end
    return true
end

return timeline
