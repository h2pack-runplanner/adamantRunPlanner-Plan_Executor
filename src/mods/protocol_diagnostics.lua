local p = type(import) == "function" and import("mods/protocol_primitives.lua")
    or require("mods/protocol_primitives")

local diagnostics = {}

local sections = {
    "counters",
    "bags",
    "godPool",
    "traits",
    "arcana",
    "vows",
    "forfeit",
    "chaos",
    "keepsakes",
    "rewardPriorities",
    "hexProgress",
    "artificer",
    "retainedEffects",
}

local rarities = { Common = true, Rare = true, Epic = true, Heroic = true }

local function validateStringList(value, label, maximum)
    local _, errorMessage = p.strings(value, label, maximum)
    if errorMessage then return nil, errorMessage end
    return true
end

local function validateIntegerList(value, label, minimum)
    local rows, errorMessage = p.arr(value, label)
    if not rows then return nil, errorMessage end
    for index, item in ipairs(rows) do
        if not p.int(item, label .. "[" .. index .. "]", minimum) then
            return p.fail(label .. " has invalid integer")
        end
    end
    return true
end

local function validateCounters(value, label)
    local record, errorMessage = p.exact(
        value,
        { "biomeDepthCache", "biomeEncounterDepth", "routeEncounterDepth", "roomHistoryOrdinal" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    for _, key in ipairs({
        "biomeDepthCache", "biomeEncounterDepth", "routeEncounterDepth", "roomHistoryOrdinal",
    }) do
        if not p.int(record[key], label .. "." .. key, 0) then
            return p.fail(label .. " has invalid counter")
        end
    end
    return true
end

local function validateCount(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    if record.kind == "exact" then
        local exactCount, exactError = p.exact(record, { "kind", "count" }, {}, label)
        if not exactCount then return nil, exactError end
        if not p.int(exactCount.count, label .. ".count", 0) then
            return p.fail(label .. " has invalid exact count")
        end
        return true
    end
    if record.kind == "range" then
        local range, rangeError = p.exact(record, { "kind", "min", "max" }, {}, label)
        if not range then return nil, rangeError end
        if not p.int(range.min, label .. ".min", 0)
            or not p.int(range.max, label .. ".max", 0)
            or range.max < range.min then
            return p.fail(label .. " has invalid range")
        end
        return true
    end
    return p.fail(label .. " has unsupported count")
end

local function validateBags(value, label)
    local rows, errorMessage = p.arr(value, label)
    if not rows then return nil, errorMessage end
    for index, valueRow in ipairs(rows) do
        local row, rowError = p.exact(
            valueRow,
            { "storeKey", "remaining" },
            {},
            label .. "[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.storeKey, label .. ".storeKey") then return p.fail(label .. " invalid bag") end
        local _, countError = validateCount(row.remaining, label .. ".remaining")
        if countError then return nil, countError end
    end
    return true
end

local function validateGodPool(value, label)
    local record, errorMessage = p.exact(
        value,
        { "acquiredSourceKeys", "effectiveSourceKeys", "capNarrowed" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    local _, acquiredError = validateStringList(record.acquiredSourceKeys, label .. ".acquiredSourceKeys")
    if acquiredError then return nil, acquiredError end
    local _, effectiveError = validateStringList(record.effectiveSourceKeys, label .. ".effectiveSourceKeys")
    if effectiveError then return nil, effectiveError end
    if not p.bool(record.capNarrowed, label .. ".capNarrowed") then
        return p.fail(label .. " has invalid capNarrowed")
    end
    return true
end

local function validateTraits(value, label)
    local record, errorMessage = p.exact(
        value,
        { "equipped", "slots", "elements", "godRarityCounts", "upgradableCount", "bannedTraitKeys" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    local equipped, equippedError = p.arr(record.equipped, label .. ".equipped")
    if not equipped then return nil, equippedError end
    for index, valueRow in ipairs(equipped) do
        local row, rowError = p.exact(
            valueRow,
            { "traitKey" },
            { "rarity", "level", "hammerRank" },
            label .. ".equipped[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.traitKey, label .. ".traitKey")
            or (row.rarity ~= nil and not p.str(row.rarity, label .. ".rarity"))
            or (row.level ~= nil and not p.int(row.level, label .. ".level", 0))
            or (row.hammerRank ~= nil
                and not p.one(row.hammerRank, { RankI = true, RankII = true }, label .. ".hammerRank")) then
            return p.fail(label .. " has invalid equipped trait")
        end
    end
    local slots, slotsError = p.arr(record.slots, label .. ".slots", 6)
    if not slots then return nil, slotsError end
    local slotKeys = {
        Melee = true, Secondary = true, Ranged = true, Rush = true, Mana = true, Spell = true,
    }
    for index, valueRow in ipairs(slots) do
        local row, rowError = p.exact(
            valueRow,
            { "slot" },
            { "traitKey" },
            label .. ".slots[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.one(row.slot, slotKeys, label .. ".slot")
            or (row.traitKey ~= nil and not p.str(row.traitKey, label .. ".traitKey")) then
            return p.fail(label .. " has invalid trait slot")
        end
    end
    if not p.recordNumbers(record.elements, label .. ".elements")
        or not p.recordNumbers(record.godRarityCounts, label .. ".godRarityCounts")
        or not p.int(record.upgradableCount, label .. ".upgradableCount", 0) then
        return p.fail(label .. " has invalid trait summary")
    end
    return validateStringList(record.bannedTraitKeys, label .. ".bannedTraitKeys")
end

local function validateArcana(value, label)
    local record, errorMessage = p.exact(value, { "active" }, {}, label)
    if not record then return nil, errorMessage end
    local rows, rowsError = p.arr(record.active, label .. ".active")
    if not rows then return nil, rowsError end
    for index, valueRow in ipairs(rows) do
        local row, rowError = p.exact(
            valueRow,
            { "key", "origin", "rarity" },
            {},
            label .. ".active[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.key, label .. ".key")
            or not p.one(row.origin, { manual = true, automatic = true, temporary = true }, label)
            or not p.one(row.rarity, rarities, label) then
            return p.fail(label .. " has invalid active Arcana")
        end
    end
    return true
end

local function validateVows(value, label)
    local record, errorMessage = p.exact(
        value,
        { "configuredRanks", "effectiveRanks", "disabledKeys" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    if not p.recordNumbers(record.configuredRanks, label .. ".configuredRanks")
        or not p.recordNumbers(record.effectiveRanks, label .. ".effectiveRanks") then
        return p.fail(label .. " has invalid Vow ranks")
    end
    return validateStringList(record.disabledKeys, label .. ".disabledKeys")
end

local function validateChaos(value, label)
    local record, errorMessage = p.exact(value, { "active", "matured" }, {}, label)
    if not record then return nil, errorMessage end
    local active, activeError = p.arr(record.active, label .. ".active")
    if not active then return nil, activeError end
    for index, valueRow in ipairs(active) do
        local row, rowError = p.exact(
            valueRow,
            { "curseKey", "blessingKey", "rarity", "clock", "remaining" },
            {},
            label .. ".active[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.curseKey, label .. ".curseKey")
            or not p.str(row.blessingKey, label .. ".blessingKey")
            or not p.str(row.rarity, label .. ".rarity")
            or not p.one(row.clock, {
                encounters = true,
                locations = true,
                godBoonScreens = true,
            }, label .. ".clock")
            or not p.int(row.remaining, label .. ".remaining", 0) then
            return p.fail(label .. " has invalid active Chaos outcome")
        end
    end
    local matured, maturedError = p.arr(record.matured, label .. ".matured")
    if not matured then return nil, maturedError end
    for index, valueRow in ipairs(matured) do
        local row, rowError = p.exact(
            valueRow,
            { "blessingKey", "rarity" },
            {},
            label .. ".matured[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.blessingKey, label .. ".blessingKey")
            or not p.str(row.rarity, label .. ".rarity") then
            return p.fail(label .. " has invalid matured Chaos outcome")
        end
    end
    return true
end

local function validateKeepsakes(value, label)
    local record, errorMessage = p.exact(
        value,
        { "currentKey", "usedKeys", "blockedKeys", "fatedStatus" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    if not p.str(record.currentKey, label .. ".currentKey")
        or not p.one(record.fatedStatus, { Unknown = true, Fated = true, Unfated = true }, label) then
        return p.fail(label .. " has invalid Keepsake state")
    end
    local _, usedError = validateStringList(record.usedKeys, label .. ".usedKeys")
    if usedError then return nil, usedError end
    return validateStringList(record.blockedKeys, label .. ".blockedKeys")
end

local function validateHex(value, label)
    local record, errorMessage = p.exact(
        value,
        { "talentKeys", "closed", "bankedPathPoints", "investedPathPoints" },
        { "spellTraitKey", "layoutKey" },
        label
    )
    if not record then return nil, errorMessage end
    local _, talentError = validateStringList(record.talentKeys, label .. ".talentKeys")
    if talentError then return nil, talentError end
    if not p.bool(record.closed, label .. ".closed")
        or not p.int(record.bankedPathPoints, label .. ".bankedPathPoints", 0)
        or not p.int(record.investedPathPoints, label .. ".investedPathPoints", 0)
        or (record.spellTraitKey ~= nil and not p.str(record.spellTraitKey, label .. ".spellTraitKey"))
        or (record.layoutKey ~= nil and not p.str(record.layoutKey, label .. ".layoutKey")) then
        return p.fail(label .. " has invalid Hex state")
    end
    return true
end

local function validateCharge(value, label)
    if p.json.isNull(value) then return true end
    local record, errorMessage = p.exact(value, { "remainingCharges" }, {}, label)
    if not record then return nil, errorMessage end
    if not p.int(record.remainingCharges, label .. ".remainingCharges", 0) then
        return p.fail(label .. " has invalid charge")
    end
    return true
end

local function validateOriginStatus(record, label)
    if not p.one(record.origin, { ordinary = true, echo = true }, label .. ".origin")
        or not p.one(record.status, { pending = true, consumed = true }, label .. ".status") then
        return p.fail(label .. " has invalid origin or status")
    end
    return true
end

local function validatePendingKeepsakes(value, label)
    local record, errorMessage = p.exact(
        value,
        {
            "olympianSources", "jeweledPom", "experimentalHammers", "callingCard", "timePiece",
            "figLeaf", "gorgon", "phial", "figurine", "stone", "transcendentEmbryo",
        },
        {},
        label
    )
    if not record then return nil, errorMessage end
    local sources, sourcesError = p.arr(record.olympianSources, label .. ".olympianSources")
    if not sources then return nil, sourcesError end
    for index, valueRow in ipairs(sources) do
        local row, rowError = p.exact(
            valueRow,
            {
                "keepsakeKey", "providerKey", "origin", "acquisitionOrder", "remainingForceUses",
                "remainingRarificationUses", "maximumSourceRarityLevel",
            },
            {},
            label .. ".olympianSources[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.keepsakeKey, label .. ".keepsakeKey")
            or not p.str(row.providerKey, label .. ".providerKey")
            or not p.one(row.origin, { ordinary = true, echo = true }, label .. ".origin")
            or not p.int(row.acquisitionOrder, label .. ".acquisitionOrder", 0)
            or not p.int(row.remainingForceUses, label .. ".remainingForceUses", 0)
            or row.remainingForceUses > 1
            or not p.int(row.remainingRarificationUses, label .. ".remainingRarificationUses", 0)
            or row.remainingRarificationUses > 1
            or not p.int(row.maximumSourceRarityLevel, label .. ".maximumSourceRarityLevel", 1)
            or row.maximumSourceRarityLevel > 3 then
            return p.fail(label .. " has invalid Olympian source")
        end
    end
    if not p.json.isNull(record.jeweledPom) then
        local pom, pomError = p.exact(
            record.jeweledPom,
            { "grantedTraitKey", "active", "levels", "acquisitionIdentity" },
            {},
            label .. ".jeweledPom"
        )
        if not pom then return nil, pomError end
        if not p.str(pom.grantedTraitKey, label .. ".grantedTraitKey")
            or not p.bool(pom.active, label .. ".active")
            or not p.int(pom.levels, label .. ".levels", 0)
            or not p.str(pom.acquisitionIdentity, label .. ".acquisitionIdentity") then
            return p.fail(label .. " has invalid Jeweled Pom state")
        end
    end
    local hammers, hammersError = p.arr(record.experimentalHammers, label .. ".experimentalHammers")
    if not hammers then return nil, hammersError end
    for index, valueRow in ipairs(hammers) do
        local row, rowError = p.exact(
            valueRow,
            { "traitKey", "remainingUses", "acquisitionIdentity", "active" },
            {},
            label .. ".experimentalHammers[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.traitKey, label .. ".traitKey")
            or not p.int(row.remainingUses, label .. ".remainingUses", 0)
            or not p.str(row.acquisitionIdentity, label .. ".acquisitionIdentity")
            or not p.bool(row.active, label .. ".active") then
            return p.fail(label .. " has invalid Experimental Hammer state")
        end
    end
    for _, key in ipairs({ "callingCard", "timePiece" }) do
        local _, chargeError = validateCharge(record[key], label .. "." .. key)
        if chargeError then return nil, chargeError end
    end
    if not p.json.isNull(record.figLeaf) then
        local leaf, leafError = p.exact(
            record.figLeaf,
            { "remainingUses", "activatedThisBiome" },
            {},
            label .. ".figLeaf"
        )
        if not leaf then return nil, leafError end
        if not p.int(leaf.remainingUses, label .. ".remainingUses", 0)
            or not p.bool(leaf.activatedThisBiome, label .. ".activatedThisBiome") then
            return p.fail(label .. " has invalid Fig Leaf state")
        end
    end
    if not p.json.isNull(record.gorgon) then
        local gorgon, gorgonError = p.exact(
            record.gorgon,
            { "status" },
            { "rarity" },
            label .. ".gorgon"
        )
        if not gorgon then return nil, gorgonError end
        if not p.one(gorgon.status, { pending = true, consumed = true, expired = true }, label) then
            return p.fail(label .. " has invalid Gorgon state")
        end
        if gorgon.status == "pending" then
            if not p.one(gorgon.rarity, rarities, label .. ".rarity") then
                return p.fail(label .. " has invalid Gorgon rarity")
            end
        elseif gorgon.rarity ~= nil then
            return p.fail(label .. " has unexpected Gorgon rarity")
        end
    end
    if not p.json.isNull(record.phial) then
        local phial, phialError = p.exact(record.phial, { "status" }, {}, label .. ".phial")
        if not phial then return nil, phialError end
        if not p.one(phial.status, { pending = true, consumed = true }, label .. ".phial.status") then
            return p.fail(label .. " has invalid Phial state")
        end
    end
    if not p.json.isNull(record.figurine) then
        local figurine, figurineError = p.exact(
            record.figurine,
            { "origin", "status", "rarity" },
            {},
            label .. ".figurine"
        )
        if not figurine then return nil, figurineError end
        local _, statusError = validateOriginStatus(figurine, label .. ".figurine")
        if statusError then return nil, statusError end
        if not p.one(figurine.rarity, rarities, label .. ".figurine.rarity") then
            return p.fail(label .. " has invalid Figurine rarity")
        end
    end
    if not p.json.isNull(record.stone) then
        local stone, stoneError = p.exact(
            record.stone,
            { "origin", "status", "rank" },
            {},
            label .. ".stone"
        )
        if not stone then return nil, stoneError end
        local _, statusError = validateOriginStatus(stone, label .. ".stone")
        if statusError then return nil, statusError end
        if not p.one(stone.rank, rarities, label .. ".stone.rank") then
            return p.fail(label .. " has invalid Stone rank")
        end
    end
    if not p.json.isNull(record.transcendentEmbryo) then
        local embryo, embryoError = p.exact(
            record.transcendentEmbryo,
            {
                "origin", "rarity", "progress", "markedBlessingKey",
                "markedBlessingValues", "markedBlessingAcquisitionIdentity",
            },
            {},
            label .. ".transcendentEmbryo"
        )
        if not embryo then return nil, embryoError end
        if not p.one(embryo.origin, { ordinary = true, echo = true }, label .. ".origin")
            or not p.one(embryo.rarity, rarities, label .. ".rarity")
            or not p.int(embryo.progress, label .. ".progress", 0)
            or not p.str(embryo.markedBlessingKey, label .. ".markedBlessingKey")
            or not p.str(
                embryo.markedBlessingAcquisitionIdentity,
                label .. ".markedBlessingAcquisitionIdentity"
            ) then
            return p.fail(label .. " has invalid Embryo state")
        end
        local _, valuesError = p.recordNumbers(
            embryo.markedBlessingValues,
            label .. ".markedBlessingValues"
        )
        if valuesError then return nil, valuesError end
    end
    return true
end

local function validateRetainedEffects(value, label)
    local record, errorMessage = p.exact(
        value,
        { "echoShopDuplicateStatus", "keepsakes", "steadyGrowth", "hermesShrineDeliveries", "stygianWell" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    if not p.json.isNull(record.echoShopDuplicateStatus)
        and not p.one(record.echoShopDuplicateStatus, { pending = true, consumed = true }, label) then
        return p.fail(label .. " has invalid Echo duplicate state")
    end
    local _, keepsakeError = validatePendingKeepsakes(record.keepsakes, label .. ".keepsakes")
    if keepsakeError then return nil, keepsakeError end
    local growthRows, growthError = p.arr(record.steadyGrowth, label .. ".steadyGrowth")
    if not growthRows then return nil, growthError end
    for index, valueRow in ipairs(growthRows) do
        local row, rowError = p.exact(
            valueRow,
            { "traitKey", "progress", "interval" },
            {},
            label .. ".steadyGrowth[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.traitKey, label .. ".traitKey")
            or not p.int(row.progress, label .. ".progress", 0)
            or not p.int(row.interval, label .. ".interval", 1) then
            return p.fail(label .. " has invalid Steady Growth clock")
        end
    end
    local deliveries, deliveriesError = p.arr(
        record.hermesShrineDeliveries,
        label .. ".hermesShrineDeliveries"
    )
    if not deliveries then return nil, deliveriesError end
    for index, valueRow in ipairs(deliveries) do
        local row, rowError = p.exact(
            valueRow,
            {
                "sourceKey", "sourceOccurrenceId", "generationKey", "rewardType",
                "remainingUses", "rushed",
            },
            { "dueOccurrenceId", "dueSequence" },
            label .. ".hermesShrineDeliveries[" .. index .. "]"
        )
        if not row then return nil, rowError end
        for _, key in ipairs({ "sourceKey", "sourceOccurrenceId", "generationKey", "rewardType" }) do
            if not p.str(row[key], label .. "." .. key) then
                return p.fail(label .. " has invalid Shrine delivery")
            end
        end
        if not p.int(row.remainingUses, label .. ".remainingUses", 0)
            or not p.bool(row.rushed, label .. ".rushed")
            or (row.dueOccurrenceId ~= nil and not p.str(row.dueOccurrenceId, label .. ".dueOccurrenceId"))
            or (row.dueSequence ~= nil and not p.int(row.dueSequence, label .. ".dueSequence", 0)) then
            return p.fail(label .. " has invalid Shrine delivery")
        end
    end
    local well, wellError = p.exact(
        record.stygianWell,
        { "sparkUses", "yarnUses", "hymnUses", "discountUses", "emptySlotUses", "extendedUses" },
        {},
        label .. ".stygianWell"
    )
    if not well then return nil, wellError end
    for _, key in ipairs({ "sparkUses", "yarnUses", "hymnUses", "extendedUses" }) do
        if not p.int(well[key], label .. ".stygianWell." .. key, 0) then
            return p.fail(label .. " has invalid Well clock")
        end
    end
    local _, discountError = validateIntegerList(
        well.discountUses,
        label .. ".stygianWell.discountUses",
        -256
    )
    if discountError then return nil, discountError end
    return validateIntegerList(well.emptySlotUses, label .. ".stygianWell.emptySlotUses", -256)
end

local validators = {
    counters = validateCounters,
    bags = validateBags,
    godPool = validateGodPool,
    traits = validateTraits,
    arcana = validateArcana,
    vows = validateVows,
    chaos = validateChaos,
    keepsakes = validateKeepsakes,
    rewardPriorities = validateStringList,
    hexProgress = validateHex,
    retainedEffects = validateRetainedEffects,
}

local function validateSection(section, value, label)
    if section == "forfeit" then
        return p.one(value, { inactive = true, available = true, consumed = true }, label)
    end
    if section == "artificer" then
        if p.json.isNull(value) then return true end
        local record, errorMessage = p.exact(value, { "usedCount", "remainingCount" }, {}, label)
        if not record then return nil, errorMessage end
        if not p.int(record.usedCount, label .. ".usedCount", 0)
            or not p.int(record.remainingCount, label .. ".remainingCount", 0) then
            return p.fail(label .. " has invalid Artificer state")
        end
        return true
    end
    return validators[section](value, label)
end

function diagnostics.expand(value, label, framing)
    if value == nil then return {} end
    local record, errorMessage = p.exact(
        value,
        {},
        { "roomEntered", "beforeRoomExit" },
        label
    )
    if not record then return nil, errorMessage end
    local result = {}
    for _, checkpoint in ipairs({ "roomEntered", "beforeRoomExit" }) do
        local frameValue = record[checkpoint]
        if frameValue ~= nil then
            local frame, frameError = p.exact(
                frameValue,
                { "frame", "owner", "checkpoint", "replace" },
                {},
                label .. "." .. checkpoint
            )
            if not frame then return nil, frameError end
            if frame.checkpoint ~= checkpoint
                or not p.int(frame.frame, label .. ".frame", 0)
                or frame.frame ~= framing.next
                or not p.str(frame.owner, label .. ".owner", p.MAX_OWNER_STRING) then
                return p.fail(label .. " has missing or out-of-order diagnostic frame")
            end
            local replace, replaceError = p.exact(
                frame.replace,
                {},
                sections,
                label .. "." .. checkpoint .. ".replace"
            )
            if not replace then return nil, replaceError end
            for section, sectionValue in pairs(replace) do
                local _, sectionError = validateSection(
                    section,
                    sectionValue,
                    label .. "." .. checkpoint .. ".replace." .. section
                )
                if sectionError then return nil, sectionError end
                framing.values[section] = sectionValue
            end
            if framing.next == 0 then
                for _, section in ipairs(sections) do
                    if framing.values[section] == nil then
                        return p.fail(label .. " frame zero must replace every section")
                    end
                end
            end
            local complete = { owner = frame.owner, checkpoint = checkpoint }
            for _, section in ipairs(sections) do complete[section] = framing.values[section] end
            result[checkpoint] = complete
            framing.next = framing.next + 1
        end
    end
    return result
end

local conformanceReaders = {
    steadyGrowth = function(state) return state.retainedEffects.steadyGrowth end,
    chaos = function(state) return state.chaos end,
    keepsakeEffects = function(state) return state.retainedEffects.keepsakes end,
    rewardPriorities = function(state) return state.rewardPriorities end,
    pathOfStars = function(state) return state.hexProgress end,
    forfeit = function(state) return state.forfeit end,
    stygianWell = function(state) return state.retainedEffects.stygianWell end,
}

function diagnostics.conformance(value, state, label)
    local record, errorMessage = p.exact(value, { "facts" }, {}, label)
    if not record then return nil, errorMessage end
    local facts, factsError = p.arr(record.facts, label .. ".facts")
    if not facts then return nil, factsError end
    local expected = {}
    for index, factValue in ipairs(facts) do
        local fact, factError = p.exact(
            factValue,
            { "kind" },
            {},
            label .. ".facts[" .. index .. "]"
        )
        if not fact then return nil, factError end
        local read = conformanceReaders[fact.kind]
        if not read or expected[fact.kind] ~= nil then
            return p.fail(label .. " has unsupported or duplicate conformance fact")
        end
        expected[fact.kind] = read(state)
    end
    return expected
end

return diagnostics
