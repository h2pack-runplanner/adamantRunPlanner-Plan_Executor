-- World Shop inventory, Travel Deal refill, and Infernal Contract inventory.
local primitives = type(import) == "function"
    and import("mods/room/features/inventory/primitives.lua")
    or require("mods.room.features.inventory.primitives")
local worldShop = {}

function worldShop.prepareRefill(shop, storeData, args, scope)
    if scope == nil or scope.kind ~= "shop" or shop == nil or shop.travelDealRefill == nil then return nil end
    local refill = primitives.copy(shop.travelDealRefill)
    local group = storeData.GroupsOf and storeData.GroupsOf[refill.groupIndex + 1]
    if type(group) ~= "table" then
        return nil, { checkpoint = "shop-refill-group", expected = refill.groupIndex }
    end
    if group.OptionsData then
        group.OptionsData = primitives.retainRawOffers(group.OptionsData, { refill })
    end
    if group.Options then group.Options = primitives.retainRawOffers(group.Options, { refill }) end
    group.Offers = 1
    storeData.GroupsOf = { group }
    return { kind = "shopRefill", expected = { refill }, args = primitives.withStoreData(args, storeData) }
end

function worldShop.prepareContract(shop, storeData, args)
    if shop == nil or shop.infernalContract == nil then return nil end
    if type(storeData.GroupsOf) ~= "table" then return nil end
    local contract = primitives.copy(shop.infernalContract)
    local wanted = { [contract.rewardType] = true }
    local matchedCount = 0
    for _, group in ipairs(storeData.GroupsOf) do
        if type(group) == "table" then
            if group.OptionsData then
                local count
                group.OptionsData, count = primitives.retainAndCount(group.OptionsData, wanted)
                matchedCount = matchedCount + count
            end
            if group.Options then
                local count
                group.Options, count = primitives.retainAndCount(group.Options, wanted)
                matchedCount = matchedCount + count
            end
        end
    end
    if matchedCount == 0 then
        return nil, { checkpoint = "contract-inventory", expected = contract.rewardType, observed = nil }
    end
    return { kind = "contract", expected = { contract }, args = primitives.withStoreData(args, storeData) }
end

function worldShop.prepare(shop, storeData, args)
    if shop == nil then return nil end
    if type(storeData.GroupsOf) ~= "table" then return nil end
    local expectedOffers = {}
    for index, rawOffer in ipairs(shop.offers or {}) do
        expectedOffers[index] = primitives.copy(rawOffer)
    end
    local matchedCount = primitives.filterGroups(storeData, expectedOffers)
    if matchedCount < #expectedOffers then
        return nil, {
            checkpoint = "shop-inventory-offer", expected = #expectedOffers, observed = matchedCount,
        }
    end
    return { kind = "shop", expected = expectedOffers, args = primitives.withStoreData(args, storeData) }
end

return worldShop
