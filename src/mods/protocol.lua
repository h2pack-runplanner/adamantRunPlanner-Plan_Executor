-- Strict decoder for the current Run Planner execution-only protocol.
-- This module accepts resolved facts, not project commands or game policy.

local json = require("mods/json")
local protocol = {}

protocol.FORMAT = "run-planner-execution"
protocol.VERSION = 5
protocol.CATALOG_VERSION = "0.52.0-boss-preboss-variants"
protocol.MAX_STRING = 512
protocol.MAX_ROOMS = 256
protocol.MAX_TRACE = 64
protocol.MAX_TARGETS = 16
protocol.MAX_PHASES = 16
protocol.MAX_OBJECTS = 32
protocol.MAX_BAGS = 64

local function fail(message) return nil, message end

local function object(value, label)
    if not json.isObject(value) then return fail(label .. " must be a JSON object") end
    return value
end

local function array(value, label, maximum)
    if not json.isArray(value) then return fail(label .. " must be a JSON array") end
    if #value > maximum then return fail(label .. " exceeds bound") end
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > #value then
            return fail(label .. " contains a non-contiguous index")
        end
    end
    return value
end

local function keys(value, required, optional, label)
    local checked, errorMessage = object(value, label)
    if not checked then return nil, errorMessage end
    for _, key in ipairs(required) do if value[key] == nil then return fail(label .. " is missing " .. key) end end
    for key in pairs(value) do
        local allowed = false
        for _, requiredKey in ipairs(required) do if key == requiredKey then allowed = true end end
        for _, optionalKey in ipairs(optional or {}) do if key == optionalKey then allowed = true end end
        if not allowed then return fail(label .. " has unknown field " .. tostring(key)) end
    end
    return value
end

local function stringValue(value, label, allowEmpty)
    if type(value) ~= "string" or (not allowEmpty and value == "") or #value > protocol.MAX_STRING then
        return fail(label .. " must be a bounded " .. (allowEmpty and "string" or "non-empty string"))
    end
    return value
end

local function integer(value, label, minimum, maximum)
    if type(value) ~= "number" or value ~= math.floor(value) or value < (minimum or 0) or (maximum and value > maximum) then
        return fail(label .. " must be an integer in range")
    end
    return value
end

local function mapNumbers(value, label)
    local record, errorMessage = object(value, label)
    if not record then return nil, errorMessage end
    local result = {}
    for key, item in pairs(record) do
        local name, nameError = stringValue(key, label .. " key")
        local number, numberError = integer(item, label .. "." .. tostring(key))
        if not name then return nil, nameError end
        if not number then return nil, numberError end
        result[name] = number
    end
    return result
end

local function mapFiniteNumbers(value, label)
    local record, errorMessage = object(value, label)
    if not record then return nil, errorMessage end
    local result = {}
    for key, item in pairs(record) do
        local name, nameError = stringValue(key, label .. " key")
        if not name then return nil, nameError end
        if type(item) ~= "number" or item ~= item or item == math.huge or item == -math.huge then
            return fail(label .. "." .. tostring(key) .. " must be finite")
        end
        result[name] = item
    end
    return result
end

local function strings(value, label, maximum, allowDuplicates)
    local values, valuesError = array(value, label, maximum)
    if not values then return nil, valuesError end
    local result, seen = {}, {}
    for index, item in ipairs(values) do
        local text, textError = stringValue(item, label .. "[" .. index .. "]")
        if not text then return nil, textError end
        if not allowDuplicates and seen[text] then return fail(label .. " has duplicate values") end
        seen[text] = true
        result[index] = text
    end
    return result
end

-- Addresses are serialized semantic tuples.  They are safety references, not
-- an invitation for the executor to reinterpret planner policy.
local function addressParts(value, label)
    local text, textError = stringValue(value, label)
    if not text then return nil, textError end
    local parsed, decodeError = json.decode(text)
    if parsed == nil or not json.isArray(parsed) or #parsed == 0 then
        return fail(label .. " must be a semantic address")
    end
    return parsed
end

local function exactAddressBase(parts, kind, length, context, label)
    if #parts ~= length or parts[1] ~= kind or parts[2] ~= "Underworld" or parts[3] ~= context.biomeKey then
        return fail(label .. " is not a " .. kind .. " address in this room")
    end
    return parts
end

local function occurrenceOwner(context)
    -- These are string-only tuples; spell the canonical JSON form rather than
    -- accepting a look-alike owner.  Occurrence identifiers are compiler-owned
    -- bounded strings, and the plan decoder has already rejected control JSON.
    return '["occurrence","Underworld","' .. context.biomeKey .. '","' .. context.roomId .. '"]'
end

local function validateRoomActionOwner(value, context, actionKey, label)
    local parts, partsError = addressParts(value, label)
    if not parts then return nil, partsError end
    local base, baseError = exactAddressBase(parts, "roomAction", 5, context, label)
    if not base then return nil, baseError end
    if parts[4] ~= context.roomId or parts[5] ~= actionKey then
        return fail(label .. " does not identify its canonical room action")
    end
    return true
end

local function validateEncounterAddress(value, context, label)
    local parts, partsError = addressParts(value, label)
    if not parts then return nil, partsError end
    local base, baseError = exactAddressBase(parts, "encounterPhase", 5, context, label)
    if not base then return nil, baseError end
    local nested, nestedError = keys(parts[4], { "kind", "occurrenceId" }, nil, label .. " occurrence owner")
    if not nested then return nil, nestedError end
    if nested.kind ~= "occurrence" or nested.occurrenceId ~= context.roomId then return fail(label .. " does not belong to this room") end
    local phase, phaseError = stringValue(parts[5], label .. " phase")
    if not phase then return nil, phaseError end
    if context.phases[phase] == nil then return fail(label .. " names an undeclared encounter phase") end
    return phase
end

local function validateSiteAddress(value, context, label)
    local parts, partsError = addressParts(value, label)
    if not parts then return nil, partsError end
    local base, baseError = exactAddressBase(parts, "acquisitionSite", 5, context, label)
    if not base then return nil, baseError end
    local owner, ownerError = stringValue(parts[4], label .. " owner")
    if not owner then return nil, ownerError end
    local ownerParts, ownerPartsError = addressParts(owner, label .. " owner")
    if not ownerParts then return nil, ownerPartsError end
    if ownerParts[1] == "occurrence" then
        if owner ~= occurrenceOwner(context) then return fail(label .. " does not belong to this room") end
    elseif ownerParts[1] == "localReward" then
        local valid, validError = exactAddressBase(ownerParts, "localReward", 6, context, label .. " owner")
        if not valid then return nil, validError end
        if ownerParts[4] ~= context.roomId then return fail(label .. " does not belong to this room") end
        if not stringValue(ownerParts[5], label .. " owner group") or not stringValue(ownerParts[6], label .. " owner slot") then return fail(label .. " local reward invalid") end
    elseif ownerParts[1] == "encounterPhase" then
        local phase, phaseError = validateEncounterAddress(owner, context, label .. " owner")
        if not phase then return nil, phaseError end
    else return fail(label .. " has an unsupported Gate C owner") end
    return stringValue(parts[5], label .. " point")
end

local function validateAcquisitionSource(value, context, label)
    local parts, partsError = addressParts(value, label)
    if not parts then return nil, partsError end
    local kind = parts[1]
    if kind == "incomingReward" then
        local valid, validError = exactAddressBase(parts, kind, 4, context, label)
        if not valid then return nil, validError end
        if parts[4] ~= context.roomId then return fail(label .. " does not belong to this room") end
        return true
    elseif kind == "localReward" then
        local valid, validError = exactAddressBase(parts, kind, 6, context, label)
        if not valid then return nil, validError end
        if parts[4] ~= context.roomId then return fail(label .. " does not belong to this room") end
        local group, groupError = stringValue(parts[5], label .. " group")
        local slot, slotError = stringValue(parts[6], label .. " slot")
        if not group then return nil, groupError end
        if not slot then return nil, slotError end
        return true
    elseif kind == "encounterPhase" then
        return validateEncounterAddress(value, context, label)
    elseif kind == "gorgonPhase" then
        local valid, validError = exactAddressBase(parts, kind, 4, context, label)
        if not valid then return nil, validError end
        local encounter, encounterError = stringValue(parts[4], label .. " encounter")
        if not encounter then return nil, encounterError end
        return validateEncounterAddress(encounter, context, label .. " encounter")
    elseif kind == "acquisitionEntry" then
        local valid, validError = exactAddressBase(parts, kind, 5, context, label)
        if not valid then return nil, validError end
        local site, siteError = stringValue(parts[4], label .. " site")
        if not site then return nil, siteError end
        local siteValid, siteValidError = validateSiteAddress(site, context, label .. " site")
        if not siteValid then return nil, siteValidError end
        return stringValue(parts[5], label .. " entry")
    end
    return fail(label .. " has an unsupported Gate C source")
end

local function parseCount(value, label)
    local count, errorMessage = keys(value, { "kind" }, { "count", "min", "max" }, label)
    if not count then return nil, errorMessage end
    if count.kind == "exact" then
        local exact, exactError = keys(count, { "kind", "count" }, nil, label)
        if not exact then return nil, exactError end
        local number, numberError = integer(exact.count, label .. ".count")
        if not number then return nil, numberError end
        return { kind = "exact", count = number }
    end
    if count.kind == "range" then
        local range, rangeError = keys(count, { "kind", "min", "max" }, nil, label)
        if not range then return nil, rangeError end
        local minimum, minimumError = integer(range.min, label .. ".min")
        if not minimum then return nil, minimumError end
        local maximum, maximumError = integer(range.max, label .. ".max")
        if not maximum then return nil, maximumError end
        if minimum > maximum then return fail(label .. ".min must not exceed max") end
        return { kind = "range", min = minimum, max = maximum }
    end
    return fail(label .. ".kind unsupported")
end

local function parseReward(value, label)
    local reward, errorMessage = keys(value, { "rewardType", "producerLifecycleKey" }, { "resolvedStoreKey", "source", "spurnedSource" }, label)
    if not reward then return nil, errorMessage end
    local rewardType, rewardError = stringValue(reward.rewardType, label .. ".rewardType")
    if not rewardType then return nil, rewardError end
    local producer, producerError = stringValue(reward.producerLifecycleKey, label .. ".producerLifecycleKey")
    if not producer then return nil, producerError end
    local result = { rewardType = rewardType, producerLifecycleKey = producer }
    for _, field in ipairs({ "resolvedStoreKey", "source", "spurnedSource" }) do
        if reward[field] ~= nil then
            local text, textError = stringValue(reward[field], label .. "." .. field)
            if not text then return nil, textError end
            result[field] = text
        end
    end
    return result
end

local function parseDiagnostic(value, label)
    local diagnostic, errorMessage = keys(value, { "owner", "checkpoint", "counters", "bags", "godPool", "traits", "arcana", "vows", "forfeit", "chaos", "keepsakes", "rewardPriorities", "hexProgress", "artificer" }, nil, label)
    if not diagnostic then return nil, errorMessage end
    if diagnostic.checkpoint ~= "roomEntered" and diagnostic.checkpoint ~= "beforeRoomExit" then return fail(label .. ".checkpoint unsupported") end
    local counters, countersError = keys(diagnostic.counters, { "biomeDepthCache", "biomeEncounterDepth", "routeEncounterDepth", "roomHistoryOrdinal" }, nil, label .. ".counters")
    if not counters then return nil, countersError end
    local result = { owner = nil, checkpoint = diagnostic.checkpoint, counters = {}, bags = {} }
    local owner, ownerError = stringValue(diagnostic.owner, label .. ".owner")
    if not owner then return nil, ownerError end
    result.owner = owner
    for _, field in ipairs({ "biomeDepthCache", "biomeEncounterDepth", "routeEncounterDepth", "roomHistoryOrdinal" }) do
        local number, numberError = integer(counters[field], label .. ".counters." .. field)
        if not number then return nil, numberError end
        result.counters[field] = number
    end
    local bags, bagsError = array(diagnostic.bags, label .. ".bags", protocol.MAX_BAGS)
    if not bags then return nil, bagsError end
    local seen = {}
    for index, valueItem in ipairs(bags) do
        local bag, bagError = keys(valueItem, { "storeKey", "remaining" }, nil, label .. ".bags[" .. index .. "]")
        if not bag then return nil, bagError end
        local storeKey, storeError = stringValue(bag.storeKey, label .. ".bags[" .. index .. "].storeKey")
        if not storeKey then return nil, storeError end
        if seen[storeKey] then return fail(label .. ".bags has duplicate stores") end
        seen[storeKey] = true
        local remaining, remainingError = parseCount(bag.remaining, label .. ".bags[" .. index .. "].remaining")
        if not remaining then return nil, remainingError end
        result.bags[index] = { storeKey = storeKey, remaining = remaining }
    end
    local godPool, godPoolError = keys(diagnostic.godPool, { "acquiredSourceKeys", "effectiveSourceKeys", "capNarrowed" }, nil, label .. ".godPool")
    if not godPool then return nil, godPoolError end
    local acquired, acquiredError = strings(godPool.acquiredSourceKeys, label .. ".godPool.acquiredSourceKeys", 32)
    local effective, effectiveError = strings(godPool.effectiveSourceKeys, label .. ".godPool.effectiveSourceKeys", 32)
    if not acquired then return nil, acquiredError end
    if not effective then return nil, effectiveError end
    if type(godPool.capNarrowed) ~= "boolean" then return fail(label .. ".godPool.capNarrowed invalid") end
    result.godPool = { acquiredSourceKeys = acquired, effectiveSourceKeys = effective, capNarrowed = godPool.capNarrowed }
    local traits, traitsError = keys(diagnostic.traits, { "equipped", "slots", "elements", "godRarityCounts", "upgradableCount", "bannedTraitKeys" }, nil, label .. ".traits")
    if not traits then return nil, traitsError end
    local equipped, equippedError = array(traits.equipped, label .. ".traits.equipped", 128)
    if not equipped then return nil, equippedError end
    result.traits = { equipped = {}, slots = {}, elements = nil, godRarityCounts = nil, upgradableCount = nil, bannedTraitKeys = nil }
    local traitSeen = {}
    for index, entry in ipairs(equipped) do
        local trait, traitError = keys(entry, { "traitKey" }, { "rarity", "level", "hammerRank" }, label .. ".traits.equipped[" .. index .. "]")
        if not trait then return nil, traitError end
        local traitKey, traitKeyError = stringValue(trait.traitKey, label .. ".traits.equipped[" .. index .. "].traitKey")
        if not traitKey then return nil, traitKeyError end
        if traitSeen[traitKey] then return fail(label .. ".traits.equipped has duplicate traits") end
        traitSeen[traitKey] = true
        local parsed = { traitKey = traitKey }
        for _, field in ipairs({ "rarity" }) do
            if trait[field] ~= nil then
                local text, textError = stringValue(trait[field], label .. ".traits.equipped[" .. index .. "]." .. field)
                if not text then return nil, textError end
                parsed[field] = text
            end
        end
        if trait.level ~= nil then local number, numberError = integer(trait.level, label .. ".traits.equipped[" .. index .. "].level"); if not number then return nil, numberError end; parsed.level = number end
        if trait.hammerRank ~= nil and trait.hammerRank ~= "RankI" and trait.hammerRank ~= "RankII" then return fail(label .. ".traits.equipped hammer rank unsupported") end
        parsed.hammerRank = trait.hammerRank
        result.traits.equipped[index] = parsed
    end
    local slots, slotsError = array(traits.slots, label .. ".traits.slots", 6)
    if not slots then return nil, slotsError end
    local slotNames = { "Melee", "Secondary", "Ranged", "Rush", "Mana", "Spell" }
    if #slots ~= 6 then return fail(label .. ".traits.slots must contain six entries") end
    for index, entry in ipairs(slots) do
        local slot, slotError = keys(entry, { "slot" }, { "traitKey" }, label .. ".traits.slots[" .. index .. "]")
        if not slot then return nil, slotError end
        if slot.slot ~= slotNames[index] then return fail(label .. ".traits.slots order invalid") end
        local parsed = { slot = slot.slot }
        if slot.traitKey ~= nil then local text, textError = stringValue(slot.traitKey, label .. ".traits.slots[" .. index .. "].traitKey"); if not text then return nil, textError end; parsed.traitKey = text end
        result.traits.slots[index] = parsed
    end
    local elements, elementsError = mapNumbers(traits.elements, label .. ".traits.elements")
    if not elements then return nil, elementsError end
    result.traits.elements = elements
    local godRarityCounts, godRarityCountsError = mapNumbers(traits.godRarityCounts, label .. ".traits.godRarityCounts")
    if not godRarityCounts then return nil, godRarityCountsError end
    result.traits.godRarityCounts = godRarityCounts
    local upgradeCount, upgradeError = integer(traits.upgradableCount, label .. ".traits.upgradableCount")
    if not upgradeCount then return nil, upgradeError end
    result.traits.upgradableCount = upgradeCount
    local bannedTraitKeys, bannedTraitKeysError = strings(traits.bannedTraitKeys, label .. ".traits.bannedTraitKeys", 128)
    if not bannedTraitKeys then return nil, bannedTraitKeysError end
    result.traits.bannedTraitKeys = bannedTraitKeys
    local chaos, chaosError = keys(diagnostic.chaos, { "active", "matured" }, nil, label .. ".chaos")
    if not chaos then return nil, chaosError end
    local activeChaos, activeChaosError = array(chaos.active, label .. ".chaos.active", 32)
    local maturedChaos, maturedChaosError = array(chaos.matured, label .. ".chaos.matured", 32)
    if not activeChaos then return nil, activeChaosError end
    if not maturedChaos then return nil, maturedChaosError end
    result.chaos = { active = {}, matured = {} }
    for index, entry in ipairs(activeChaos) do
        local item, itemError = keys(entry, { "curseKey", "blessingKey", "rarity", "clock", "remaining" }, nil, label .. ".chaos.active[" .. index .. "]")
        if not item then return nil, itemError end
        if item.clock ~= "encounters" and item.clock ~= "locations" and item.clock ~= "godBoonScreens" then return fail(label .. ".chaos.active clock unsupported") end
        local remaining, remainingError = integer(item.remaining, label .. ".chaos.active remaining")
        if not remaining then return nil, remainingError end
        local curseKey, curseKeyError = stringValue(item.curseKey, label .. ".chaos.active curseKey")
        local blessingKey, blessingKeyError = stringValue(item.blessingKey, label .. ".chaos.active blessingKey")
        local rarity, rarityError = stringValue(item.rarity, label .. ".chaos.active rarity")
        if not curseKey then return nil, curseKeyError end; if not blessingKey then return nil, blessingKeyError end; if not rarity then return nil, rarityError end
        result.chaos.active[index] = { curseKey = curseKey, blessingKey = blessingKey, rarity = rarity, clock = item.clock, remaining = remaining }
    end
    for index, entry in ipairs(maturedChaos) do
        local item, itemError = keys(entry, { "blessingKey", "rarity" }, nil, label .. ".chaos.matured[" .. index .. "]")
        if not item then return nil, itemError end
        local blessingKey, blessingKeyError = stringValue(item.blessingKey, label .. ".chaos.matured blessingKey")
        local rarity, rarityError = stringValue(item.rarity, label .. ".chaos.matured rarity")
        if not blessingKey then return nil, blessingKeyError end; if not rarity then return nil, rarityError end
        result.chaos.matured[index] = { blessingKey = blessingKey, rarity = rarity }
    end
    local arcana, arcanaError = keys(diagnostic.arcana, { "active" }, nil, label .. ".arcana")
    if not arcana then return nil, arcanaError end
    local active, activeError = array(arcana.active, label .. ".arcana.active", 32)
    if not active then return nil, activeError end
    result.arcana = { active = {} }
    for index, entry in ipairs(active) do
        local card, cardError = keys(entry, { "key", "origin", "rarity" }, nil, label .. ".arcana.active[" .. index .. "]")
        if not card then return nil, cardError end
        if card.origin ~= "manual" and card.origin ~= "automatic" and card.origin ~= "temporary" then return fail(label .. ".arcana origin unsupported") end
        if card.rarity ~= "Common" and card.rarity ~= "Rare" and card.rarity ~= "Epic" and card.rarity ~= "Heroic" then return fail(label .. ".arcana rarity unsupported") end
        local key, keyError = stringValue(card.key, label .. ".arcana.active[" .. index .. "].key")
        if not key then return nil, keyError end
        result.arcana.active[index] = { key = key, origin = card.origin, rarity = card.rarity }
    end
    local vows, vowsError = keys(diagnostic.vows, { "configuredRanks", "effectiveRanks", "disabledKeys" }, nil, label .. ".vows")
    if not vows then return nil, vowsError end
    local configured, configuredError = mapNumbers(vows.configuredRanks, label .. ".vows.configuredRanks")
    local effectiveRanks, effectiveError = mapNumbers(vows.effectiveRanks, label .. ".vows.effectiveRanks")
    local disabled, disabledError = strings(vows.disabledKeys, label .. ".vows.disabledKeys", 128)
    if not configured then return nil, configuredError end
    if not effectiveRanks then return nil, effectiveError end
    if not disabled then return nil, disabledError end
    if diagnostic.forfeit ~= "inactive" and diagnostic.forfeit ~= "available" and diagnostic.forfeit ~= "consumed" then return fail(label .. ".forfeit unsupported") end
    result.vows = { configuredRanks = configured, effectiveRanks = effectiveRanks, disabledKeys = disabled }
    result.forfeit = diagnostic.forfeit
    local keepsakes, keepsakesError = keys(diagnostic.keepsakes, { "currentKey", "usedKeys", "blockedKeys", "fatedStatus" }, nil, label .. ".keepsakes")
    if not keepsakes then return nil, keepsakesError end
    local currentKey, currentKeyError = stringValue(keepsakes.currentKey, label .. ".keepsakes.currentKey")
    local used, usedError = strings(keepsakes.usedKeys, label .. ".keepsakes.usedKeys", 16)
    local blocked, blockedError = strings(keepsakes.blockedKeys, label .. ".keepsakes.blockedKeys", 32)
    if not currentKey then return nil, currentKeyError end; if not used then return nil, usedError end; if not blocked then return nil, blockedError end
    if keepsakes.fatedStatus ~= "Unknown" and keepsakes.fatedStatus ~= "Fated" and keepsakes.fatedStatus ~= "Unfated" then return fail(label .. ".keepsakes.fatedStatus unsupported") end
    result.keepsakes = { currentKey = currentKey, usedKeys = used, blockedKeys = blocked, fatedStatus = keepsakes.fatedStatus }
    result.rewardPriorities, errorMessage = strings(diagnostic.rewardPriorities, label .. ".rewardPriorities", 32, true)
    if not result.rewardPriorities then return nil, errorMessage end
    local hex, hexError = keys(diagnostic.hexProgress, { "talentKeys", "closed", "bankedPathPoints", "investedPathPoints" }, { "spellTraitKey", "layoutKey" }, label .. ".hexProgress")
    if not hex then return nil, hexError end
    local banked, bankedError = integer(hex.bankedPathPoints, label .. ".hexProgress.bankedPathPoints")
    local invested, investedError = integer(hex.investedPathPoints, label .. ".hexProgress.investedPathPoints")
    local talentKeys, talentKeysError = strings(hex.talentKeys, label .. ".hexProgress.talentKeys", 16)
    if not banked then return nil, bankedError end; if not invested then return nil, investedError end; if not talentKeys then return nil, talentKeysError end
    if type(hex.closed) ~= "boolean" then return fail(label .. ".hexProgress.closed invalid") end
    result.hexProgress = { talentKeys = talentKeys, closed = hex.closed, bankedPathPoints = banked, investedPathPoints = invested }
    if hex.spellTraitKey ~= nil then local text, textError = stringValue(hex.spellTraitKey, label .. ".hexProgress.spellTraitKey"); if not text then return nil, textError end; result.hexProgress.spellTraitKey = text end
    if hex.layoutKey ~= nil then local text, textError = stringValue(hex.layoutKey, label .. ".hexProgress.layoutKey"); if not text then return nil, textError end; result.hexProgress.layoutKey = text end
    if json.isNull(diagnostic.artificer) then
        result.artificer = nil
    else
        local artificer, artificerError = keys(diagnostic.artificer, { "usedCount", "remainingCount" }, nil, label .. ".artificer")
        if not artificer then return nil, artificerError end
        local usedCount, usedCountError = integer(artificer.usedCount, label .. ".artificer.usedCount")
        local remaining, remainingError = integer(artificer.remainingCount, label .. ".artificer.remainingCount")
        if not usedCount then return nil, usedCountError end; if not remaining then return nil, remainingError end
        result.artificer = { usedCount = usedCount, remainingCount = remaining }
    end
    return result
end

local function parseTraitOffer(value, label)
    local offer, offerError = object(value, label)
    if not offer then return nil, offerError end
    if offer.kind == "fallbackGold" then
        local checked, checkedError = keys(offer, { "kind", "giver" }, nil, label)
        if not checked then return nil, checkedError end
        local giver, giverError = stringValue(offer.giver, label .. ".giver")
        if not giver then return nil, giverError end
        return { kind = "fallbackGold", giver = giver }
    end
    if offer.kind == "chaos" then
        local checked, checkedError = keys(offer, { "kind", "giver", "curseOptions", "selected", "selectedCurseValues", "blessingKey", "rarity", "blessingValues" }, nil, label)
        if not checked then return nil, checkedError end
        if offer.giver ~= "Chaos" then return fail(label .. ".giver must be Chaos") end
        local options, optionsError = array(offer.curseOptions, label .. ".curseOptions", 3)
        if not options then return nil, optionsError end
        if #options ~= 3 then return fail(label .. ".curseOptions must contain three ordered curses") end
        local result = { kind = "chaos", giver = "Chaos", curseOptions = {} }
        for index, entry in ipairs(options) do
            local option, optionError = keys(entry, { "curseKey", "requirementCount" }, nil, label .. ".curseOptions[" .. index .. "]")
            if not option then return nil, optionError end
            local curseKey, curseKeyError = stringValue(option.curseKey, label .. ".curseOptions curseKey")
            local requirementCount, requirementCountError = integer(
                option.requirementCount,
                label .. ".curseOptions requirementCount",
                1
            )
            if not curseKey then return nil, curseKeyError end; if not requirementCount then return nil, requirementCountError end
            result.curseOptions[index] = { curseKey = curseKey, requirementCount = requirementCount }
        end
        local selected, selectedError = stringValue(offer.selected, label .. ".selected")
        if not selected then return nil, selectedError end
        if not selected:match("^option[1-3]$") then return fail(label .. ".selected invalid") end
        local curseValues, curseValuesError = mapFiniteNumbers(offer.selectedCurseValues, label .. ".selectedCurseValues")
        local blessingValues, blessingValuesError = mapFiniteNumbers(offer.blessingValues, label .. ".blessingValues")
        local blessingKey, blessingKeyError = stringValue(offer.blessingKey, label .. ".blessingKey")
        local rarity, rarityError = stringValue(offer.rarity, label .. ".rarity")
        if not curseValues then return nil, curseValuesError end; if not blessingValues then return nil, blessingValuesError end
        if not blessingKey then return nil, blessingKeyError end; if not rarity then return nil, rarityError end
        result.selected, result.selectedCurseValues, result.blessingKey, result.rarity, result.blessingValues = selected, curseValues, blessingKey, rarity, blessingValues
        return result
    end
    local checked, checkedError = keys(offer, { "kind", "giver", "options", "selected" }, { "rejected", "runtimeFallback" }, label)
    if not checked then return nil, checkedError end
    if offer.kind ~= "traits" then return fail(label .. ".kind unsupported") end
    local options, optionsError = array(offer.options, label .. ".options", 3)
    if not options then return nil, optionsError end
    if #options == 0 then return fail(label .. ".options cannot be empty") end
    local result, seen = { kind = "traits", giver = nil, options = {}, selected = nil }, {}
    result.giver, offerError = stringValue(offer.giver, label .. ".giver")
    if not result.giver then return nil, offerError end
    for index, entry in ipairs(options) do
        local option, optionError = keys(entry, { "key" }, { "rarity", "effectiveLevel", "replacement" }, label .. ".options[" .. index .. "]")
        if not option then return nil, optionError end
        local key, keyError = stringValue(option.key, label .. ".options[" .. index .. "].key")
        if not key then return nil, keyError end
        if seen[key] then return fail(label .. ".options has duplicate trait identities") end
        seen[key] = true
        local parsed = { key = key }
        if option.rarity ~= nil then local text, textError = stringValue(option.rarity, label .. ".options[" .. index .. "].rarity"); if not text then return nil, textError end; parsed.rarity = text end
        if option.effectiveLevel ~= nil then local number, numberError = integer(option.effectiveLevel, label .. ".options[" .. index .. "].effectiveLevel"); if not number then return nil, numberError end; parsed.effectiveLevel = number end
        if option.replacement ~= nil then
            local replacement, replacementError = keys(option.replacement, { "slot", "replacedTraitKey", "oldRarity", "newTraitKey", "requiredRarity" }, { "levelBonus" }, label .. ".options[" .. index .. "].replacement")
            if not replacement then return nil, replacementError end
            parsed.replacement = {}
            for _, field in ipairs({ "slot", "replacedTraitKey", "oldRarity", "newTraitKey", "requiredRarity" }) do
                local text, textError = stringValue(replacement[field], label .. ".options[" .. index .. "].replacement." .. field)
                if not text then return nil, textError end
                parsed.replacement[field] = text
            end
            if replacement.levelBonus ~= nil then local number, numberError = integer(replacement.levelBonus, label .. ".options[" .. index .. "].replacement.levelBonus"); if not number then return nil, numberError end; parsed.replacement.levelBonus = number end
        end
        result.options[index] = parsed
    end
    local selected, selectedError = stringValue(offer.selected, label .. ".selected")
    if not selected then return nil, selectedError end
    local valid = "option" .. tostring(#result.options)
    if not selected:match("^option[1-3]$") or tonumber(selected:sub(7)) > #result.options then return fail(label .. ".selected must identify a declared option") end
    result.selected = selected
    if offer.rejected ~= nil then
        local rejected, rejectedError = stringValue(offer.rejected, label .. ".rejected")
        if not rejected then return nil, rejectedError end
        if rejected == selected or not rejected:match("^option[1-3]$") or tonumber(rejected:sub(7)) > #result.options then return fail(label .. ".rejected invalid") end
        result.rejected = rejected
    end
    if offer.runtimeFallback ~= nil then local text, textError = stringValue(offer.runtimeFallback, label .. ".runtimeFallback"); if not text then return nil, textError end; result.runtimeFallback = text end
    return result
end

local function parseRole(value, label)
    local role, roleError = keys(value, { "role", "disposition", "lifecyclePoint", "kind", "gameName" }, { "settlement", "producer", "traitOffer", "levelResolution" }, label)
    if not role then return nil, roleError end
    local result = {}
    for _, field in ipairs({ "role", "lifecyclePoint", "kind", "gameName" }) do local text, textError = stringValue(role[field], label .. "." .. field); if not text then return nil, textError end; result[field] = text end
    if role.disposition ~= "normal" and role.disposition ~= "timePiece" and role.disposition ~= "artificer" then return fail(label .. ".disposition unsupported") end
    result.disposition = role.disposition
    if role.producer ~= nil then
        local producer, producerError = object(role.producer, label .. ".producer")
        if not producer then return nil, producerError end
        if producer.kind == "seaStarDuplicate" or producer.kind == "artificerReplacement" or producer.kind == "echoLastReward" then
            local checked, checkedError = keys(producer, { "kind", "sourceOwner", "sourceRole" }, nil, label .. ".producer")
            if not checked then return nil, checkedError end
            local source, sourceError = stringValue(producer.sourceOwner, label .. ".producer.sourceOwner")
            local sourceRole, sourceRoleError = stringValue(producer.sourceRole, label .. ".producer.sourceRole")
            if not source then return nil, sourceError end
            if not sourceRole then return nil, sourceRoleError end
            result.producer = { kind = producer.kind, sourceOwner = source, sourceRole = sourceRole }
        else return fail(label .. ".producer.kind unsupported") end
    end
    if role.settlement ~= nil then
        local settlement, settlementError = keys(role.settlement, { "site", "entry" }, nil, label .. ".settlement")
        if not settlement then return nil, settlementError end
        local site, siteError = stringValue(settlement.site, label .. ".settlement.site")
        local entry, entryError = stringValue(settlement.entry, label .. ".settlement.entry")
        if not site then return nil, siteError end
        if not entry then return nil, entryError end
        result.settlement = { site = site, entry = entry }
    end
    if role.traitOffer ~= nil then local offer, offerError = parseTraitOffer(role.traitOffer, label .. ".traitOffer"); if not offer then return nil, offerError end; result.traitOffer = offer end
    if role.levelResolution ~= nil then
        local level, levelError = keys(role.levelResolution, { "offeredTargets", "selectedTarget", "levelCount" }, nil, label .. ".levelResolution")
        if not level then return nil, levelError end
        local targets, targetsError = strings(level.offeredTargets, label .. ".levelResolution.offeredTargets", 64)
        local count, countError = integer(level.levelCount, label .. ".levelResolution.levelCount")
        if not targets then return nil, targetsError end
        if not count then return nil, countError end
        if level.selectedTarget ~= nil and type(level.selectedTarget) ~= "string" then return fail(label .. ".levelResolution.selectedTarget invalid") end
        if level.selectedTarget ~= nil then
            local found = false; for _, target in ipairs(targets) do if target == level.selectedTarget then found = true end end
            if not found then return fail(label .. ".levelResolution selected target was not offered") end
        end
        result.levelResolution = { offeredTargets = targets, selectedTarget = level.selectedTarget, levelCount = count }
    end
    return result
end

local function parseRoom(value, index)
    local label = "rooms[" .. index .. "]"
    local room, errorMessage = keys(value, { "id", "owner", "biomeKey", "gameName", "kind", "entered", "contents", "trace", "outgoing" }, nil, label)
    if not room then return nil, errorMessage end
    local result = {}
    for _, field in ipairs({ "id", "owner", "biomeKey", "gameName", "kind" }) do
        local text, textError = stringValue(room[field], label .. "." .. field)
        if not text then return nil, textError end
        result[field] = text
    end
    local context = { roomId = result.id, biomeKey = result.biomeKey, phases = {} }
    if result.owner ~= occurrenceOwner(context) then return fail(label .. ".owner does not identify this occurrence") end
    if type(room.entered) ~= "boolean" then return fail(label .. ".entered invalid") end
    result.entered = room.entered
    local contents, contentsError = keys(room.contents, { "encounterPhases", "requiredObjects" }, { "incomingReward", "shop", "stygianWell", "purgingPool", "keepsakeRack", "fountain", "resources" }, label .. ".contents")
    if not contents then return nil, contentsError end
    result.contents = { encounterPhases = {}, requiredObjects = {} }
    if contents.incomingReward ~= nil then
        local reward, rewardError = parseReward(contents.incomingReward, label .. ".contents.incomingReward")
        if not reward then return nil, rewardError end
        result.contents.incomingReward = reward
    end
    if contents.shop ~= nil then
        local shop, shopError = keys(contents.shop, { "profileKey", "offers" }, { "travelDealRefill" }, label .. ".contents.shop")
        if not shop then return nil, shopError end
        local profile, profileError = stringValue(shop.profileKey, label .. ".contents.shop.profileKey")
        local offers, offersError = array(shop.offers, label .. ".contents.shop.offers", protocol.MAX_TARGETS)
        if not profile then return nil, profileError end; if not offers then return nil, offersError end
        result.contents.shop = { profileKey = profile, offers = {} }
        local seen = {}
        for offerIndex, valueOffer in ipairs(offers) do
            local offer, offerError = keys(valueOffer, { "offerKey", "optionKey", "rewardType" }, { "source", "spurnedSource" }, label .. ".contents.shop.offers[" .. offerIndex .. "]")
            if not offer then return nil, offerError end
            local key, keyError = stringValue(offer.offerKey, label .. ".contents.shop.offers[" .. offerIndex .. "].offerKey")
            local optionKey, optionKeyError = stringValue(offer.optionKey, label .. ".contents.shop.offers[" .. offerIndex .. "].optionKey")
            local rewardType, rewardTypeError = stringValue(offer.rewardType, label .. ".contents.shop.offers[" .. offerIndex .. "].rewardType")
            if not key then return nil, keyError end; if not optionKey then return nil, optionKeyError end; if not rewardType then return nil, rewardTypeError end
            if seen[key] then return fail(label .. ".contents.shop.offers has duplicate keys") end; seen[key] = true
            local parsed = { offerKey = key, optionKey = optionKey, rewardType = rewardType }
            for _, field in ipairs({ "source", "spurnedSource" }) do if offer[field] ~= nil then local text, textError = stringValue(offer[field], label .. ".contents.shop.offers[" .. offerIndex .. "]." .. field); if not text then return nil, textError end; parsed[field] = text end end
            result.contents.shop.offers[offerIndex] = parsed
        end
        if shop.travelDealRefill ~= nil then
            local refill, refillError = keys(shop.travelDealRefill, { "sourceOfferKey", "slotIndex", "optionKey", "reward" }, nil, label .. ".contents.shop.travelDealRefill")
            if not refill then return nil, refillError end
            local sourceOfferKey, sourceError = stringValue(refill.sourceOfferKey, label .. ".contents.shop.travelDealRefill.sourceOfferKey")
            local slotIndex = refill.slotIndex
            local optionKey, optionError = stringValue(refill.optionKey, label .. ".contents.shop.travelDealRefill.optionKey")
            local reward, rewardError = parseReward(refill.reward, label .. ".contents.shop.travelDealRefill.reward")
            if not sourceOfferKey then return nil, sourceError end
            if type(slotIndex) ~= "number" or slotIndex % 1 ~= 0 or slotIndex < 0 or slotIndex >= #result.contents.shop.offers then return fail(label .. ".contents.shop.travelDealRefill.slotIndex invalid") end
            if not optionKey then return nil, optionError end
            if not reward then return nil, rewardError end
            local sourceOffer = result.contents.shop.offers[slotIndex + 1]
            if sourceOffer == nil or sourceOffer.offerKey ~= sourceOfferKey then return fail(label .. ".contents.shop.travelDealRefill source slot does not close inventory") end
            result.contents.shop.travelDealRefill = { sourceOfferKey = sourceOfferKey, slotIndex = slotIndex, optionKey = optionKey, reward = reward }
        end
    end
    if contents.stygianWell ~= nil then
        local well, wellError = keys(contents.stygianWell, { "offers" }, nil, label .. ".contents.stygianWell")
        if not well then return nil, wellError end
        local offers, offersError = array(well.offers, label .. ".contents.stygianWell.offers", 4)
        if not offers then return nil, offersError end
        local allowed = { ["initial:healing"] = true, ["initial:secondLeft"] = true, ["initial:secondRight"] = true, ["travelDealRefill"] = true }
        result.contents.stygianWell = { offers = {} }
        local seen = {}
        for offerIndex, valueOffer in ipairs(offers) do
            local offer, offerError = keys(valueOffer, { "generationKey", "offerKey" }, { "twistResultKey" }, label .. ".contents.stygianWell.offers[" .. offerIndex .. "]")
            if not offer then return nil, offerError end
            if allowed[offer.generationKey] ~= true then return fail(label .. ".contents.stygianWell generation unsupported") end
            local offerKey, offerKeyError = stringValue(offer.offerKey, label .. ".contents.stygianWell.offers[" .. offerIndex .. "].offerKey")
            if not offerKey then return nil, offerKeyError end
            if seen[offer.generationKey] then return fail(label .. ".contents.stygianWell has duplicate generations") end; seen[offer.generationKey] = true
            local parsed = { generationKey = offer.generationKey, offerKey = offerKey }
            if offer.twistResultKey ~= nil then local twist, twistError = stringValue(offer.twistResultKey, label .. ".contents.stygianWell.offers[" .. offerIndex .. "].twistResultKey"); if not twist then return nil, twistError end; parsed.twistResultKey = twist end
            result.contents.stygianWell.offers[offerIndex] = parsed
        end
    end
    if contents.purgingPool ~= nil then
        local pool, poolError = keys(contents.purgingPool, { "traits" }, nil, label .. ".contents.purgingPool")
        if not pool then return nil, poolError end
        local traits = array(pool.traits, label .. ".contents.purgingPool.traits", 3)
        if not traits or #traits ~= 3 then return fail(label .. ".contents.purgingPool requires three canonical slots") end
        result.contents.purgingPool = { traits = {} }
        local expectedSlots = { "left", "middle", "right" }
        for traitIndex, valueTrait in ipairs(traits) do
            local trait, traitError = keys(valueTrait, { "slotKey", "traitKey" }, nil, label .. ".contents.purgingPool.traits[" .. traitIndex .. "]")
            if not trait then return nil, traitError end
            if trait.slotKey ~= expectedSlots[traitIndex] then return fail(label .. ".contents.purgingPool slot order invalid") end
            if trait.traitKey ~= nil and type(trait.traitKey) ~= "string" then return fail(label .. ".contents.purgingPool trait invalid") end
            result.contents.purgingPool.traits[traitIndex] = { slotKey = trait.slotKey, traitKey = trait.traitKey }
        end
    end
    if contents.keepsakeRack ~= nil then
        local rack, rackError = keys(contents.keepsakeRack, { "keepsakeKey" }, nil, label .. ".contents.keepsakeRack")
        if not rack then return nil, rackError end
        local key, keyError = stringValue(rack.keepsakeKey, label .. ".contents.keepsakeRack.keepsakeKey")
        if not key then return nil, keyError end; result.contents.keepsakeRack = { keepsakeKey = key }
    end
    if contents.fountain ~= nil then
        local fountain, fountainError = keys(contents.fountain, {}, { "aromaticPhialTarget" }, label .. ".contents.fountain")
        if not fountain then return nil, fountainError end
        result.contents.fountain = {}
        if fountain.aromaticPhialTarget ~= nil then local target, targetError = stringValue(fountain.aromaticPhialTarget, label .. ".contents.fountain.aromaticPhialTarget"); if not target then return nil, targetError end; result.contents.fountain.aromaticPhialTarget = target end
    end
    if contents.resources ~= nil then
        local resources, resourcesError = array(contents.resources, label .. ".contents.resources", 4)
        if not resources then return nil, resourcesError end
        result.contents.resources = {}
        local seen = {}
        for resourceIndex, valueResource in ipairs(resources) do
            local resource, resourceError = keys(valueResource, { "acquisitionRole", "grantedTraitKey", "contributions" }, nil, label .. ".contents.resources[" .. resourceIndex .. "]")
            if not resource then return nil, resourceError end
            local role, roleError = stringValue(resource.acquisitionRole, label .. ".contents.resources[" .. resourceIndex .. "].acquisitionRole")
            local traitKey, traitError = stringValue(resource.grantedTraitKey, label .. ".contents.resources[" .. resourceIndex .. "].grantedTraitKey")
            local contributions, contributionError = mapNumbers(resource.contributions, label .. ".contents.resources[" .. resourceIndex .. "].contributions")
            if not role then return nil, roleError end
            if not traitKey then return nil, traitError end
            if not contributions then return nil, contributionError end
            if role ~= "resource:" .. traitKey then return fail(label .. ".contents.resources acquisition role must match granted trait") end
            if seen[role] then return fail(label .. ".contents.resources has duplicate acquisition roles") end
            seen[role] = true
            result.contents.resources[resourceIndex] = { acquisitionRole = role, grantedTraitKey = traitKey, contributions = contributions }
        end
    end
    local phases, phasesError = array(contents.encounterPhases, label .. ".contents.encounterPhases", protocol.MAX_PHASES)
    if not phases then return nil, phasesError end
    for phaseIndex, valuePhase in ipairs(phases) do
        local phase, phaseError = keys(valuePhase, { "slotKey", "encounterKey", "kind" }, nil, label .. ".contents.encounterPhases[" .. phaseIndex .. "]")
        if not phase then return nil, phaseError end
        local slot, slotError = stringValue(phase.slotKey, label .. ".contents.encounterPhases[" .. phaseIndex .. "].slotKey")
        if not slot then return nil, slotError end
        local encounter, encounterError = stringValue(phase.encounterKey, label .. ".contents.encounterPhases[" .. phaseIndex .. "].encounterKey")
        if not encounter then return nil, encounterError end
        local kind, kindError = stringValue(phase.kind, label .. ".contents.encounterPhases[" .. phaseIndex .. "].kind")
        if not kind then return nil, kindError end
        result.contents.encounterPhases[phaseIndex] = { slotKey = slot, encounterKey = encounter, kind = kind }
    end
    local objects, objectsError = array(contents.requiredObjects, label .. ".contents.requiredObjects", protocol.MAX_OBJECTS)
    if not objects then return nil, objectsError end
    for objectIndex, valueObject in ipairs(objects) do
        local objectKey, objectError = stringValue(valueObject, label .. ".contents.requiredObjects[" .. objectIndex .. "]")
        if not objectKey then return nil, objectError end
        result.contents.requiredObjects[objectIndex] = objectKey
    end
    local trace, traceError = array(room.trace, label .. ".trace", protocol.MAX_TRACE)
    if not trace then return nil, traceError end
    if room.entered and #trace == 0 then return fail(label .. ".trace cannot be empty for entered room") end
    if not room.entered and #trace ~= 0 then return fail(label .. ".trace cannot exist for an unentered room") end
    result.trace = {}
    local phasesByKey = {}
    for _, phase in ipairs(result.contents.encounterPhases) do
        if phasesByKey[phase.slotKey] ~= nil then return fail(label .. ".contents.encounterPhases has duplicate slots") end
        phasesByKey[phase.slotKey] = phase
    end
    context.phases = phasesByKey
    for traceIndex, valueStep in ipairs(trace) do
        local step, stepError = object(valueStep, label .. ".trace[" .. traceIndex .. "]")
        if not step then return nil, stepError end
        local id, idError = stringValue(step.id, label .. ".trace[" .. traceIndex .. "].id")
        local owner, ownerError = stringValue(step.owner, label .. ".trace[" .. traceIndex .. "].owner")
        if not id then return nil, idError end; if not owner then return nil, ownerError end
        local parsed = { id = id, kind = step.kind, owner = owner }
        if step.kind == "roomEntered" or step.kind == "beforeRoomExit" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "runState" }, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            if owner ~= result.owner then return fail(label .. ".trace owner mismatch") end
            local state, stateError = parseDiagnostic(step.runState, label .. ".trace[" .. traceIndex .. "].runState")
            if not state then return nil, stateError end
            if state.checkpoint ~= step.kind then return fail(label .. ".trace runState checkpoint mismatch") end
            local expectedOwner = '["roomRunStateCheckpoint","Underworld","' .. context.biomeKey .. '","' .. context.roomId .. '","' .. step.kind .. '"]'
            if state.owner ~= expectedOwner then return fail(label .. ".trace runState owner mismatch") end
            parsed.checkpoint, parsed.runState = step.kind, state
        elseif step.kind == "cleanup" then
            local checked, checkedError = keys(step, { "id", "kind", "owner" }, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end; if owner ~= result.owner then return fail(label .. ".trace owner mismatch") end
        elseif step.kind == "encounterStart" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "phase", "encounter", "encounterKind" }, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            local phase, phaseError = stringValue(step.phase, label .. ".trace phase")
            if not phase then return nil, phaseError end
            local declared = phasesByKey[phase]
            if owner ~= result.owner or not declared or declared.encounterKey ~= step.encounter or declared.kind ~= step.encounterKind then return fail(label .. ".trace encounter phase mismatch") end
            parsed.phase, parsed.encounter, parsed.encounterKind = phase, step.encounter, step.encounterKind
        elseif step.kind == "encounterEnd" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "phase", "endEffectsExpected" }, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            if owner ~= result.owner or not phasesByKey[step.phase] or type(step.endEffectsExpected) ~= "boolean" then return fail(label .. ".trace encounter end mismatch") end
            parsed.phase, parsed.endEffectsExpected = step.phase, step.endEffectsExpected
        elseif step.kind == "encounterInteraction" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "phaseKey" }, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            local phase, phaseError = stringValue(step.phaseKey, label .. ".trace phaseKey")
            if not phase then return nil, phaseError end
            local ownerPhase, ownerPhaseError = validateEncounterAddress(owner, context, label .. ".trace owner")
            if not ownerPhase then return nil, ownerPhaseError end
            if ownerPhase ~= phase then return fail(label .. ".trace encounter interaction mismatch") end
            parsed.phaseKey = phase
        elseif step.kind == "steadyGrowth" or step.kind == "transcendentEmbryo" then
            local required = step.kind == "steadyGrowth" and { "id", "kind", "owner", "phase", "source", "target" } or { "id", "kind", "owner", "phase", "source", "target", "rarity" }
            local checked, checkedError = keys(step, required, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            if owner ~= result.owner or not phasesByKey[step.phase] then return fail(label .. ".trace automatic phase mismatch") end
            for _, field in ipairs({ "phase", "source", "target", "rarity" }) do if step[field] ~= nil then local text, textError = stringValue(step[field], label .. ".trace " .. field); if not text then return nil, textError end; parsed[field] = text end end
        elseif step.kind == "stygianWellPurchase" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "generationKey", "offerKey" }, { "twistResultKey" }, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            local actionKey = json.encode({ "purchaseStygianWellOffer", step.generationKey })
            local valid, validError = validateRoomActionOwner(owner, context, actionKey, label .. ".trace owner")
            if not valid then return nil, validError end
            local allowed = { ["initial:healing"] = true, ["initial:secondLeft"] = true, ["initial:secondRight"] = true, ["travelDealRefill"] = true }
            if allowed[step.generationKey] ~= true then return fail(label .. ".trace Well generation unsupported") end
            local offerKey, offerError = stringValue(step.offerKey, label .. ".trace Well offerKey")
            if not offerKey then return nil, offerError end
            local inventory = result.contents.stygianWell and result.contents.stygianWell.offers or {}
            local found
            for _, offer in ipairs(inventory) do if offer.generationKey == step.generationKey then found = offer end end
            if found == nil or found.offerKey ~= offerKey then return fail(label .. ".trace Well purchase does not close inventory") end
            parsed.generationKey, parsed.offerKey = step.generationKey, offerKey
            if step.twistResultKey ~= nil then local twist, twistError = stringValue(step.twistResultKey, label .. ".trace Well twistResultKey"); if not twist then return nil, twistError end; if found.twistResultKey ~= twist then return fail(label .. ".trace Well twist does not close inventory") end; parsed.twistResultKey = twist end
        elseif step.kind == "worldShopPurchase" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "offerKey", "rewardType" }, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            local offerKey, offerError = stringValue(step.offerKey, label .. ".trace World Shop offerKey")
            local rewardType, rewardError = stringValue(step.rewardType, label .. ".trace World Shop rewardType")
            if not offerKey then return nil, offerError end; if not rewardType then return nil, rewardError end
            local actionKey = json.encode({ "interactShopOffer", offerKey })
            local valid, validError = validateRoomActionOwner(owner, context, actionKey, label .. ".trace owner")
            if not valid then return nil, validError end
            local found
            for _, offer in ipairs(result.contents.shop and result.contents.shop.offers or {}) do if offer.offerKey == offerKey then found = offer end end
            if found == nil or found.rewardType ~= rewardType then return fail(label .. ".trace World Shop purchase does not close inventory") end
            parsed.offerKey, parsed.rewardType = offerKey, rewardType
        elseif step.kind == "purgingPoolSale" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "slotKey", "traitKey" }, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            local traitKey, traitError = stringValue(step.traitKey, label .. ".trace Pool traitKey")
            if not traitKey then return nil, traitError end
            if step.slotKey ~= "left" and step.slotKey ~= "middle" and step.slotKey ~= "right" then return fail(label .. ".trace Pool slot unsupported") end
            local actionKey = json.encode({ "sellPurgingPoolTrait", step.slotKey })
            local valid, validError = validateRoomActionOwner(owner, context, actionKey, label .. ".trace owner")
            if not valid then return nil, validError end
            local expected
            for _, trait in ipairs(result.contents.purgingPool and result.contents.purgingPool.traits or {}) do if trait.slotKey == step.slotKey then expected = trait.traitKey end end
            if expected == nil or expected ~= traitKey then return fail(label .. ".trace Pool sale does not close inventory") end
            parsed.slotKey, parsed.traitKey = step.slotKey, traitKey
        elseif step.kind == "keepsakeRackChange" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "keepsakeKey" }, { "equipResults" }, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            local key, keyError = stringValue(step.keepsakeKey, label .. ".trace keepsakeKey")
            if not key then return nil, keyError end
            local valid, validError = validateRoomActionOwner(owner, context, '["interactKeepsakeRack"]', label .. ".trace owner")
            if not valid then return nil, validError end
            if result.contents.keepsakeRack == nil or result.contents.keepsakeRack.keepsakeKey ~= key then return fail(label .. ".trace rack target does not close contents") end
            parsed.keepsakeKey = key
            if step.equipResults ~= nil then
                local results, resultsError = keys(step.equipResults, {}, { "jeweledPom", "experimentalHammer", "transcendentEmbryo" }, label .. ".trace rack results")
                if not results then return nil, resultsError end
                parsed.equipResults = {}
                if results.jeweledPom ~= nil then
                    local pom, pomError = keys(results.jeweledPom, { "traitKey" }, { "rarity" }, label .. ".trace rack Pom")
                    if not pom then return nil, pomError end
                    local trait, traitError = stringValue(pom.traitKey, label .. ".trace rack Pom trait")
                    if not trait then return nil, traitError end
                    if pom.rarity ~= nil then
                        local rarity, rarityError = stringValue(pom.rarity, label .. ".trace rack Pom rarity")
                        if not rarity then return nil, rarityError end
                        parsed.equipResults.jeweledPom = { traitKey = trait, rarity = rarity }
                    else parsed.equipResults.jeweledPom = { traitKey = trait } end
                end
                if results.experimentalHammer ~= nil then
                    local hammer, hammerError = object(results.experimentalHammer, label .. ".trace rack Hammer")
                    if not hammer then return nil, hammerError end
                    if hammer.kind == "selected" then
                        local checkedHammer, checkedHammerError = keys(hammer, { "kind", "traitKey" }, nil, label .. ".trace rack Hammer")
                        if not checkedHammer then return nil, checkedHammerError end
                        local trait, traitError = stringValue(hammer.traitKey, label .. ".trace rack Hammer trait")
                        if not trait then return nil, traitError end
                        parsed.equipResults.experimentalHammer = { kind = "selected", traitKey = trait }
                    elseif hammer.kind == "exhausted" then parsed.equipResults.experimentalHammer = { kind = "exhausted" }
                    else return fail(label .. ".trace rack Hammer kind unsupported") end
                end
                if results.transcendentEmbryo ~= nil then
                    local embryo, embryoError = keys(results.transcendentEmbryo, { "blessingKey" }, nil, label .. ".trace rack Embryo")
                    if not embryo then return nil, embryoError end
                    local blessing, blessingError = stringValue(embryo.blessingKey, label .. ".trace rack Embryo blessing")
                    if not blessing then return nil, blessingError end
                    parsed.equipResults.transcendentEmbryo = { blessingKey = blessing }
                end
            end
        elseif step.kind == "fountainUse" then
            local checked, checkedError = keys(step, { "id", "kind", "owner" }, { "aromaticPhialTarget" }, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            local valid, validError = validateRoomActionOwner(owner, context, '["useFountain"]', label .. ".trace owner")
            if not valid then return nil, validError end
            if step.aromaticPhialTarget ~= nil then local target, targetError = stringValue(step.aromaticPhialTarget, label .. ".trace fountain target"); if not target then return nil, targetError end; if result.contents.fountain == nil or result.contents.fountain.aromaticPhialTarget ~= target then return fail(label .. ".trace fountain target does not close contents") end; parsed.aromaticPhialTarget = target end
        elseif step.kind == "acquireReward" then
            local checked, checkedError = keys(step, { "id", "kind", "owner", "sourceOwner", "reward", "producerLifecycleKey", "roles" }, nil, label .. ".trace[" .. traceIndex .. "]")
            if not checked then return nil, checkedError end
            local reward, rewardError = parseReward(step.reward, label .. ".trace reward")
            local sourceOwner, sourceError = stringValue(step.sourceOwner, label .. ".trace sourceOwner")
            local producer, producerError = stringValue(step.producerLifecycleKey, label .. ".trace producerLifecycleKey")
            local roles, rolesError = array(step.roles, label .. ".trace roles", 16)
            if not reward then return nil, rewardError end; if not sourceOwner then return nil, sourceError end; if not producer then return nil, producerError end; if not roles then return nil, rolesError end
            if reward.producerLifecycleKey ~= producer then return fail(label .. ".trace acquisition provenance mismatch") end
            local sourceValid, sourceValidError = validateAcquisitionSource(sourceOwner, context, label .. ".trace sourceOwner")
            if not sourceValid then return nil, sourceValidError end
            local actionParts, actionPartsError = addressParts(owner, label .. ".trace owner")
            if not actionParts then return nil, actionPartsError end
            local actionValid, actionValidError = exactAddressBase(actionParts, "acquisitionRole", 5, context, label .. ".trace owner")
            if not actionValid then return nil, actionValidError end
            if actionParts[4] ~= sourceOwner then return fail(label .. ".trace acquisition owner source mismatch") end
            parsed.sourceOwner, parsed.reward, parsed.producerLifecycleKey, parsed.roles = sourceOwner, reward, producer, {}
            local identities = {}
            local actionRoleFound = false
            for roleIndex, entry in ipairs(roles) do
                local role, roleError = parseRole(entry, label .. ".trace roles[" .. roleIndex .. "]")
                if not role then return nil, roleError end
                local identity = role.role .. "\0" .. role.lifecyclePoint
                if identities[identity] then return fail(label .. ".trace roles duplicate") end
                identities[identity] = true
                if role.role == actionParts[5] then actionRoleFound = true end
                if role.settlement ~= nil then
                    local siteValid, siteError = validateSiteAddress(role.settlement.site, context, label .. ".trace settlement site")
                    if not siteValid then return nil, siteError end
                    local entryParts, entryPartsError = addressParts(role.settlement.entry, label .. ".trace settlement entry")
                    if not entryParts then return nil, entryPartsError end
                    local entryValid, entryError = exactAddressBase(entryParts, "acquisitionEntry", 5, context, label .. ".trace settlement entry")
                    if not entryValid then return nil, entryError end
                    if entryParts[4] ~= role.settlement.site or entryParts[5] ~= role.role then return fail(label .. ".trace settlement relation mismatch") end
                end
                parsed.roles[roleIndex] = role
            end
            if #parsed.roles == 0 then return fail(label .. ".trace roles cannot be empty") end
            if not actionRoleFound then return fail(label .. ".trace acquisition owner role mismatch") end
        else return fail(label .. ".trace kind unsupported") end
        result.trace[traceIndex] = parsed
    end
    if room.entered and (result.trace[1].kind ~= "roomEntered" or result.trace[#result.trace].kind ~= "beforeRoomExit") then return fail(label .. ".trace boundary order invalid") end
    local outgoing, outgoingError = keys(room.outgoing, { "owner", "kind" }, { "targets", "additional", "selectedExitKey", "selectedAdditionalKey", "target", "resolvedSharedRewardStoreKey" }, label .. ".outgoing")
    if not outgoing then return nil, outgoingError end
    local outgoingOwner, outgoingOwnerError = stringValue(outgoing.owner, label .. ".outgoing.owner")
    if not outgoingOwner then return nil, outgoingOwnerError end
    if outgoing.kind == "batch" then
        local checked, checkedError = keys(outgoing, { "owner", "kind", "targets", "additional" }, { "selectedExitKey", "selectedAdditionalKey", "resolvedSharedRewardStoreKey" }, label .. ".outgoing")
        if not checked then return nil, checkedError end
        local targets, targetsError = array(outgoing.targets, label .. ".outgoing.targets", protocol.MAX_TARGETS)
        if not targets then return nil, targetsError end
        if #targets == 0 then return fail(label .. ".outgoing.targets cannot be empty") end
        local additional, additionalError = array(outgoing.additional, label .. ".outgoing.additional", 2)
        if not additional then return nil, additionalError end
        local selectedExit = outgoing.selectedExitKey ~= nil and stringValue(outgoing.selectedExitKey, label .. ".outgoing.selectedExitKey") or nil
        local selectedAdditional = outgoing.selectedAdditionalKey ~= nil and stringValue(outgoing.selectedAdditionalKey, label .. ".outgoing.selectedAdditionalKey") or nil
        if (selectedExit == nil and selectedAdditional == nil) or (selectedExit ~= nil and selectedAdditional ~= nil) then return fail(label .. ".outgoing must select one continuation") end
        result.outgoing = { owner = outgoingOwner, kind = "batch", targets = {}, additional = {} }
        if selectedExit ~= nil then result.outgoing.selectedExitKey = selectedExit else result.outgoing.selectedAdditionalKey = selectedAdditional end
        if outgoing.resolvedSharedRewardStoreKey ~= nil then
            local store, storeError = stringValue(outgoing.resolvedSharedRewardStoreKey, label .. ".outgoing.resolvedSharedRewardStoreKey")
            if not store then return nil, storeError end
            result.outgoing.resolvedSharedRewardStoreKey = store
        end
        local exits, indices, additionalKeys, additionalOwners, picked = {}, {}, {}, {}, 0
        for targetIndex, valueTarget in ipairs(targets) do
            local target, targetError = keys(valueTarget, { "exitKey", "index", "type", "room", "picked" }, nil, label .. ".outgoing.targets[" .. targetIndex .. "]")
            if not target then return nil, targetError end
            local exitKey, exitError = stringValue(target.exitKey, label .. ".outgoing.targets[" .. targetIndex .. "].exitKey")
            if not exitKey then return nil, exitError end
            local exitIndex, exitIndexError = integer(target.index, label .. ".outgoing.targets[" .. targetIndex .. "].index", 1, protocol.MAX_TARGETS)
            if not exitIndex then return nil, exitIndexError end
            if exitIndex ~= targetIndex then return fail(label .. ".outgoing.targets must preserve physical order") end
            local exitType, exitTypeError = stringValue(target.type, label .. ".outgoing.targets[" .. targetIndex .. "].type")
            if not exitType then return nil, exitTypeError end
            if type(target.picked) ~= "boolean" then return fail(label .. ".outgoing.targets picked invalid") end
            if exits[exitKey] or indices[exitIndex] then return fail(label .. ".outgoing.targets duplicate identity") end
            exits[exitKey], indices[exitIndex] = true, true
            if target.picked then picked = picked + 1 end
            local targetRoom, targetRoomError = keys(target.room, { "id", "biomeKey", "gameName" }, nil, label .. ".outgoing.targets[" .. targetIndex .. "].room")
            if not targetRoom then return nil, targetRoomError end
            local targetId, targetIdError = stringValue(targetRoom.id, label .. ".outgoing.targets[" .. targetIndex .. "].room.id")
            local targetBiome, targetBiomeError = stringValue(targetRoom.biomeKey, label .. ".outgoing.targets[" .. targetIndex .. "].room.biomeKey")
            local targetName, targetNameError = stringValue(targetRoom.gameName, label .. ".outgoing.targets[" .. targetIndex .. "].room.gameName")
            if not targetId then return nil, targetIdError end
            if not targetBiome then return nil, targetBiomeError end
            if not targetName then return nil, targetNameError end
            result.outgoing.targets[targetIndex] = { exitKey = exitKey, index = exitIndex, type = exitType, room = { id = targetId, biomeKey = targetBiome, gameName = targetName }, picked = target.picked }
            if target.picked and selectedExit ~= exitKey then return fail(label .. ".outgoing selected target mismatch") end
        end
        for additionalIndex, valueAdditional in ipairs(additional) do
            local item, itemError = keys(valueAdditional, { "kind", "key", "owner", "room", "picked" }, { "ixionOrigin" }, label .. ".outgoing.additional[" .. additionalIndex .. "]")
            if not item then return nil, itemError end
            if (item.kind ~= "chaos" and item.kind ~= "zagreusContract") or item.key ~= item.kind then return fail(label .. ".outgoing additional identity invalid") end
            local key, keyError = stringValue(item.key, label .. ".outgoing.additional key")
            local owner, ownerError = stringValue(item.owner, label .. ".outgoing.additional owner")
            if not key then return nil, keyError end; if not owner then return nil, ownerError end
            local ownerParts, ownerPartsError = addressParts(owner, label .. ".outgoing.additional owner")
            if not ownerParts then return nil, ownerPartsError end
            local ownerBase, ownerBaseError = exactAddressBase(
                ownerParts, "additionalExit", 5, context, label .. ".outgoing.additional owner")
            if not ownerBase then return nil, ownerBaseError end
            if ownerParts[4] ~= context.roomId or ownerParts[5] ~= key then
                return fail(label .. ".outgoing additional owner mismatch")
            end
            if additionalKeys[key] or additionalOwners[owner] then return fail(label .. ".outgoing additional duplicate") end
            additionalKeys[key], additionalOwners[owner] = true, true
            local targetRoom, targetRoomError = keys(item.room, { "id", "biomeKey", "gameName" }, nil, label .. ".outgoing.additional room")
            if not targetRoom then return nil, targetRoomError end
            if type(item.picked) ~= "boolean" then return fail(label .. ".outgoing additional picked invalid") end
            if item.picked then picked = picked + 1; if selectedAdditional ~= key then return fail(label .. ".outgoing selected additional mismatch") end end
            local roomId, roomIdError = stringValue(targetRoom.id, label .. ".outgoing.additional room.id")
            local roomBiome, roomBiomeError = stringValue(targetRoom.biomeKey, label .. ".outgoing.additional room.biomeKey")
            local roomName, roomNameError = stringValue(targetRoom.gameName, label .. ".outgoing.additional room.gameName")
            if not roomId then return nil, roomIdError end
            if not roomBiome then return nil, roomBiomeError end
            if not roomName then return nil, roomNameError end
            local parsed = { kind = item.kind, key = key, owner = owner, room = { id = roomId, biomeKey = roomBiome, gameName = roomName }, picked = item.picked }
            if item.ixionOrigin ~= nil then
                if item.kind ~= "chaos" then return fail(label .. ".outgoing Ixion origin requires Chaos") end
                local origin, originError = keys(item.ixionOrigin, { "sourceBiomeKey", "sourceOccurrenceId", "generationKey" }, nil, label .. ".outgoing.additional ixionOrigin")
                if not origin then return nil, originError end
                local sourceBiome, sourceBiomeError = stringValue(origin.sourceBiomeKey, label .. ".outgoing.additional ixion sourceBiomeKey")
                local sourceOccurrence, sourceOccurrenceError = stringValue(origin.sourceOccurrenceId, label .. ".outgoing.additional ixion sourceOccurrenceId")
                local generationKey, generationKeyError = stringValue(origin.generationKey, label .. ".outgoing.additional ixion generationKey")
                if not sourceBiome then return nil, sourceBiomeError end
                if not sourceOccurrence then return nil, sourceOccurrenceError end
                if not generationKey then return nil, generationKeyError end
                parsed.ixionOrigin = { sourceBiomeKey = sourceBiome, sourceOccurrenceId = sourceOccurrence, generationKey = generationKey }
            end
            result.outgoing.additional[additionalIndex] = parsed
        end
        if picked ~= 1 then return fail(label .. ".outgoing must select exactly one continuation") end
    elseif outgoing.kind == "fixed" then
        local checked, checkedError = keys(outgoing, { "owner", "kind", "target" }, nil, label .. ".outgoing")
        if not checked then return nil, checkedError end
        local target, targetError = keys(outgoing.target, { "id", "biomeKey", "gameName" }, nil, label .. ".outgoing.target")
        if not target then return nil, targetError end
        result.outgoing = { owner = outgoingOwner, kind = "fixed", target = { id = stringValue(target.id, label .. ".outgoing.target.id"), biomeKey = stringValue(target.biomeKey, label .. ".outgoing.target.biomeKey"), gameName = stringValue(target.gameName, label .. ".outgoing.target.gameName") } }
    elseif outgoing.kind == "terminal" then
        local checked, checkedError = keys(outgoing, { "owner", "kind" }, nil, label .. ".outgoing")
        if not checked then return nil, checkedError end
        result.outgoing = { owner = outgoingOwner, kind = "terminal" }
    else
        return fail(label .. ".outgoing.kind unsupported")
    end
    return result
end

function protocol.decode(value)
    local record, errorMessage = keys(value, { "format", "protocolVersion", "catalogVersion", "projectId", "planFingerprint", "routeKey", "extent", "rooms" }, nil, "execution plan")
    if not record then return nil, errorMessage end
    if record.format ~= protocol.FORMAT then return fail("unsupported execution plan format") end
    if record.protocolVersion ~= protocol.VERSION then return fail("unsupported execution protocol version") end
    if record.catalogVersion ~= protocol.CATALOG_VERSION then return fail("unsupported execution catalog version") end
    if record.routeKey ~= "Underworld" then return fail("unsupported execution route") end
    local projectId, projectError = stringValue(record.projectId, "projectId")
    local fingerprint, fingerprintError = stringValue(record.planFingerprint, "planFingerprint")
    if not projectId then return nil, projectError end
    if not fingerprint then return nil, fingerprintError end
    if not fingerprint:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") then return fail("planFingerprint must be an eight-character lowercase hexadecimal value") end
    local extent, extentError = keys(record.extent, { "kind", "biomeKeys", "terminalBiomeKey" }, nil, "extent")
    if not extent then return nil, extentError end
    if extent.kind ~= "configuredPrefix" then return fail("unsupported execution extent") end
    local biomeKeys, biomeError = array(extent.biomeKeys, "extent.biomeKeys", 2)
    if not biomeKeys then return nil, biomeError end
    if not ((#biomeKeys == 1 and biomeKeys[1] == "F") or (#biomeKeys == 2 and biomeKeys[1] == "F" and biomeKeys[2] == "G")) then return fail("unsupported execution biome prefix") end
    if extent.terminalBiomeKey ~= biomeKeys[#biomeKeys] then return fail("extent terminal biome mismatch") end
    local rooms, roomsError = array(record.rooms, "rooms", protocol.MAX_ROOMS)
    if not rooms then return nil, roomsError end
    if #rooms == 0 then return fail("execution plan requires rooms") end
    local resultRooms, ids = {}, {}
    for index, valueRoom in ipairs(rooms) do
        local room, roomError = parseRoom(valueRoom, index)
        if not room then return nil, roomError end
        if ids[room.id] then return fail("execution plan has duplicate room ids") end
        ids[room.id] = true
        if room.biomeKey ~= "F" and room.biomeKey ~= "G" then return fail("room has unsupported biome") end
        resultRooms[index] = room
    end
    if not resultRooms[1].entered or resultRooms[1].biomeKey ~= "F" then return fail("execution plan must start with entered F room") end
    local roomsById = {}
    for _, room in ipairs(resultRooms) do roomsById[room.id] = room end
    for _, room in ipairs(resultRooms) do
        if room.outgoing.kind == "batch" then
            for _, target in ipairs(room.outgoing.targets) do
                local referenced = roomsById[target.room.id]
                if not referenced then return fail("outgoing target references unknown room") end
                if referenced.biomeKey ~= target.room.biomeKey or referenced.gameName ~= target.room.gameName then
                    return fail("outgoing target room identity mismatch")
                end
            end
            for _, additional in ipairs(room.outgoing.additional) do
                local referenced = roomsById[additional.room.id]
                if not referenced then return fail("additional exit references unknown room") end
                if referenced.biomeKey ~= additional.room.biomeKey
                    or referenced.gameName ~= additional.room.gameName then
                    return fail("additional exit room identity mismatch")
                end
                if (additional.kind == "chaos" and not additional.room.gameName:match("^Chaos_"))
                    or (additional.kind == "zagreusContract"
                        and additional.room.gameName ~= "C_Boss01") then
                    return fail("additional exit target mismatch")
                end
                if additional.ixionOrigin ~= nil then
                    local source = roomsById[additional.ixionOrigin.sourceOccurrenceId]
                    local purchaseFound = false
                    for _, step in ipairs(source and source.trace or {}) do
                        if step.kind == "stygianWellPurchase"
                            and step.generationKey == additional.ixionOrigin.generationKey
                            and step.offerKey == "TemporaryForcedSecretDoorTrait" then
                            purchaseFound = true
                            break
                        end
                    end
                    if source == nil
                        or source.biomeKey ~= additional.ixionOrigin.sourceBiomeKey
                        or not purchaseFound then
                        return fail("Ixion origin mismatch")
                    end
                end
            end
        elseif room.outgoing.kind == "fixed" then
            local referenced = roomsById[room.outgoing.target.id]
            if not referenced then return fail("fixed target references unknown room") end
            if referenced.biomeKey ~= room.outgoing.target.biomeKey or referenced.gameName ~= room.outgoing.target.gameName then
                return fail("fixed target room identity mismatch")
            end
        end
    end
    return { kind = "ready", format = protocol.FORMAT, protocolVersion = protocol.VERSION, catalogVersion = record.catalogVersion, projectId = projectId, planFingerprint = fingerprint, routeKey = "Underworld", extent = { kind = "configuredPrefix", biomeKeys = biomeKeys, terminalBiomeKey = extent.terminalBiomeKey }, rooms = resultRooms }
end

return protocol
