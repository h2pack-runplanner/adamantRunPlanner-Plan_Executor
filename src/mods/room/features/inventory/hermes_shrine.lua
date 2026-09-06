-- Hermes Shrine inventory and carrier-specific Travel Deal refill construction.
local primitives = type(import) == "function"
    and import("mods/room/features/inventory/primitives.lua")
    or require("mods.room.features.inventory.primitives")
local shrineInventory = {}

function shrineInventory.prepareRefill(shrine, storeData, args, scope)
    if scope == nil or scope.kind ~= "shrine" or shrine == nil or shrine.travelDealRefill == nil then return nil end
    local refill = primitives.copy(shrine.travelDealRefill)
    local matched, sourceGroup = 0, nil
    for _, group in ipairs(storeData.GroupsOf or {}) do
        if type(group) == "table" then
            local groupMatched = 0
            if group.OptionsData then
                local count
                group.OptionsData, count = primitives.retainRawOffers(group.OptionsData, { refill })
                groupMatched = groupMatched + count
            end
            if group.Options then
                local count
                group.Options, count = primitives.retainRawOffers(group.Options, { refill })
                groupMatched = groupMatched + count
            end
            matched = matched + groupMatched
            if sourceGroup == nil and groupMatched > 0 then sourceGroup = group end
        end
    end
    if matched == 0 then
        return nil, {
            checkpoint = "shrine-refill-inventory", expected = refill.optionKey, observed = nil,
        }
    end
    sourceGroup.Offers = 1
    storeData.GroupsOf = { sourceGroup }
    refill.generationKey = "travelDealRefill"
    refill.sourceGenerationKey = shrine.travelDealRefill.sourceGenerationKey
    refill.slotIndex = scope.slotIndex
    return { kind = "shrineRefill", expected = { refill }, args = primitives.withStoreData(args, storeData) }
end

function shrineInventory.prepare(shrine, storeData, args)
    if shrine == nil then return nil end
    if type(storeData.GroupsOf) ~= "table" then return nil end
    local expectedOffers = {}
    for index, rawOffer in ipairs(shrine.offers or {}) do
        local offer = primitives.copy(rawOffer)
        offer.generationKey = offer.generationKey or ({
            "initial:first", "initial:secondLeft", "initial:secondRight",
        })[index]
        expectedOffers[index] = offer
    end
    local matchedCount = primitives.filterGroups(storeData, expectedOffers)
    if matchedCount < #expectedOffers then
        return nil, {
            checkpoint = "shrine-inventory-offer", expected = #expectedOffers, observed = matchedCount,
        }
    end
    return { kind = "shrine", expected = expectedOffers, args = primitives.withStoreData(args, storeData) }
end

return shrineInventory
