local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")
local rewards = type(import) == "function" and import("mods/protocol/rewards.lua")
    or require("mods.protocol.rewards")

local timeline = {}
local generationKeys = {
    ["initial:healing"] = true,
    ["initial:secondLeft"] = true,
    ["initial:secondRight"] = true,
    travelDealRefill = true,
}
local wellEffects = {
    neutral = true,
    spark = true,
    yarn = true,
    hymn = true,
    discount = true,
    emptySlot = true,
    extended = true,
    twist = true,
    lastStand = true,
}

function timeline.lifecycle(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    if record.kind == "standard" then
        local row, rowError = p.exact(record, { "kind", "phase" }, {}, label)
        if not row then return nil, rowError end
        if not p.one(row.phase, { beforeCombat = true, afterCombat = true }, label .. ".phase") then
            return p.fail(label .. " has unsupported standard phase")
        end
        return row
    end
    if record.kind == "encounterEnd" or record.kind == "bossDefeated" then
        local row, rowError = p.exact(record, { "kind", "phaseKey" }, {}, label)
        if not row then return nil, rowError end
        if not p.str(row.phaseKey, label .. ".phaseKey") then
            return p.fail(label .. " has invalid phaseKey")
        end
        return row
    end
    if record.kind == "postOutgoing" then return p.exact(record, { "kind" }, {}, label) end
    return p.fail(label .. ".kind is unsupported")
end

local function validateBase(record, label)
    if not p.str(record.owner, label .. ".owner", p.MAX_OWNER_STRING) then
        return p.fail(label .. " has invalid owner")
    end
    return timeline.lifecycle(record.window, label .. ".window")
end

local function acquisition(value, label)
    local record, errorMessage = p.exact(
        value,
        { "kind", "owner", "sourceOwner", "reward", "producerLifecycleKey", "roles", "window" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    if not p.str(record.sourceOwner, label .. ".sourceOwner", p.MAX_OWNER_STRING)
        or not p.str(record.producerLifecycleKey, label .. ".producerLifecycleKey") then
        return p.fail(label .. " has invalid acquisition identity")
    end
    local _, rewardError = rewards.reward(record.reward, label .. ".reward")
    if rewardError then return nil, rewardError end
    local _, rolesError = rewards.roles(record.roles, label .. ".roles")
    if rolesError then return nil, rolesError end
    return record
end

local function nemesisOutcome(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    if record.kind == "freeItem" then
        local row, rowError = p.exact(record, { "kind", "itemGameName" }, {}, label)
        if not row then return nil, rowError end
        if not p.str(row.itemGameName, label .. ".itemGameName") then
            return p.fail(label .. " has invalid free-item identity")
        end
        return row
    end
    if record.kind == "goldTrade" or record.kind == "damageTrade" then
        local row, rowError = p.exact(record, { "kind", "response" }, {}, label)
        if not row then return nil, rowError end
        if not p.one(row.response, { accept = true, decline = true }, label .. ".response") then
            return p.fail(label .. " has invalid trade response")
        end
        return row
    end
    if record.kind == "traitTrade" then
        local row, rowError = p.exact(record, { "kind", "traitKey", "response" }, {}, label)
        if not row then return nil, rowError end
        if not p.str(row.traitKey, label .. ".traitKey")
            or not p.one(row.response, { accept = true, decline = true }, label .. ".response") then
            return p.fail(label .. " has invalid trait trade")
        end
        return row
    end
    if record.kind == "damageContest" then
        local row, rowError = p.exact(record, { "kind", "result" }, {}, label)
        if not row then return nil, rowError end
        if not p.one(row.result, { success = true, failure = true }, label .. ".result") then
            return p.fail(label .. " has invalid contest result")
        end
        return row
    end
    return p.fail(label .. " has unsupported Nemesis outcome")
end

local function encounterInteraction(value, label)
    local record, errorMessage = p.exact(
        value,
        { "kind", "owner", "phaseKey", "window" },
        { "resolution" },
        label
    )
    if not record then return nil, errorMessage end
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    if not p.str(record.phaseKey, label .. ".phaseKey") then
        return p.fail(label .. " has invalid phaseKey")
    end
    if record.resolution == nil then return record end
    local resolution, resolutionError = p.obj(record.resolution, label .. ".resolution")
    if not resolution then return nil, resolutionError end
    if resolution.kind == "traitOffer" then
        local row, rowError = p.exact(resolution, { "kind", "offer" }, {}, label .. ".resolution")
        if not row then return nil, rowError end
        local _, offerError = rewards.traitOffer(row.offer, label .. ".resolution.offer")
        if offerError then return nil, offerError end
    elseif resolution.kind == "nemesisRandomEvent" then
        local row, rowError = p.exact(
            resolution,
            { "kind", "outcome" },
            {},
            label .. ".resolution"
        )
        if not row then return nil, rowError end
        local _, outcomeError = nemesisOutcome(row.outcome, label .. ".resolution.outcome")
        if outcomeError then return nil, outcomeError end
    else
        return p.fail(label .. " has unsupported encounter resolution")
    end
    return record
end

local function automatic(value, label)
    local effect = value.effect
    local record, errorMessage
    if effect == "transcendentEmbryo" then
        record, errorMessage = p.exact(
            value,
            {
                "kind", "owner", "effect", "phaseKey", "source", "target", "rarity",
                "blessingValues", "window",
            },
            {},
            label
        )
        if not record then return nil, errorMessage end
        if not p.str(record.source, label .. ".source")
            or not p.str(record.target, label .. ".target")
            or not p.str(record.rarity, label .. ".rarity") then
            return p.fail(label .. " has malformed Embryo automatic outcome")
        end
        local _, valuesError = p.recordNumbers(record.blessingValues, label .. ".blessingValues")
        if valuesError then return nil, valuesError end
    elseif effect == "steadyGrowth" then
        record, errorMessage = p.exact(
            value,
            { "kind", "owner", "effect", "phaseKey", "source", "target", "window" },
            { "rarity" },
            label
        )
        if not record then return nil, errorMessage end
        if not p.str(record.source, label .. ".source")
            or not p.str(record.target, label .. ".target")
            or (record.rarity ~= nil and not p.str(record.rarity, label .. ".rarity")) then
            return p.fail(label .. " has malformed trait automatic outcome")
        end
    elseif effect == "judgment" or effect == "crystalFigurine" then
        record, errorMessage = p.exact(
            value,
            { "kind", "owner", "effect", "phaseKey", "arcanaKeys", "rarity", "window" },
            {},
            label
        )
        if not record then return nil, errorMessage end
        local _, arcanaError = p.strings(record.arcanaKeys, label .. ".arcanaKeys")
        if arcanaError then return nil, arcanaError end
        if not p.str(record.rarity, label .. ".rarity") then
            return p.fail(label .. " has invalid Arcana rarity")
        end
    else
        return p.fail(label .. " has unsupported automatic effect")
    end
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    if not p.str(record.phaseKey, label .. ".phaseKey") then
        return p.fail(label .. " has invalid phaseKey")
    end
    return record
end

local function shopPurchase(value, label)
    local record, errorMessage = p.exact(
        value,
        {
            "kind", "owner", "window", "offerKey", "rewardType", "sourceOwner", "reward",
            "producerLifecycleKey", "roles",
        },
        {},
        label
    )
    if not record then return nil, errorMessage end
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    for _, key in ipairs({ "offerKey", "rewardType", "producerLifecycleKey" }) do
        if not p.str(record[key], label .. "." .. key) then
            return p.fail(label .. " has invalid " .. key)
        end
    end
    if not p.str(record.sourceOwner, label .. ".sourceOwner", p.MAX_OWNER_STRING) then
        return p.fail(label .. " has invalid sourceOwner")
    end
    local _, rewardError = rewards.reward(record.reward, label .. ".reward")
    if rewardError then return nil, rewardError end
    local _, rolesError = rewards.roles(record.roles, label .. ".roles")
    if rolesError then return nil, rolesError end
    for _, role in ipairs(record.roles) do
        if role.seaStarResult ~= nil then
            return p.fail(label .. ".roles may not publish Sea Star results for purchases")
        end
    end
    return record
end

local function validateWell(record, label)
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    if not p.one(record.generationKey, generationKeys, label .. ".generationKey")
        or not p.one(record.effect, wellEffects, label .. ".effect")
        or not p.str(record.offerKey, label .. ".offerKey")
        or (record.twistResultKey ~= nil and not p.str(record.twistResultKey, label .. ".twistResultKey")) then
        return p.fail(label .. " has invalid Well outcome")
    end
    return record
end

local function wellPurchase(value, label)
    local record, errorMessage = p.exact(
        value,
        {
            "kind", "owner", "window", "offerKey", "generationKey", "effect",
            "extendedDirectPurchase",
        },
        { "twistResultKey" },
        label
    )
    if not record then return nil, errorMessage end
    local _, wellError = validateWell(record, label)
    if wellError then return nil, wellError end
    if not p.bool(record.extendedDirectPurchase, label .. ".extendedDirectPurchase") then
        return p.fail(label .. " has invalid Extended marker")
    end
    return record
end

local function wellRefill(value, label)
    local record, errorMessage = p.exact(
        value,
        { "kind", "owner", "window", "generationKey", "offerKey", "effect" },
        { "twistResultKey" },
        label
    )
    if not record then return nil, errorMessage end
    local _, wellError = validateWell(record, label)
    if wellError then return nil, wellError end
    if record.generationKey ~= "travelDealRefill" then
        return p.fail(label .. " must use travelDealRefill")
    end
    return record
end

local function poolSale(value, label)
    local record, errorMessage = p.exact(
        value,
        { "kind", "owner", "window", "slotKey", "traitKey" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    if not p.str(record.slotKey, label .. ".slotKey")
        or not p.str(record.traitKey, label .. ".traitKey") then
        return p.fail(label .. " has invalid sale")
    end
    return record
end

local function keepsakeChange(value, label)
    local record, errorMessage = p.exact(
        value,
        { "kind", "owner", "window", "keepsakeKey" },
        { "equipResults" },
        label
    )
    if not record then return nil, errorMessage end
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    if not p.str(record.keepsakeKey, label .. ".keepsakeKey") then
        return p.fail(label .. " has invalid keepsakeKey")
    end
    if record.equipResults ~= nil then
        local _, equipError = rewards.equip(record.equipResults, label .. ".equipResults")
        if equipError then return nil, equipError end
    end
    return record
end

local function keepsakeReplay(value, label)
    local record, errorMessage = p.exact(
        value,
        { "kind", "owner", "window", "keepsakeKey", "equipResults" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    if not p.str(record.keepsakeKey, label .. ".keepsakeKey") then
        return p.fail(label .. " has invalid keepsakeKey")
    end
    if record.window.kind ~= "standard" or record.window.phase ~= "beforeCombat" then
        return p.fail(label .. ".window must be standard beforeCombat")
    end
    local _, equipError = rewards.equip(record.equipResults, label .. ".equipResults")
    if equipError then return nil, equipError end
    local hasHammer = record.equipResults.experimentalHammer ~= nil
    local hasEmbryo = record.equipResults.transcendentEmbryo ~= nil
    if (hasHammer and hasEmbryo) or (not hasHammer and not hasEmbryo)
        or record.equipResults.jeweledPom ~= nil then
        return p.fail(label .. ".equipResults must contain exactly one volatile replay result")
    end
    return record
end

local function fountainUse(value, label)
    local record, errorMessage = p.exact(
        value,
        { "kind", "owner", "window", "interactionKey" },
        { "aromaticPhialTarget" },
        label
    )
    if not record then return nil, errorMessage end
    local _, baseError = validateBase(record, label)
    if baseError then return nil, baseError end
    if record.interactionKey ~= "fountain" then
        return p.fail(label .. " has invalid fountain interaction key")
    end
    if record.aromaticPhialTarget ~= nil
        and not p.str(record.aromaticPhialTarget, label .. ".aromaticPhialTarget") then
        return p.fail(label .. " has invalid Aromatic Phial target")
    end
    return record
end

local decoders = {
    acquisition = acquisition,
    encounterInteraction = encounterInteraction,
    automatic = automatic,
    shopPurchase = shopPurchase,
    wellPurchase = wellPurchase,
    wellRefill = wellRefill,
    poolSale = poolSale,
    keepsakeChange = keepsakeChange,
    keepsakeReplay = keepsakeReplay,
    fountainUse = fountainUse,
}

function timeline.transaction(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    local decode = decoders[record.kind]
    if not decode then return p.fail(label .. ".kind is unsupported") end
    return decode(record, label)
end

function timeline.decode(value, label, globalOwners)
    local record, errorMessage = p.exact(
        value,
        { "transactions", "dependencies", "obligations" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    local transactions, transactionsError = p.arr(record.transactions, label .. ".transactions")
    if not transactions then return nil, transactionsError end
    local byOwner = {}
    for index, transactionValue in ipairs(transactions) do
        local transactionRecord, transactionError = timeline.transaction(
            transactionValue,
            label .. ".transactions[" .. index .. "]"
        )
        if not transactionRecord then return nil, transactionError end
        if globalOwners[transactionRecord.owner] then
            return p.fail("transaction owners must be globally unique")
        end
        globalOwners[transactionRecord.owner] = true
        byOwner[transactionRecord.owner] = transactionRecord
    end
    local dependencies, dependenciesError = p.arr(record.dependencies, label .. ".dependencies")
    if not dependencies then return nil, dependenciesError end
    local dependencyKeys = {}
    local prerequisites = {}
    for index, dependencyValue in ipairs(dependencies) do
        local dependency, dependencyError = p.exact(
            dependencyValue,
            { "owner", "afterOwner" },
            {},
            label .. ".dependencies[" .. index .. "]"
        )
        if not dependency then return nil, dependencyError end
        if not byOwner[dependency.owner] or not byOwner[dependency.afterOwner]
            or dependency.owner == dependency.afterOwner then
            return p.fail(label .. " has invalid local prerequisite")
        end
        local key = dependency.owner .. "\0" .. dependency.afterOwner
        if dependencyKeys[key] then return p.fail(label .. " has duplicate prerequisite") end
        dependencyKeys[key] = true
        prerequisites[dependency.owner] = prerequisites[dependency.owner] or {}
        prerequisites[dependency.owner][dependency.afterOwner] = true
    end
    local visiting = {}
    local visited = {}
    local function visit(owner)
        if visiting[owner] then return false end
        if visited[owner] then return true end
        visiting[owner] = true
        for prerequisite in pairs(prerequisites[owner] or {}) do
            if not visit(prerequisite) then return false end
        end
        visiting[owner] = nil
        visited[owner] = true
        return true
    end
    for owner in pairs(byOwner) do
        if not visit(owner) then return p.fail(label .. " dependencies contain a cycle") end
    end
    local obligations, obligationsError = p.arr(record.obligations, label .. ".obligations")
    if not obligations then return nil, obligationsError end
    local obligationKeys = {}
    local obligationCounts = {}
    for index, obligationValue in ipairs(obligations) do
        local obligation, obligationError = p.exact(
            obligationValue,
            { "owner", "checkpoint" },
            {},
            label .. ".obligations[" .. index .. "]"
        )
        if not obligation then return nil, obligationError end
        if not p.str(obligation.owner, label .. ".obligation.owner", p.MAX_OWNER_STRING)
            or not byOwner[obligation.owner]
            or not p.one(obligation.checkpoint, {
                roomEntered = true,
                outgoingGeneration = true,
                exitUsable = true,
                roomExit = true,
            }, label .. ".obligation.checkpoint") then
            return p.fail(label .. " has invalid obligation")
        end
        local key = obligation.owner .. "\0" .. obligation.checkpoint
        if obligationKeys[key] then return p.fail(label .. " has duplicate obligation") end
        obligationKeys[key] = true
        obligationCounts[obligation.owner] = (obligationCounts[obligation.owner] or 0) + 1
    end
    for owner in pairs(byOwner) do
        if obligationCounts[owner] ~= 1 then
            return p.fail(label .. " must have exactly one obligation per transaction")
        end
    end
    return record, byOwner
end

return timeline
