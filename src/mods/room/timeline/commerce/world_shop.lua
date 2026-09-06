-- World Shop purchase settlement over feature-owned materialized item bindings.
local primitives = type(import) == "function"
    and import("mods/room/timeline/commerce/primitives.lua")
    or require("mods.room.timeline.commerce.primitives")
local worldShop = {}

function worldShop.attach(module, session, getState, report, room, inventoryBindings)
    module.hooks.wrap("RemoveStoreItem", "run-planner-world-shop-purchase", function(_, runtime, base, args)
        local state = getState(runtime)
        local binding = type(args) == "table" and inventoryBindings.find(args.Id) or nil
        local handle = binding and binding.handle
        local preview = handle and room.peek(state, handle) or nil
        local payload = preview and preview.transaction.kind == "shopPurchase"
            and room.begin(state, handle) or nil
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local before = nativeRoom and nativeRoom.StoreItemsPurchased or 0
        local result = base(args)
        local after = nativeRoom and nativeRoom.StoreItemsPurchased or 0
        local accepted = after == before + 1
        local exactShopHandle = preview and preview.transaction.kind == "shopPurchase"
        if accepted and binding and binding.paid and not binding.sourceOwned and not exactShopHandle then
            session.mismatch(state, "purchase-selection", "authored Shop purchase", binding.bindingKey)
        elseif payload and primitives.completesAtPurchase(payload.transaction) then
            if not accepted or not primitives.shopBinding(payload, binding.bindingKey) then
                session.mismatch(state, "purchase-selection", binding.bindingKey, binding.itemKey)
            else
                session.complete(state, handle)
            end
        end
        if type(args) == "table" then inventoryBindings.forget(args.Id) end
        report(runtime)
        return result
    end)
end

return worldShop
