local p = type(import) == "function" and import("mods/protocol_primitives.lua")
    or require("mods/protocol_primitives")

local rewards = {}

local optionKeys = { option1 = true, option2 = true, option3 = true }
local availabilityContacts = {
    traitEligibility = true,
    storeInventoryGeneration = true,
    storePurchase = true,
    npcConsumableSelection = true,
}

function rewards.reward(value, label)
    local record, errorMessage = p.exact(
        value,
        { "rewardType", "producerLifecycleKey" },
        { "resolvedStoreKey", "source", "spurnedSource", "acquisitionEnabled" },
        label
    )
    if not record then return nil, errorMessage end
    for _, key in ipairs({
        "rewardType", "producerLifecycleKey", "resolvedStoreKey", "source", "spurnedSource",
    }) do
        if record[key] ~= nil and not p.str(record[key], label .. "." .. key) then
            return p.fail(label .. " has invalid " .. key)
        end
    end
    if record.acquisitionEnabled ~= nil
        and not p.bool(record.acquisitionEnabled, label .. ".acquisitionEnabled") then
        return p.fail(label .. " has invalid acquisitionEnabled")
    end
    return record
end

function rewards.fallbacks(value, label)
    local rows, errorMessage = p.arr(value, label)
    if not rows then return nil, errorMessage end
    local seen = {}
    for index, valueRow in ipairs(rows) do
        local row, rowError = p.exact(
            valueRow,
            { "preferredKey", "fallbackKey", "availabilityContact" },
            {},
            label .. "[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.preferredKey, label .. ".preferredKey")
            or not p.str(row.fallbackKey, label .. ".fallbackKey")
            or row.preferredKey == row.fallbackKey
            or not p.one(row.availabilityContact, availabilityContacts, label .. ".availabilityContact") then
            return p.fail(label .. " has invalid fallback")
        end
        local key = row.preferredKey .. "\0" .. row.availabilityContact
        if seen[key] then return p.fail(label .. " has duplicate preferred key") end
        seen[key] = true
    end
    return rows
end

local function replacement(value, label)
    local record, errorMessage = p.exact(
        value,
        { "slot", "replacedTraitKey", "oldRarity", "newTraitKey", "requiredRarity" },
        { "levelBonus" },
        label
    )
    if not record then return nil, errorMessage end
    for _, key in ipairs({ "slot", "replacedTraitKey", "oldRarity", "newTraitKey", "requiredRarity" }) do
        if not p.str(record[key], label .. "." .. key) then
            return p.fail(label .. " has invalid " .. key)
        end
    end
    if record.levelBonus ~= nil and not p.int(record.levelBonus, label .. ".levelBonus", 0) then
        return p.fail(label .. " has invalid levelBonus")
    end
    return record
end

function rewards.traitOffer(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    if record.kind == "fallbackGold" then
        local row, rowError = p.exact(record, { "kind", "giver" }, {}, label)
        if not row then return nil, rowError end
        if not p.str(row.giver, label .. ".giver") then return p.fail(label .. " has invalid giver") end
        return row
    end
    if record.kind == "chaos" then
        local row, rowError = p.exact(
            record,
            {
                "kind", "giver", "curseOptions", "selected", "selectedCurseValues",
                "blessingKey", "rarity", "blessingValues",
            },
            {},
            label
        )
        if not row then return nil, rowError end
        if row.giver ~= "Chaos" or not p.one(row.selected, optionKeys, label .. ".selected") then
            return p.fail(label .. " is a malformed Chaos offer")
        end
        local options, optionsError = p.arr(row.curseOptions, label .. ".curseOptions", 3)
        if not options then return nil, optionsError end
        if #options ~= 3 then return p.fail(label .. ".curseOptions must contain three options") end
        for index, optionValue in ipairs(options) do
            local option, optionError = p.exact(
                optionValue,
                { "curseKey", "requirementCount" },
                {},
                label .. ".curseOptions[" .. index .. "]"
            )
            if not option then return nil, optionError end
            if not p.str(option.curseKey, label .. ".curseKey")
                or not p.int(option.requirementCount, label .. ".requirementCount", 1) then
                return p.fail(label .. " has a malformed curse option")
            end
        end
        if not p.recordNumbers(row.selectedCurseValues, label .. ".selectedCurseValues")
            or not p.str(row.blessingKey, label .. ".blessingKey")
            or not p.str(row.rarity, label .. ".rarity")
            or not p.recordNumbers(row.blessingValues, label .. ".blessingValues") then
            return p.fail(label .. " has malformed Chaos values")
        end
        return row
    end
    local row, rowError = p.exact(
        record,
        { "kind", "giver", "options", "selected" },
        { "rejected", "runtimeFallbacks" },
        label
    )
    if not row then return nil, rowError end
    if row.kind ~= "traits" or not p.str(row.giver, label .. ".giver")
        or not p.one(row.selected, optionKeys, label .. ".selected") then
        return p.fail(label .. " is a malformed trait offer")
    end
    if row.rejected ~= nil and not p.one(row.rejected, optionKeys, label .. ".rejected") then
        return p.fail(label .. " has malformed rejected option")
    end
    local options, optionsError = p.arr(row.options, label .. ".options", 3)
    if not options then return nil, optionsError end
    if #options == 0 then return p.fail(label .. ".options must contain one to three options") end
    local optionIndex = { option1 = 1, option2 = 2, option3 = 3 }
    if optionIndex[row.selected] > #options
        or (row.rejected ~= nil and optionIndex[row.rejected] > #options) then
        return p.fail(label .. " selects a missing option")
    end
    for index, optionValue in ipairs(options) do
        local option, optionError = p.exact(
            optionValue,
            { "key" },
            { "baseRarity", "rarity", "effectiveLevel", "replacement" },
            label .. ".options[" .. index .. "]"
        )
        if not option then return nil, optionError end
        if not p.str(option.key, label .. ".key")
            or (option.rarity ~= nil and not p.str(option.rarity, label .. ".rarity"))
            or (option.baseRarity ~= nil and not p.str(option.baseRarity, label .. ".baseRarity"))
            or (option.effectiveLevel ~= nil
                and not p.int(option.effectiveLevel, label .. ".effectiveLevel", 0)) then
            return p.fail(label .. " has malformed trait option")
        end
        if option.replacement ~= nil then
            local _, replacementError = replacement(option.replacement, label .. ".replacement")
            if replacementError then return nil, replacementError end
        end
    end
    if row.runtimeFallbacks ~= nil then
        local _, fallbackError = rewards.fallbacks(row.runtimeFallbacks, label .. ".runtimeFallbacks")
        if fallbackError then return nil, fallbackError end
    end
    return row
end

function rewards.acquisitionRole(value, label)
    local record, errorMessage = p.exact(
        value,
        { "role", "disposition", "lifecyclePoint", "kind", "gameName" },
        { "producer", "settlement", "traitOffer", "levelResolution" },
        label
    )
    if not record then return nil, errorMessage end
    if not p.one(record.disposition, { normal = true, timePiece = true, artificer = true }, label) then
        return p.fail(label .. " has invalid disposition")
    end
    for _, key in ipairs({ "role", "lifecyclePoint", "kind", "gameName" }) do
        if not p.str(record[key], label .. "." .. key) then
            return p.fail(label .. " has invalid " .. key)
        end
    end
    if record.producer ~= nil then
        local producer, producerError = p.exact(
            record.producer,
            { "kind", "sourceOwner", "sourceRole" },
            {},
            label .. ".producer"
        )
        if not producer then return nil, producerError end
        if not p.one(producer.kind, {
            seaStarDuplicate = true,
            artificerReplacement = true,
            echoLastReward = true,
        }, label .. ".producer.kind")
            or not p.str(producer.sourceOwner, label .. ".producer.sourceOwner", p.MAX_OWNER_STRING)
            or not p.str(producer.sourceRole, label .. ".producer.sourceRole") then
            return p.fail(label .. " has invalid producer")
        end
    end
    if record.settlement ~= nil then
        local settlement, settlementError = p.exact(
            record.settlement,
            { "site", "entry" },
            {},
            label .. ".settlement"
        )
        if not settlement then return nil, settlementError end
        if not p.str(settlement.site, label .. ".settlement.site", p.MAX_OWNER_STRING)
            or not p.str(settlement.entry, label .. ".settlement.entry", p.MAX_OWNER_STRING) then
            return p.fail(label .. " has invalid settlement")
        end
    end
    if record.traitOffer ~= nil then
        local _, offerError = rewards.traitOffer(record.traitOffer, label .. ".traitOffer")
        if offerError then return nil, offerError end
    end
    if record.levelResolution ~= nil then
        local level, levelError = p.exact(
            record.levelResolution,
            { "offeredTargets", "selectedTarget", "levelCount" },
            {},
            label .. ".levelResolution"
        )
        if not level then return nil, levelError end
        local _, targetsError = p.strings(
            level.offeredTargets,
            label .. ".levelResolution.offeredTargets",
            3
        )
        if targetsError then return nil, targetsError end
        if not p.json.isNull(level.selectedTarget)
            and not p.str(level.selectedTarget, label .. ".levelResolution.selectedTarget") then
            return p.fail(label .. " has invalid selected target")
        end
        if not p.int(level.levelCount, label .. ".levelResolution.levelCount", 0) then
            return p.fail(label .. " has invalid level count")
        end
    end
    return record
end

function rewards.roles(value, label)
    local rows, errorMessage = p.arr(value, label)
    if not rows then return nil, errorMessage end
    for index, valueRow in ipairs(rows) do
        local _, roleError = rewards.acquisitionRole(valueRow, label .. "[" .. index .. "]")
        if roleError then return nil, roleError end
    end
    return rows
end

function rewards.equip(value, label)
    local record, errorMessage = p.exact(
        value,
        {},
        { "jeweledPom", "experimentalHammer", "transcendentEmbryo" },
        label
    )
    if not record then return nil, errorMessage end
    if record.jeweledPom ~= nil then
        local pom, pomError = p.exact(
            record.jeweledPom,
            { "traitKey" },
            { "rarity", "runtimeFallbacks" },
            label .. ".jeweledPom"
        )
        if not pom then return nil, pomError end
        if not p.str(pom.traitKey, label .. ".jeweledPom.traitKey")
            or (pom.rarity ~= nil and not p.str(pom.rarity, label .. ".jeweledPom.rarity")) then
            return p.fail(label .. " has invalid jeweled Pom result")
        end
        if pom.runtimeFallbacks ~= nil then
            local _, fallbackError = rewards.fallbacks(
                pom.runtimeFallbacks,
                label .. ".jeweledPom.runtimeFallbacks"
            )
            if fallbackError then return nil, fallbackError end
        end
    end
    if record.experimentalHammer ~= nil then
        local hammer, hammerError = p.obj(record.experimentalHammer, label .. ".experimentalHammer")
        if not hammer then return nil, hammerError end
        if hammer.kind == "selected" then
            local selected, selectedError = p.exact(
                hammer,
                { "kind", "traitKey" },
                {},
                label .. ".experimentalHammer"
            )
            if not selected then return nil, selectedError end
            if not p.str(selected.traitKey, label .. ".experimentalHammer.traitKey") then
                return p.fail(label .. " has invalid experimental Hammer result")
            end
        elseif hammer.kind == "exhausted" then
            local _, exhaustedError = p.exact(
                hammer,
                { "kind" },
                {},
                label .. ".experimentalHammer"
            )
            if exhaustedError then return nil, exhaustedError end
        else
            return p.fail(label .. " has unsupported experimental Hammer result")
        end
    end
    if record.transcendentEmbryo ~= nil then
        local embryo, embryoError = p.exact(
            record.transcendentEmbryo,
            { "blessingKey", "blessingValues" },
            {},
            label .. ".transcendentEmbryo"
        )
        if not embryo then return nil, embryoError end
        if not p.str(embryo.blessingKey, label .. ".transcendentEmbryo.blessingKey") then
            return p.fail(label .. " has invalid Embryo result")
        end
        local _, valuesError = p.recordNumbers(
            embryo.blessingValues,
            label .. ".transcendentEmbryo.blessingValues"
        )
        if valuesError then return nil, valuesError end
    end
    return record
end

return rewards
