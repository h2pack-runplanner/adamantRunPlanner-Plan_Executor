-- Exact occurrence-local Timeline correlation and planner-visible outcome
-- comparison. Native hook groups own when these functions are called; this
-- module owns only published-field indexes and bounded native bindings.
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods/chaos")
local timeline = {}

local function same(left, right)
    if type(left) ~= type(right) then return false end
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

local function add(index, namespace, key, node, detail)
    if key == nil then return true end
    local rows = index[namespace]
    local prior = rows[key]
    if prior ~= nil and prior.node ~= node then
        return nil, { checkpoint = "timeline-binding", expected = "unique " .. namespace,
            observed = key }
    end
    rows[key] = { node = node, detail = detail }
    return true
end

function timeline.index(occurrence)
    local index = {
        owner = {}, role = {}, producer = {}, offer = {}, generation = {}, phase = {}, source = {},
        slot = {}, keepsake = {}, automatic = {}, native = {}, produced = {},
    }
    for owner, node in pairs(occurrence.transactionsByOwner or {}) do
        index.owner[owner] = { node = node }
        local ok, errorValue
        ok, errorValue = add(index, "offer", node.offerKey, node)
        if not ok then return nil, errorValue end
        ok, errorValue = add(index, "generation", node.generationKey, node)
        if not ok then return nil, errorValue end
        ok, errorValue = add(index, "phase", node.phaseKey, node)
        if not ok then return nil, errorValue end
        ok, errorValue = add(index, "source", node.sourceOwner, node)
        if not ok then return nil, errorValue end
        if node.producerLifecycleKey and node.reward then
            ok, errorValue = add(index, "producer",
                node.producerLifecycleKey .. "\0" .. node.reward.rewardType, node)
            if not ok then return nil, errorValue end
        end
        ok, errorValue = add(index, "slot", node.slotKey, node)
        if not ok then return nil, errorValue end
        ok, errorValue = add(index, "keepsake", node.keepsakeKey, node)
        if not ok then return nil, errorValue end
        if node.kind == "automatic" then
            ok, errorValue = add(index, "automatic", node.effect .. "\0" .. node.phaseKey, node)
            if not ok then return nil, errorValue end
        end
        for _, role in ipairs(node.roles or {}) do
            ok, errorValue = add(index, "role", role.lifecyclePoint .. "\0" .. role.gameName, node, role)
            if not ok then return nil, errorValue end
            if role.producer then
                local producedKey = role.producer.sourceOwner .. "\0" .. role.producer.sourceRole
                ok, errorValue = add(index, "produced", producedKey, node, role)
                if not ok then return nil, errorValue end
            end
        end
    end
    return index
end

function timeline.produced(index, sourceRow, sourceRole, native)
    if sourceRow == nil or sourceRow.node == nil or sourceRole == nil then return nil end
    -- Producer relations are declared against the acquisition source (for
    -- example the incoming reward), not the timeline action that settles one
    -- of that source's roles. Those addresses intentionally differ.
    local sourceOwner = sourceRow.node.sourceOwner or sourceRow.node.owner
    local key = sourceOwner .. "\0" .. sourceRole
    return timeline.bind(index, timeline.lookup(index, "produced", key), native)
end

function timeline.sourceRole(row, gameName)
    if row == nil or row.node == nil then return nil end
    if row.detail and row.detail.role then return row.detail.role end
    for _, role in ipairs(row.node.roles or {}) do
        if role.gameName == gameName then return role.role end
    end
    return nil
end

function timeline.materialized(index, sourceRow, gameName, native)
    if sourceRow == nil or sourceRow.node == nil then return nil end
    local matching
    for _, role in ipairs(sourceRow.node.roles or {}) do
        if role.gameName == gameName then
            if matching ~= nil then
                return nil, { checkpoint = "timeline-binding",
                    expected = "one materialized role", observed = gameName }
            end
            matching = role
        end
    end
    if matching == nil then return nil end
    return timeline.bind(index, { node = sourceRow.node, detail = matching }, native)
end

function timeline.lookup(index, namespace, key)
    return index and index[namespace] and index[namespace][key] or nil
end

function timeline.bind(index, row, native)
    if row == nil then return nil end
    if native ~= nil then index.native[native] = row end
    return row
end

function timeline.bound(index, native)
    return index and index.native[native] or nil
end

local function sameFallback(left, right)
    return type(left) == "table" and left.preferredKey == right.preferredKey
        and left.fallbackKey == right.fallbackKey
        and left.availabilityContact == right.availabilityContact
end

local function declaredFallback(row, fallback)
    if row == nil or row.node == nil then return true end
    local choices = { row.node.runtimeFallbacks }
    if row.node.resolution and row.node.resolution.outcome then
        choices[#choices + 1] = row.node.resolution.outcome.runtimeFallbacks
    end
    if row.detail and row.detail.traitOffer then choices[#choices + 1] = row.detail.traitOffer.runtimeFallbacks end
    for _, list in ipairs(choices) do
        for _, candidate in ipairs(list or {}) do
            if sameFallback(candidate, fallback) then return true end
        end
    end
    return false
end

function timeline.resolveFallback(index, row, contact, fallback, available, native)
    local key = available(fallback.preferredKey) and fallback.preferredKey or nil
    if key == nil and available(fallback.fallbackKey) then key = fallback.fallbackKey end
    if key == nil then
        return nil, { checkpoint = "availability:" .. contact,
            expected = { fallback.preferredKey, fallback.fallbackKey }, observed = "neither" }
    end
    if not declaredFallback(row, fallback) then
        return nil, { checkpoint = "availability:" .. contact, expected = fallback, observed = key }
    end
    timeline.bind(index, row, native)
    if type(row) == "table" then row.realizedKey = key end
    return key, row
end

function timeline.role(index, lifecyclePoint, gameName, native)
    return timeline.bind(index, timeline.lookup(index, "role", lifecyclePoint .. "\0" .. gameName), native)
end

function timeline.offer(index, offerKey, native)
    return timeline.bind(index, timeline.lookup(index, "offer", offerKey), native)
end

function timeline.generation(index, generationKey, native)
    return timeline.bind(index, timeline.lookup(index, "generation", generationKey), native)
end

function timeline.phase(index, phaseKey, native)
    return timeline.bind(index, timeline.lookup(index, "phase", phaseKey), native)
end

function timeline.automatic(index, effect, phaseKey, native)
    return timeline.bind(index, timeline.lookup(index, "automatic", effect .. "\0" .. phaseKey), native)
end

function timeline.expectedTrait(row)
    if row == nil then return nil end
    local node, role = row.node, row.detail
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
    lootData.UpgradeOptions = {}
    for index, option in ipairs(offer.options or {}) do
        local optionKey = option.key
        local selected = type(offer.selected) == "string" and tonumber(offer.selected:match("(%d+)$"))
        if row.realizedKey and index == selected then optionKey = row.realizedKey end
        lootData.UpgradeOptions[index] = {
            ItemName = optionKey, Rarity = option.rarity, StackNum = option.effectiveLevel,
            TraitToReplace = option.replacement and option.replacement.replacedTraitKey or nil,
            OldRarity = option.replacement and option.replacement.oldRarity or nil,
        }
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
    local node = row and row.node
    return node ~= nil and (node.kind == "wellPurchase" or node.kind == "wellRefill")
        and node.generationKey == generationKey
        and (row.realizedKey or node.offerKey) == offerKey
        and node.twistResultKey == twistResultKey
end

function timeline.effectiveOfferKey(row)
    return row and (row.realizedKey or row.node and row.node.offerKey) or nil
end

function timeline.verifyPool(row, slotKey, traitKey)
    local node = row and row.node
    return node ~= nil and node.kind == "poolSale"
        and node.slotKey == slotKey and node.traitKey == traitKey
end

function timeline.verifyKeepsake(row, keepsakeKey, equipResults)
    local node = row and row.node
    return node ~= nil and node.kind == "keepsakeChange" and node.keepsakeKey == keepsakeKey
        and (node.equipResults == nil or same(node.equipResults, equipResults))
end

function timeline.verifyFountain(row, target)
    local node = row and row.node
    return node ~= nil and node.kind == "fountainUse" and node.aromaticPhialTarget == target
end

function timeline.verifyAutomatic(row, observed)
    local node = row and row.node
    if node == nil or node.kind ~= "automatic" then return false end
    if node.effect == "steadyGrowth" or node.effect == "transcendentEmbryo" then
        return type(observed) == "table" and observed.target == node.target
            and (node.rarity == nil or observed.rarity == node.rarity)
    end
    if node.effect == "judgment" or node.effect == "crystalFigurine" then
        return type(observed) == "table" and same(observed.arcanaKeys, node.arcanaKeys)
            and observed.rarity == node.rarity
    end
    return false
end

return timeline
