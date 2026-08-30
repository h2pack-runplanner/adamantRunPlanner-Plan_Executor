-- Strict decoder for the current Run Planner execution-only protocol.
-- This module accepts resolved facts, not project commands or game policy.

local json = require("mods/json")
local protocol = {}

protocol.FORMAT = "run-planner-execution"
protocol.VERSION = 3
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

local function strings(value, label, maximum)
    local values, valuesError = array(value, label, maximum)
    if not values then return nil, valuesError end
    local result, seen = {}, {}
    for index, item in ipairs(values) do
        local text, textError = stringValue(item, label .. "[" .. index .. "]")
        if not text then return nil, textError end
        if seen[text] then return fail(label .. " has duplicate values") end
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
    local diagnostic, errorMessage = keys(value, { "owner", "checkpoint", "counters", "bags", "godPool", "traits", "arcana", "vows", "forfeit" }, nil, label)
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
    local role, roleError = keys(value, { "role", "lifecyclePoint", "kind", "gameName" }, { "settlement", "traitOffer", "levelResolution" }, label)
    if not role then return nil, roleError end
    local result = {}
    for _, field in ipairs({ "role", "lifecyclePoint", "kind", "gameName" }) do local text, textError = stringValue(role[field], label .. "." .. field); if not text then return nil, textError end; result[field] = text end
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
    local contents, contentsError = keys(room.contents, { "encounterPhases", "requiredObjects" }, { "incomingReward" }, label .. ".contents")
    if not contents then return nil, contentsError end
    result.contents = { encounterPhases = {}, requiredObjects = {} }
    if contents.incomingReward ~= nil then
        local reward, rewardError = parseReward(contents.incomingReward, label .. ".contents.incomingReward")
        if not reward then return nil, rewardError end
        result.contents.incomingReward = reward
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
    local outgoing, outgoingError = keys(room.outgoing, { "owner", "kind" }, { "targets", "selectedExitKey", "target", "resolvedSharedRewardStoreKey" }, label .. ".outgoing")
    if not outgoing then return nil, outgoingError end
    local outgoingOwner, outgoingOwnerError = stringValue(outgoing.owner, label .. ".outgoing.owner")
    if not outgoingOwner then return nil, outgoingOwnerError end
    if outgoing.kind == "batch" then
        local checked, checkedError = keys(outgoing, { "owner", "kind", "targets", "selectedExitKey" }, { "resolvedSharedRewardStoreKey" }, label .. ".outgoing")
        if not checked then return nil, checkedError end
        local targets, targetsError = array(outgoing.targets, label .. ".outgoing.targets", protocol.MAX_TARGETS)
        if not targets then return nil, targetsError end
        if #targets == 0 then return fail(label .. ".outgoing.targets cannot be empty") end
        local selectedExit, selectedError = stringValue(outgoing.selectedExitKey, label .. ".outgoing.selectedExitKey")
        if not selectedExit then return nil, selectedError end
        result.outgoing = { owner = outgoingOwner, kind = "batch", targets = {}, selectedExitKey = selectedExit }
        if outgoing.resolvedSharedRewardStoreKey ~= nil then
            local store, storeError = stringValue(outgoing.resolvedSharedRewardStoreKey, label .. ".outgoing.resolvedSharedRewardStoreKey")
            if not store then return nil, storeError end
            result.outgoing.resolvedSharedRewardStoreKey = store
        end
        local exits, indices, picked = {}, {}, 0
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
        if picked ~= 1 then return fail(label .. ".outgoing must select exactly one picked target") end
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
