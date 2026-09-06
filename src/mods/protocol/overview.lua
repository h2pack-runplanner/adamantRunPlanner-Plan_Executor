local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")
local rewards = type(import) == "function" and import("mods/protocol/rewards.lua")
    or require("mods.protocol.rewards")

local overview = {}
local generationKeys = {
    ["initial:healing"] = true,
    ["initial:secondLeft"] = true,
    ["initial:secondRight"] = true,
    travelDealRefill = true,
}
local shrineGenerationKeys = {
    ["initial:first"] = true,
    ["initial:secondLeft"] = true,
    ["initial:secondRight"] = true,
}

local function shop(value, label)
    local record, errorMessage = p.exact(
        value, { "profileKey", "offers" }, { "travelDealRefill", "infernalContract" }, label
    )
    if not record then return nil, errorMessage end
    if not p.str(record.profileKey, label .. ".profileKey") then
        return p.fail(label .. " has invalid profileKey")
    end
    local offers, offersError = p.arr(record.offers, label .. ".offers")
    if not offers then return nil, offersError end
    for index, valueRow in ipairs(offers) do
        local row, rowError = p.exact(
            valueRow,
            { "offerKey", "optionKey", "rewardType" },
            { "source", "spurnedSource" },
            label .. ".offers[" .. index .. "]"
        )
        if not row then return nil, rowError end
        for _, key in ipairs({ "offerKey", "optionKey", "rewardType" }) do
            if not p.str(row[key], label .. ".offers." .. key) then
                return p.fail(label .. " has invalid shop offer")
            end
        end
        for _, key in ipairs({ "source", "spurnedSource" }) do
            if row[key] ~= nil and not p.str(row[key], label .. ".offers." .. key) then
                return p.fail(label .. " has invalid shop offer")
            end
        end
    end
    if record.infernalContract ~= nil then
        local contract, contractError = p.exact(
            record.infernalContract, { "sourceOwner", "rewardType" }, {}, label .. ".infernalContract"
        )
        if not contract then return nil, contractError end
        if not p.str(contract.sourceOwner, label .. ".infernalContract.sourceOwner", p.MAX_OWNER_STRING)
            or not p.str(contract.rewardType, label .. ".infernalContract.rewardType") then
            return p.fail(label .. " has invalid Infernal Contract pedestal")
        end
    end
    if record.travelDealRefill ~= nil then
        local refill, refillError = p.exact(
            record.travelDealRefill,
            { "sourceOfferKey", "sourceOwner", "slotIndex", "groupIndex", "optionKey", "reward" },
            {},
            label .. ".travelDealRefill"
        )
        if not refill then return nil, refillError end
        if not p.str(refill.sourceOfferKey, label .. ".travelDealRefill.sourceOfferKey")
            or not p.str(refill.sourceOwner, label .. ".travelDealRefill.sourceOwner", p.MAX_OWNER_STRING)
            or not p.int(refill.slotIndex, label .. ".travelDealRefill.slotIndex", 0)
            or not p.int(refill.groupIndex, label .. ".travelDealRefill.groupIndex", 0)
            or not p.str(refill.optionKey, label .. ".travelDealRefill.optionKey") then
            return p.fail(label .. " has invalid Travel Deal refill")
        end
        local _, rewardError = rewards.reward(refill.reward, label .. ".travelDealRefill.reward")
        if rewardError then return nil, rewardError end
    end
    return record
end

local function stygianWell(value, label)
    local record, errorMessage = p.exact(value, { "interacted" }, { "offers" }, label)
    if not record then return nil, errorMessage end
    if not p.bool(record.interacted, label .. ".interacted")
        or record.interacted ~= (record.offers ~= nil) then
        return p.fail(label .. " has invalid interaction state")
    end
    if record.offers == nil then return record end
    local offers, offersError = p.arr(record.offers, label .. ".offers")
    if not offers then return nil, offersError end
    local seen = {}
    for index, valueRow in ipairs(offers) do
        local row, rowError = p.exact(
            valueRow,
            { "generationKey", "offerKey" },
            { "twistResultKey" },
            label .. ".offers[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.one(row.generationKey, generationKeys, label .. ".generationKey")
            or seen[row.generationKey]
            or not p.str(row.offerKey, label .. ".offerKey")
            or (row.twistResultKey ~= nil and not p.str(row.twistResultKey, label .. ".twistResultKey")) then
            return p.fail(label .. " has invalid Well offer")
        end
        seen[row.generationKey] = true
    end
    return record
end

local function shrinePurchase(value, label)
    local row, errorMessage = p.exact(value, { "roomDelay", "rushed" }, {}, label)
    if not row then return nil, errorMessage end
    if not p.int(row.roomDelay, label .. ".roomDelay", 2)
        or row.roomDelay > 8
        or not p.bool(row.rushed, label .. ".rushed") then
        return p.fail(label .. " has invalid purchase disposition")
    end
    return row
end

local function hermesShrine(value, label)
    local record, errorMessage = p.exact(value, { "offers" }, { "travelDealRefill" }, label)
    if not record then return nil, errorMessage end
    local offers, offersError = p.arr(record.offers, label .. ".offers")
    if not offers then return nil, offersError end
    if #offers ~= 3 then return p.fail(label .. " must publish three offers") end
    local seen = {}
    for index, valueRow in ipairs(offers) do
        local row, rowError = p.exact(
            valueRow,
            { "generationKey", "optionKey", "rewardType", "slotIndex" },
            { "purchase", "deliverySourceKey" },
            label .. ".offers[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.one(row.generationKey, shrineGenerationKeys, label .. ".generationKey")
            or seen[row.generationKey]
            or row.generationKey ~= ({
                [1] = "initial:first", [2] = "initial:secondLeft", [3] = "initial:secondRight",
            })[index]
            or row.slotIndex ~= index
            or not p.int(row.slotIndex, label .. ".slotIndex", 1)
            or row.slotIndex > 3
            or not p.str(row.optionKey, label .. ".optionKey")
            or not p.str(row.rewardType, label .. ".rewardType") then
            return p.fail(label .. " has invalid Shrine offer")
        end
        if row.deliverySourceKey ~= nil
            and not p.str(row.deliverySourceKey, label .. ".deliverySourceKey", p.MAX_OWNER_STRING) then
            return p.fail(label .. " has invalid Shrine delivery source")
        end
        if (row.purchase == nil) ~= (row.deliverySourceKey == nil) then
            return p.fail(label .. " purchase and delivery source must be paired")
        end
        if row.purchase ~= nil then
            local _, purchaseError = shrinePurchase(row.purchase, label .. ".offers[" .. index .. "].purchase")
            if purchaseError then return nil, purchaseError end
        end
        seen[row.generationKey] = true
    end
    if record.travelDealRefill ~= nil then
        local refill, refillError = p.exact(
            record.travelDealRefill,
            { "sourceGenerationKey", "slotIndex", "optionKey", "rewardType" },
            { "purchase", "deliverySourceKey" },
            label .. ".travelDealRefill"
        )
        if not refill then return nil, refillError end
        local expectedSlot = ({
            ["initial:first"] = 1, ["initial:secondLeft"] = 2, ["initial:secondRight"] = 3,
        })
            [refill.sourceGenerationKey]
        if not p.one(refill.sourceGenerationKey, shrineGenerationKeys, label .. ".sourceGenerationKey")
            or not p.int(refill.slotIndex, label .. ".slotIndex", 1)
            or refill.slotIndex > 3
            or refill.slotIndex ~= expectedSlot
            or not p.str(refill.optionKey, label .. ".optionKey")
            or not p.str(refill.rewardType, label .. ".rewardType") then
            return p.fail(label .. " has invalid Travel Deal refill")
        end
        if refill.deliverySourceKey ~= nil
            and not p.str(refill.deliverySourceKey, label .. ".deliverySourceKey", p.MAX_OWNER_STRING) then
            return p.fail(label .. " has invalid refill delivery source")
        end
        if (refill.purchase == nil) ~= (refill.deliverySourceKey == nil) then
            return p.fail(label .. " purchase and delivery source must be paired")
        end
        if refill.purchase ~= nil then
            local _, purchaseError = shrinePurchase(refill.purchase, label .. ".purchase")
            if purchaseError then return nil, purchaseError end
        end
    end
    return record
end

local function purgingPool(value, label)
    local record, errorMessage = p.exact(value, { "interacted" }, { "traits" }, label)
    if not record then return nil, errorMessage end
    if not p.bool(record.interacted, label .. ".interacted")
        or record.interacted ~= (record.traits ~= nil) then
        return p.fail(label .. " has invalid interaction state")
    end
    if record.traits == nil then return record end
    local traits, traitsError = p.arr(record.traits, label .. ".traits", 3)
    if not traits then return nil, traitsError end
    local seen = {}
    for index, valueRow in ipairs(traits) do
        local row, rowError = p.exact(
            valueRow,
            { "slotKey", "traitKey" },
            {},
            label .. ".traits[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.one(row.slotKey, { left = true, middle = true, right = true }, label .. ".slotKey")
            or seen[row.slotKey]
            or (not p.json.isNull(row.traitKey) and not p.str(row.traitKey, label .. ".traitKey")) then
            return p.fail(label .. " has invalid trait row")
        end
        seen[row.slotKey] = true
    end
    return record
end

local function additional(value, label)
    local rows, errorMessage = p.arr(value, label)
    if not rows then return nil, errorMessage end
    for index, valueRow in ipairs(rows) do
        local row, rowError = p.exact(
            valueRow,
            { "kind", "owner", "room" },
            { "ixionOrigin" },
            label .. "[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.one(row.kind, { chaos = true, zagreusContract = true }, label .. ".kind")
            or not p.str(row.owner, label .. ".owner", p.MAX_OWNER_STRING)
            or not p.roomRef(row.room, label .. ".room") then
            return p.fail(label .. " has invalid additional exit")
        end
        if row.ixionOrigin ~= nil then
            local origin, originError = p.exact(
                row.ixionOrigin,
                { "sourceBiomeKey", "sourceOccurrenceId", "generationKey" },
                {},
                label .. ".ixionOrigin"
            )
            if not origin then return nil, originError end
            if not p.str(origin.sourceBiomeKey, label .. ".ixionOrigin.sourceBiomeKey")
                or not p.str(origin.sourceOccurrenceId, label .. ".ixionOrigin.sourceOccurrenceId", 256)
                or not p.str(origin.generationKey, label .. ".ixionOrigin.generationKey") then
                return p.fail(label .. " has invalid Ixion origin")
            end
        end
    end
    return rows
end

function overview.decode(value, label)
    local record, errorMessage = p.exact(
        value,
        { "encounterPhases", "requiredObjects" },
        {
            "incomingReward", "effectNeutralRequiredReward", "unmodeledEncounterKeys",
            "shop", "hermesShrine", "stygianWell",
            "purgingPool", "keepsakeRack",
            "fountain", "additional",
        },
        label
    )
    if not record then return nil, errorMessage end
    local phases, phasesError = p.arr(record.encounterPhases, label .. ".encounterPhases")
    if not phases then return nil, phasesError end
    if record.unmodeledEncounterKeys ~= nil then
        local _, keysError = p.strings(record.unmodeledEncounterKeys, label .. ".unmodeledEncounterKeys")
        if keysError then return nil, keysError end
        if #record.unmodeledEncounterKeys == 0 then
            return p.fail(label .. ".unmodeledEncounterKeys must be non-empty when present")
        end
        if #phases > 0 then return p.fail(label .. ".unmodeledEncounterKeys cannot coexist with modeled phases") end
    end
    local _, objectsError = p.strings(record.requiredObjects, label .. ".requiredObjects")
    if objectsError then return nil, objectsError end
    for index, valueRow in ipairs(phases) do
        local phaseLabel = label .. ".encounterPhases[" .. index .. "]"
        local row, rowError = p.exact(
            valueRow,
            { "slotKey", "encounterKey", "kind" },
            { "figLeafSkip" },
            phaseLabel
        )
        if not row then return nil, rowError end
        if not p.str(row.slotKey, phaseLabel .. ".slotKey")
            or not p.str(row.encounterKey, phaseLabel .. ".encounterKey")
            or not p.str(row.kind, phaseLabel .. ".kind") then
            return p.fail(phaseLabel .. " has invalid encounter phase")
        end
        if row.figLeafSkip ~= nil then
            local _, figLeafError = p.bool(row.figLeafSkip, phaseLabel .. ".figLeafSkip")
            if figLeafError then return nil, figLeafError end
        end
    end
    if record.incomingReward ~= nil then
        local _, rewardError = rewards.reward(record.incomingReward, label .. ".incomingReward")
        if rewardError then return nil, rewardError end
    end
    if record.effectNeutralRequiredReward ~= nil
        and (not p.bool(record.effectNeutralRequiredReward, label .. ".effectNeutralRequiredReward")
            or record.effectNeutralRequiredReward ~= true) then
        return p.fail(label .. ".effectNeutralRequiredReward must be true when present")
    end
    if record.shop ~= nil then
        local _, shopError = shop(record.shop, label .. ".shop")
        if shopError then return nil, shopError end
    end
    if record.hermesShrine ~= nil then
        local _, shrineError = hermesShrine(record.hermesShrine, label .. ".hermesShrine")
        if shrineError then return nil, shrineError end
    end
    if record.stygianWell ~= nil then
        local _, wellError = stygianWell(record.stygianWell, label .. ".stygianWell")
        if wellError then return nil, wellError end
    end
    if record.purgingPool ~= nil then
        local _, poolError = purgingPool(record.purgingPool, label .. ".purgingPool")
        if poolError then return nil, poolError end
    end
    if record.keepsakeRack ~= nil then
        local rack, rackError = p.exact(
            record.keepsakeRack,
            {},
            { "keepsakeKey" },
            label .. ".keepsakeRack"
        )
        if not rack then return nil, rackError end
        if rack.keepsakeKey ~= nil and not p.str(rack.keepsakeKey, label .. ".keepsakeKey") then
            return p.fail(label .. " has invalid keepsake Rack")
        end
    end
    if record.fountain ~= nil then
        local fountain, fountainError = p.exact(
            record.fountain,
            {},
            { "aromaticPhialTarget" },
            label .. ".fountain"
        )
        if not fountain then return nil, fountainError end
        if fountain.aromaticPhialTarget ~= nil
            and not p.str(fountain.aromaticPhialTarget, label .. ".aromaticPhialTarget") then
            return p.fail(label .. " has invalid fountain")
        end
    end
    if record.additional ~= nil then
        local _, additionalError = additional(record.additional, label .. ".additional")
        if additionalError then return nil, additionalError end
    end
    return record
end

return overview
