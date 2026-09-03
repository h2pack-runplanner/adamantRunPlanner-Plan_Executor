-- Planner-visible outcome comparison for native hook groups. Exact
-- occurrence-local owner correlation lives in room/timeline/bindings.lua.
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods/chaos")
local timeline = {}

local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) == "number" then return math.abs(left - right) < 0.0000001 end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not same(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

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

local function realizedOptionKey(row, offer, index)
    local option = offer.options and offer.options[index]
    if option == nil then return nil end
    local selected = type(offer.selected) == "string" and tonumber(offer.selected:match("(%d+)$")) or nil
    if row.realizedKey and index == selected then return row.realizedKey end
    return option.key
end

local function sameFallback(left, right)
    return type(left) == "table" and left.preferredKey == right.preferredKey
        and left.fallbackKey == right.fallbackKey
        and left.availabilityContact == right.availabilityContact
end

local function declaredFallback(row, fallback)
    if row == nil or row.transaction == nil then return true end
    local choices = { row.transaction.runtimeFallbacks }
    if row.transaction.resolution and row.transaction.resolution.outcome then
        choices[#choices + 1] = row.transaction.resolution.outcome.runtimeFallbacks
    end
    if row.detail and row.detail.traitOffer then choices[#choices + 1] = row.detail.traitOffer.runtimeFallbacks end
    for _, list in ipairs(choices) do
        for _, candidate in ipairs(list or {}) do
            if sameFallback(candidate, fallback) then return true end
        end
    end
    return false
end

function timeline.resolveFallback(row, contact, fallback, available)
    local key = available(fallback.preferredKey) and fallback.preferredKey or nil
    if key == nil and available(fallback.fallbackKey) then key = fallback.fallbackKey end
    if key == nil then
        return nil, { checkpoint = "availability:" .. contact,
            expected = { fallback.preferredKey, fallback.fallbackKey }, observed = "neither" }
    end
    if not declaredFallback(row, fallback) then
        return nil, { checkpoint = "availability:" .. contact, expected = fallback, observed = key }
    end
    if type(row) == "table" then row.realizedKey = key end
    return key, row
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
        local optionKey = realizedOptionKey(row, offer, index)
        local item = copyRecord(existing[optionKey])
        item.ItemName = optionKey
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
        if candidates[realizedOptionKey(row, offer, index)] == nil then return false end
    end
    if not timeline.applyTraitOffer(row, args) then return false end
    for _, option in ipairs(args.UpgradeOptions) do
        option.GameStateRequirements = nil
        option.PriorityRequirements = nil
    end
    return true
end

function timeline.verifyTrait(row, selectedKey, heroTraits)
    local expected, offer = timeline.expectedTrait(row)
    if offer and offer.kind == "chaos" then
        local selectedIndex = type(offer.selected) == "string"
            and tonumber(offer.selected:match("(%d+)$")) or nil
        local curse = selectedIndex and offer.curseOptions and offer.curseOptions[selectedIndex]
        if curse == nil or selectedKey ~= curse.curseKey then return false end
        for _, trait in pairs(heroTraits or {}) do
            if type(trait) == "table" and (trait.Name == selectedKey or trait.TraitName == selectedKey) then
                local blessing = trait.OnExpire and trait.OnExpire.TraitData
                return chaos.matchesCurse(trait, curse.curseKey, curse.requirementCount,
                        offer.selectedCurseValues)
                    and chaos.matchesBlessing(blessing, offer.blessingKey, offer.rarity,
                        offer.blessingValues)
            end
        end
        return false
    end
    local expectedKey = row and row.realizedKey or expected and expected.key
    if (expected == nil and not (offer and offer.kind == "chaos")) or expectedKey ~= selectedKey then
        return false
    end
    if selectedKey == "FallbackGold" then return true end
    for _, trait in pairs(heroTraits or {}) do
        if type(trait) == "table" and (trait.Name == selectedKey or trait.TraitName == selectedKey) then
            local rarity = expected and expected.rarity or offer and offer.rarity
            if rarity ~= nil and trait.Rarity ~= rarity then return false end
            if expected and expected.effectiveLevel ~= nil and trait.StackNum ~= expected.effectiveLevel then
                return false
            end
            return true
        end
    end
    return false
end

function timeline.applyLevelResolution(row, lootData)
    local role = row and row.detail
    local resolution = role and role.levelResolution
    if resolution == nil or type(lootData) ~= "table" then return false end
    lootData.StackOnly, lootData.StackNum, lootData.UpgradeOptions = true, resolution.levelCount, {}
    for index, key in ipairs(resolution.offeredTargets) do lootData.UpgradeOptions[index] = { ItemName = key } end
    return true
end

function timeline.verifyLevel(row, selectedKey, before, heroTraits)
    local role = row and row.detail
    local resolution = role and role.levelResolution
    if resolution == nil or resolution.selectedTarget ~= selectedKey then return false end
    if selectedKey == nil then return true end
    for _, trait in pairs(heroTraits or {}) do
        if type(trait) == "table" and (trait.Name == selectedKey or trait.TraitName == selectedKey) then
            return type(before) == "number" and trait.StackNum == before + resolution.levelCount
        end
    end
    return false
end

function timeline.verifySimple(row, gameName)
    return row ~= nil and row.detail ~= nil and row.detail.gameName == gameName
end

function timeline.verifyWell(row, generationKey, offerKey, twistResultKey)
    local node = row and row.transaction
    return node ~= nil and (node.kind == "wellPurchase" or node.kind == "wellRefill")
        and node.generationKey == generationKey
        and (row.realizedKey or node.offerKey) == offerKey
        and node.twistResultKey == twistResultKey
end

function timeline.effectiveOfferKey(row)
    return row and (row.realizedKey or row.transaction and row.transaction.offerKey) or nil
end

function timeline.verifyPool(row, slotKey, traitKey)
    local node = row and row.transaction
    return node ~= nil and node.kind == "poolSale"
        and node.slotKey == slotKey and node.traitKey == traitKey
end

function timeline.verifyKeepsake(row, keepsakeKey, equipResults)
    local node = row and row.transaction
    return node ~= nil and node.kind == "keepsakeChange" and node.keepsakeKey == keepsakeKey
        and (node.equipResults == nil or same(node.equipResults, equipResults))
end

function timeline.verifyFountain(row, target)
    local node = row and row.transaction
    return node ~= nil and node.kind == "fountainUse" and node.aromaticPhialTarget == target
end

function timeline.verifyAutomatic(row, observed)
    local node = row and row.transaction
    if node == nil or node.kind ~= "automatic" then return false end
    if node.effect == "steadyGrowth" then
        return type(observed) == "table" and observed.target == node.target
            and (node.rarity == nil or observed.rarity == node.rarity)
    end
    if node.effect == "transcendentEmbryo" then
        return type(observed) == "table" and observed.target == node.target
            and observed.rarity == node.rarity
            and same(observed.blessingValues, node.blessingValues)
    end
    if node.effect == "judgment" or node.effect == "crystalFigurine" then
        return type(observed) == "table" and same(observed.arcanaKeys, node.arcanaKeys)
            and observed.rarity == node.rarity
    end
    return false
end

return timeline
