-- Deterministic room-feature inventory construction from
-- the active occurrence Overview. Vanilla still owns costs and item records.
local inventory = {}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function retain(values, expected)
    local result = {}
    for _, value in pairs(values or {}) do
        local key = type(value) == "table" and (value.Name or value.ItemName) or value
        if expected[key] then result[#result + 1] = value end
    end
    return result
end

function inventory.prepare(occurrence, args, refillOnly)
    local expected = occurrence and occurrence.overview or {}
    local shop, well = expected.shop, expected.stygianWell
    local storeData = copy(type(args) == "table" and args.StoreData or nil)
    if type(storeData) ~= "table" then return nil end
    if refillOnly and shop and shop.travelDealRefill then
        local refill = copy(shop.travelDealRefill)
        local group = storeData.GroupsOf and storeData.GroupsOf[refill.slotIndex + 1]
        if type(group) ~= "table" then return nil, { checkpoint = "shop-refill-slot", expected = refill.slotIndex } end
        local wanted = { [refill.optionKey] = true }
        if group.OptionsData then group.OptionsData = retain(group.OptionsData, wanted) end
        if group.Options then group.Options = retain(group.Options, wanted) end
        local result = copy(args or {})
        result.StoreData = storeData
        return { kind = "shopRefill", expected = { refill }, args = result }
    end
    if shop ~= nil then
        if type(storeData.GroupsOf) ~= "table" then return nil end
        local expectedOffers = {}
        for index, rawOffer in ipairs(shop.offers or {}) do
            local offer = copy(rawOffer)
            expectedOffers[index] = offer
            local group = storeData.GroupsOf[index]
            if type(group) ~= "table" then return nil, { checkpoint = "shop-inventory-slot", expected = index } end
            local wanted = { [offer.optionKey] = true }
            if group.OptionsData then group.OptionsData = retain(group.OptionsData, wanted) end
            if group.Options then group.Options = retain(group.Options, wanted) end
        end
        local result = copy(args or {})
        result.StoreData = storeData
        return { kind = "shop", expected = expectedOffers, args = result }
    end
    if well and well.interacted then
        local byGeneration = {}
        for _, rawOffer in ipairs(well.offers or {}) do
            local offer = copy(rawOffer)
            byGeneration[offer.generationKey] = offer
        end
        local healing = byGeneration["initial:healing"]
        local left = byGeneration["initial:secondLeft"]
        local right = byGeneration["initial:secondRight"]
        if not healing or not left or not right then
            return nil, { checkpoint = "well-inventory", expected = "three initial offers" }
        end
        if storeData.HealingOffers and storeData.HealingOffers.WeightedList then
            storeData.HealingOffers.WeightedList = retain(
                storeData.HealingOffers.WeightedList, { [healing.offerKey] = true }
            )
        end
        local wanted = { [left.offerKey] = true, [right.offerKey] = true }
        storeData.Traits = retain(storeData.Traits, wanted)
        storeData.Consumables = retain(storeData.Consumables, wanted)
        local result = copy(args or {})
        result.StoreData = storeData
        return { kind = "well", expected = { healing, left, right }, args = result }
    end
    return nil
end

function inventory.order(prepared, store)
    if prepared == nil or prepared.kind ~= "well" or type(store) ~= "table"
        or type(store.StoreOptions) ~= "table" then return store end
    local byName = {}
    for _, option in ipairs(store.StoreOptions) do byName[option.Name or option.ItemName] = option end
    local ordered = {}
    for _, offer in ipairs(prepared.expected) do
        if byName[offer.offerKey] == nil then return store end
        ordered[#ordered + 1] = byName[offer.offerKey]
    end
    store.StoreOptions = ordered
    return store
end

function inventory.verify(prepared, store)
    if prepared == nil then return true end
    if type(store) ~= "table" or type(store.StoreOptions) ~= "table" then
        return nil, { checkpoint = "inventory-generation", expected = prepared.kind, observed = nil }
    end
    local offset = prepared.kind == "shopRefill" and prepared.expected[1].slotIndex or 0
    for index, offer in ipairs(prepared.expected) do
        local option = store.StoreOptions[index + offset]
        local expectedKey = offer.optionKey or offer.offerKey
        local observedKey = type(option) == "table" and (option.Name or option.ItemName) or nil
        if observedKey ~= expectedKey then
            return nil, { checkpoint = "inventory-generation", expected = expectedKey, observed = observedKey }
        end
        option.__runPlannerOfferKey = offer.offerKey or offer.sourceOfferKey or expectedKey
        option.__runPlannerGenerationKey = offer.generationKey
            or (prepared.kind == "shopRefill" and "travelDealRefill" or nil)
        option.__runPlannerTwistResultKey = offer.twistResultKey
    end
    return true
end

function inventory.applyPool(occurrence, nativeRoom)
    local pool = occurrence and occurrence.overview.purgingPool
    if pool == nil or not pool.interacted or type(nativeRoom) ~= "table"
        or type(nativeRoom.SellOptions) ~= "table" then return true end
    local available, selected = {}, {}
    for _, option in pairs(nativeRoom.SellOptions) do available[option.Name] = option end
    for _, slot in ipairs(pool.traits or {}) do
        if slot.traitKey ~= nil then
            local option = available[slot.traitKey]
            if option == nil then
                return nil, { checkpoint = "purging-pool-inventory",
                    expected = slot.traitKey, observed = nil }
            end
            option.__runPlannerPoolSlotKey = slot.slotKey
            selected[#selected + 1] = option
        end
    end
    nativeRoom.SellOptions = selected
    return true
end

return inventory
