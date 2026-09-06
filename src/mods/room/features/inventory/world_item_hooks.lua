-- World Shop refill/contract construction and stable binding of materialized
-- world items for later Timeline-owned acquisition or purchase contacts.
local current = type(import) == "function"
    and import("mods/room/features/inventory/current.lua")
    or require("mods.room.features.inventory.current")
local hooks = {}

local function materializedHandle(state, active, room, root, itemKey)
    if root == nil or itemKey == nil then return root end
    return room.resolve(state, active, {
        kind = "materialized", source = root, gameName = itemKey,
    }) or root
end

function hooks.attach(module, session, getState, report, room, route, scope)
    local worldItemsById = {}

    module.hooks.wrap("RestockWorldItem", "run-planner-travel-deal-refill", function(_, runtime, base, index,
        kitId, args)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local refill = active and active.occurrence.overview.shop
            and active.occurrence.overview.shop.travelDealRefill
        if refill == nil then return base(index, kitId, args) end
        if index ~= refill.slotIndex + 1 then
            session.mismatch(state, "shop-refill-slot", refill.slotIndex + 1, index)
        end
        local prior = scope.worldShopRefill
        scope.worldShopRefill = active and {
            kind = "shop", index = index, kitId = kitId, groupIndex = refill.groupIndex,
        } or nil
        local ok, result = pcall(base, index, kitId, args)
        scope.worldShopRefill = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SpawnZagContractRewards", "run-planner-contract-inventory", function(_, runtime, base,
        nativeRoom, args)
        local prior = scope.contract
        scope.contract = true
        local ok, result = pcall(base, nativeRoom, args)
        scope.contract = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SpawnStoreItemInWorld", "run-planner-bind-world-shop-item", function(_, runtime, base,
        itemData, kitId)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local result = base(itemData, kitId)
        if active and type(itemData) == "table" and result ~= nil then
            local generationKey = itemData.__runPlannerGenerationKey
            local bindingKey = itemData.__runPlannerOfferKey or itemData.Name or itemData.ItemName
            local itemKey = itemData.Name or itemData.ItemName or bindingKey
            local shrineDelivery = itemData.__runPlannerShrine == true
                and itemData.__runPlannerShrineSourceKey ~= nil
            local sourceKey = itemData.__runPlannerShrineSourceKey
            local handle = shrineDelivery and room.resolve(state, active,
                { kind = "hermesShrineDelivery", sourceKey = sourceKey })
                or itemData.__runPlannerSourceOwner and room.resolve(state, active,
                { kind = "source", sourceOwner = itemData.__runPlannerSourceOwner })
                or itemData.__runPlannerContractSourceOwner and room.resolve(state, active,
                { kind = "source", sourceOwner = itemData.__runPlannerContractSourceOwner })
                or generationKey and room.resolve(state, active,
                { kind = "generation", generationKey = generationKey })
                or bindingKey and room.resolve(state, active, { kind = "offer", offerKey = bindingKey }) or nil
            handle = materializedHandle(state, active, room, handle, itemKey)
            handle = room.bind(state, active, handle, result)
            -- Refill materializes before its acquisition dependency is ready;
            -- only preserve its exact native-object binding here.
            local payload = not shrineDelivery and itemData.__runPlannerSourceOwner == nil
                and handle and room.begin(state, handle) or nil
            if payload and payload.transaction.kind == "wellRefill" then session.complete(state, handle) end
            local paid = itemData.__runPlannerPaidShopOffer == true
            local sourceOwned = itemData.__runPlannerSourceOwner ~= nil
            if type(result) == "table" and result.ObjectId ~= nil and (handle ~= nil or paid) then
                worldItemsById[result.ObjectId] = {
                    handle = handle, bindingKey = bindingKey, itemKey = itemKey,
                    paid = paid, sourceOwned = sourceOwned, shrineDelivery = shrineDelivery,
                }
            end
        end
        report(runtime)
        return result
    end)

    return {
        find = function(objectId) return worldItemsById[objectId] end,
        forget = function(objectId) worldItemsById[objectId] = nil end,
    }
end

return hooks
