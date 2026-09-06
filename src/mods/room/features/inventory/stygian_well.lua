-- Stygian Well inventory and carrier-specific Travel Deal refill construction.
local primitives = type(import) == "function"
    and import("mods/room/features/inventory/primitives.lua")
    or require("mods.room.features.inventory.primitives")
local wellInventory = {}

local function offersByGeneration(well)
    local result = {}
    for _, rawOffer in ipairs(well and well.offers or {}) do
        local offer = primitives.copy(rawOffer)
        result[offer.generationKey] = offer
    end
    return result
end

local function retainOffer(storeData, offer)
    if type(offer) ~= "table" then return false end
    local matched = false
    if storeData.HealingOffers and storeData.HealingOffers.WeightedList then
        local retained, count = primitives.retainAndCount(storeData.HealingOffers.WeightedList,
            { [offer.offerKey] = true })
        storeData.HealingOffers.WeightedList = retained
        matched = matched or count > 0
    end
    local wanted = { [offer.offerKey] = true }
    local retained, count = primitives.retainAndCount(storeData.Traits, wanted)
    storeData.Traits = retained
    matched = matched or count > 0
    retained, count = primitives.retainAndCount(storeData.Consumables, wanted)
    storeData.Consumables = retained
    return matched or count > 0
end

function wellInventory.prepareRefill(well, storeData, args, scope)
    if scope == nil or scope.kind ~= "well" or well == nil or not well.interacted then return nil end
    local refill = offersByGeneration(well)["travelDealRefill"]
    if refill == nil then
        return nil, { checkpoint = "well-refill", expected = "published refill", observed = nil }
    end
    if not retainOffer(storeData, refill) then
        return nil, { checkpoint = "well-refill-inventory", expected = refill.offerKey, observed = nil }
    end
    local expectedRefill = primitives.copy(refill)
    expectedRefill.slotIndex = scope.slotIndex
    return { kind = "wellRefill", expected = { expectedRefill },
        args = primitives.withStoreData(args, storeData) }
end

function wellInventory.prepare(well, storeData, args)
    if well == nil or not well.interacted then return nil end
    local byGeneration = offersByGeneration(well)
    local healing = byGeneration["initial:healing"]
    local left = byGeneration["initial:secondLeft"]
    local right = byGeneration["initial:secondRight"]
    if not healing or not left or not right then
        return nil, { checkpoint = "well-inventory", expected = "three initial offers" }
    end
    if storeData.HealingOffers and storeData.HealingOffers.WeightedList then
        storeData.HealingOffers.WeightedList = primitives.retain(
            storeData.HealingOffers.WeightedList, { [healing.offerKey] = true })
    end
    local wanted = { [left.offerKey] = true, [right.offerKey] = true }
    storeData.Traits = primitives.retain(storeData.Traits, wanted)
    storeData.Consumables = primitives.retain(storeData.Consumables, wanted)
    return { kind = "well", expected = { healing, left, right },
        args = primitives.withStoreData(args, storeData) }
end

return wellInventory
