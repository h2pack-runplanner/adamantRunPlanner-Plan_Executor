-- Deterministic room-feature inventory construction from
-- the active occurrence Overview. Vanilla still owns costs and item records.
local inventory = {}
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")

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

local function retainAndCount(values, expected)
    local result, matches = {}, 0
    for _, value in pairs(values or {}) do
        local key = type(value) == "table" and (value.Name or value.ItemName) or value
        if expected[key] then
            result[#result + 1] = value
            matches = matches + 1
        end
    end
    return result, matches
end

local function generatedName(offer)
    local key = offer.optionKey or offer.offerKey
    local carrier = nativeBindings.roomFeatures.shopOptionCarriers[key]
    return carrier and carrier.name or key
end

local function hasCarrierMarker(option, carrier)
    if type(option) ~= "table" or type(carrier) ~= "table" then return false end
    local args = option.Args
    for _, key in ipairs(carrier.argsMarkers or {}) do
        if type(args) == "table" and args[key] ~= nil then return true end
    end
    return false
end

local function generatedMatches(option, offer)
    local observed = type(option) == "table" and (option.Name or option.ItemName) or option
    if observed ~= generatedName(offer) then return false end
    local key = offer.optionKey or offer.offerKey
    local carrier = nativeBindings.roomFeatures.shopOptionCarriers[key]
    if carrier ~= nil then return hasCarrierMarker(option, carrier) end
    for _, candidate in pairs(nativeBindings.roomFeatures.shopOptionCarriers) do
        if candidate.name == observed and hasCarrierMarker(option, candidate) then return false end
    end
    return true
end

local function retainRawOffers(values, offers)
    local wanted, seen = {}, {}
    for _, offer in ipairs(offers or {}) do wanted[offer.optionKey or offer.offerKey] = true end
    local result = {}
    for _, value in pairs(values or {}) do
        local key = type(value) == "table" and (value.Name or value.ItemName) or value
        if wanted[key] then
            result[#result + 1] = value
            seen[key] = true
        end
    end
    local matchesFound = 0
    for _ in pairs(seen) do matchesFound = matchesFound + 1 end
    return result, matchesFound
end

function inventory.prepare(occurrence, args, refillOnly, contractOnly)
    local expected = occurrence and occurrence.overview or {}
    local shop, well = expected.shop, expected.stygianWell
    local storeData = copy(type(args) == "table" and args.StoreData or nil)
    if type(storeData) ~= "table" then return nil end
    if refillOnly and shop and shop.travelDealRefill then
        local refill = copy(shop.travelDealRefill)
        local group = storeData.GroupsOf and storeData.GroupsOf[refill.groupIndex + 1]
        if type(group) ~= "table" then
            return nil, { checkpoint = "shop-refill-group", expected = refill.groupIndex }
        end
        if group.OptionsData then group.OptionsData = retainRawOffers(group.OptionsData, { refill }) end
        if group.Options then group.Options = retainRawOffers(group.Options, { refill }) end
        group.Offers = 1
        storeData.GroupsOf = { group }
        local result = copy(args or {})
        result.StoreData = storeData
        return { kind = "shopRefill", expected = { refill }, args = result }
    end
    if contractOnly and shop and shop.infernalContract then
        if type(storeData.GroupsOf) ~= "table" then return nil end
        local contract = copy(shop.infernalContract)
        local wanted = { [contract.rewardType] = true }
        local matchedCount = 0
        for _, group in ipairs(storeData.GroupsOf) do
            if type(group) == "table" then
                if group.OptionsData then
                    local count
                    group.OptionsData, count = retainAndCount(group.OptionsData, wanted)
                    matchedCount = matchedCount + count
                end
                if group.Options then
                    local count
                    group.Options, count = retainAndCount(group.Options, wanted)
                    matchedCount = matchedCount + count
                end
            end
        end
        if matchedCount == 0 then
            return nil, { checkpoint = "contract-inventory", expected = contract.rewardType, observed = nil }
        end
        local result = copy(args or {})
        result.StoreData = storeData
        return { kind = "contract", expected = { contract }, args = result }
    end
    if contractOnly then return nil end
    if shop ~= nil then
        if type(storeData.GroupsOf) ~= "table" then return nil end
        local expectedOffers = {}
        for index, rawOffer in ipairs(shop.offers or {}) do
            local offer = copy(rawOffer)
            expectedOffers[index] = offer
        end
        local matchedCount = 0
        for _, group in ipairs(storeData.GroupsOf) do
            if type(group) == "table" then
                if group.OptionsData then
                    local count
                    group.OptionsData, count = retainRawOffers(group.OptionsData, expectedOffers)
                    matchedCount = matchedCount + count
                end
                if group.Options then
                    local count
                    group.Options, count = retainRawOffers(group.Options, expectedOffers)
                    matchedCount = matchedCount + count
                end
            end
        end
        if matchedCount < #expectedOffers then
            return nil, {
                checkpoint = "shop-inventory-offer", expected = #expectedOffers, observed = matchedCount,
            }
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
    if prepared == nil or (prepared.kind ~= "well" and prepared.kind ~= "shop") or type(store) ~= "table"
        or type(store.StoreOptions) ~= "table" then return store end
    local ordered, used = {}, {}
    for _, offer in ipairs(prepared.expected) do
        local found
        for index, option in ipairs(store.StoreOptions) do
            if not used[index] and generatedMatches(option, offer) then
                used[index] = true
                found = option
                break
            end
        end
        if found == nil then return store end
        ordered[#ordered + 1] = found
    end
    store.StoreOptions = ordered
    return store
end

function inventory.placeRefill(prepared, store)
    if prepared == nil or prepared.kind ~= "shopRefill" or type(store) ~= "table"
        or type(store.StoreOptions) ~= "table" then return store end
    local option = store.StoreOptions[1]
    if option == nil then return store end
    store.StoreOptions = { [prepared.expected[1].slotIndex + 1] = option }
    return store
end

function inventory.verify(prepared, store)
    if prepared == nil then return true end
    if type(store) ~= "table" or type(store.StoreOptions) ~= "table" then
        return nil, { checkpoint = "inventory-generation", expected = prepared.kind, observed = nil }
    end
    if prepared.kind == "contract" then
        local contract = prepared.expected[1]
        local option = store.StoreOptions[1]
        local observedKey = type(option) == "table" and (option.Name or option.ItemName) or nil
        if observedKey ~= contract.rewardType then
            return nil, { checkpoint = "contract-inventory", expected = contract.rewardType, observed = observedKey }
        end
        option.__runPlannerContractSourceOwner = contract.sourceOwner
        return true
    end
    local offset = prepared.kind == "shopRefill" and prepared.expected[1].slotIndex or 0
    for index, offer in ipairs(prepared.expected) do
        local option = store.StoreOptions[index + offset]
        local expectedKey = offer.optionKey or offer.offerKey
        local observedKey = type(option) == "table" and (option.Name or option.ItemName) or nil
        if not generatedMatches(option, offer) then
            return nil, { checkpoint = "inventory-generation", expected = expectedKey, observed = observedKey }
        end
        option.__runPlannerOfferKey = offer.offerKey or offer.sourceOfferKey or expectedKey
        option.__runPlannerPaidShopOffer = prepared.kind == "shop" or nil
        option.__runPlannerGenerationKey = offer.generationKey
            or (prepared.kind == "shopRefill" and "travelDealRefill" or nil)
        option.__runPlannerSourceOwner = prepared.kind == "shopRefill" and offer.sourceOwner or nil
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
