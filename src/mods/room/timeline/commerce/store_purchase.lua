-- Coordinator for the shared HandleStorePurchase contact. Current authored
-- participation is Stygian Well purchase/refill; native Shop callbacks may
-- pass through this contact without acquiring Well semantics.
local primitives = type(import) == "function"
    and import("mods/room/timeline/commerce/primitives.lua")
    or require("mods.room.timeline.commerce.primitives")
local purchase = {}

function purchase.attach(module, session, getState, report, room, inventoryBindings)
    local materializationScope

    module.hooks.wrap("HandleStorePurchase", "run-planner-store-purchase", function(_, runtime, base, screen,
        button, args)
        local state = getState(runtime)
        local active = room.current(state)
        local item = type(button) == "table" and (button.Data or button) or nil
        local generationKey = item and item.__runPlannerGenerationKey
        local bindingKey = item and (item.__runPlannerOfferKey or item.Name or item.ItemName)
        local itemKey = item and (item.Name or item.ItemName or bindingKey)
        local handle = active and room.resolve(state, active, generationKey
            and { kind = "wellPurchase", generationKey = generationKey }
            or { kind = "offer", offerKey = bindingKey }) or nil
        if handle == nil and active and generationKey ~= nil then
            handle = room.resolve(state, active, { kind = "generation", generationKey = generationKey })
        end
        handle = primitives.materializedHandle(state, active, room, handle, itemKey)
        handle = room.bind(state, active, handle, item)
        local payload = handle and room.begin(state, handle) or nil
        local transaction = payload and payload.transaction
        local refillScope
        local refillHandle
        if transaction and transaction.kind == "wellPurchase"
            and transaction.generationKey ~= "travelDealRefill"
            and inventoryBindings and inventoryBindings.setWellRefillScope then
            local slotIndex = primitives.storeButtonIndex(button, item)
            refillHandle = room.resolve(state, active,
                { kind = "wellRefill", generationKey = "travelDealRefill" })
            local refillPayload = refillHandle and room.peek(state, refillHandle) or nil
            if slotIndex ~= nil and refillPayload and refillPayload.transaction.kind == "wellRefill" then
                refillScope = { kind = "well", slotIndex = slotIndex }
                inventoryBindings.setWellRefillScope(refillScope)
            end
        end
        if transaction and transaction.kind == "wellPurchase"
            and transaction.twistResultKey ~= nil then
            materializationScope = {
                state = state, active = active, handle = handle,
                twistResultKey = transaction.twistResultKey,
                generationKey = transaction.generationKey,
                offerKey = transaction.offerKey,
            }
        end
        local purchasesBefore = transaction and transaction.kind == "wellPurchase"
            and _G.CurrentRun and (_G.CurrentRun.WellPurchases or 0) or nil
        local ok, result = pcall(base, screen, button, args)
        materializationScope = nil
        if inventoryBindings and inventoryBindings.setWellRefillScope then
            inventoryBindings.setWellRefillScope(nil)
        end
        if not ok then error(result, 0) end
        local purchasesAfter = transaction and transaction.kind == "wellPurchase"
            and _G.CurrentRun and _G.CurrentRun.WellPurchases or nil
        local purchased = payload ~= nil and type(purchasesBefore) == "number"
            and purchasesAfter == purchasesBefore + 1
        local exact = transaction and (
            transaction.kind == "wellPurchase" and transaction.offerKey == itemKey
            or transaction.kind == "shopPurchase" and primitives.shopBinding(payload, bindingKey)
        )
        if transaction == nil or transaction.kind ~= "shopPurchase" then
            if payload and not exact then
                session.mismatch(state, "purchase-selection", transaction.offerKey,
                    itemKey or bindingKey)
            elseif transaction and (not purchased or result == false) then
                session.mismatch(state, "purchase-selection", itemKey, "native-rejected")
            elseif purchased and primitives.completesAtPurchase(transaction) then
                session.complete(state, handle)
            end
            if purchased and exact and result ~= false and refillScope and refillHandle ~= nil then
                local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
                local options = nativeRoom and nativeRoom.Store and nativeRoom.Store.StoreOptions
                local replacement = options and options[refillScope.slotIndex]
                if type(replacement) == "table"
                    and replacement.__runPlannerGenerationKey == "travelDealRefill" then
                    local refillPayload = room.begin(state, refillHandle)
                    if refillPayload ~= nil then session.complete(state, refillHandle) end
                end
            end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("CreateConsumableItem", "run-planner-well-purchase-carrier", function(_, runtime, base,
        ...)
        local result = base(...)
        local scope = materializationScope
        if scope ~= nil and type(result) == "table" then
            local source = select(1, ...)
            if type(source) == "table" and type(source.Data) == "table" then source = source.Data end
            local itemKey = type(source) == "table" and (source.Name or source.ItemName) or source
            local resultKey = result.Name or result.ItemName
            if itemKey == "RandomStoreItem" or resultKey == "RandomStoreItem" then
                result.__runPlannerGenerationKey = scope.generationKey
                result.__runPlannerOfferKey = scope.offerKey
                result.__runPlannerTwistResultKey = scope.twistResultKey
                room.bind(scope.state, scope.active, scope.handle, result)
            end
        end
        report(runtime)
        return result
    end)
end

return purchase
