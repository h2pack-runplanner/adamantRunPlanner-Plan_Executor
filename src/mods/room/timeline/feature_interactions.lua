-- Timeline contacts for interacting with already-realized room features.
-- Feature adapters own native inventory construction and expose only stable
-- item bindings; this module owns purchases, sales, uses, and acquired effects.
local carriers = type(import) == "function" and import("mods/room/features/store_carriers.lua")
    or require("mods.room.features.store_carriers")
local hooks = {}

local function current(state, room)
    return room.current(state)
end

local function shopBinding(payload, bindingKey)
    local transaction = payload and payload.transaction
    if transaction == nil or transaction.kind ~= "shopPurchase" then return false end
    -- The planner binds a shop purchase to its authored offer slot.  The
    -- materialized native item is deliberately a separate identity (for
    -- example BlindBoxLoot is the carrier for the Boon offer).
    return transaction.offerKey == bindingKey
end

local function completesAtPurchase(node)
    for _, role in ipairs(node and node.roles or {}) do
        if role.lifecyclePoint ~= "purchase" or role.traitOffer ~= nil or role.levelResolution ~= nil then
            return false
        end
    end
    return true
end

-- A world item represents its declared materialized role when one exists.
local function materializedHandle(state, active, room, root, itemKey)
    if root == nil or itemKey == nil then return root end
    return room.resolve(state, active, {
        kind = "materialized", source = root, gameName = itemKey,
    }) or root
end

function hooks.attach(module, session, getState, report, room, inventoryBindings)
    local pendingTwist

    module.hooks.wrap("HandleStorePurchase", "run-planner-store-purchase", function(_, runtime, base, screen,
        button, args)
        local state = getState(runtime)
        local active = current(state, room)
        local item = type(button) == "table" and (button.Data or button) or nil
        local generationKey = item and item.__runPlannerGenerationKey
        local bindingKey = item and (item.__runPlannerOfferKey or item.Name or item.ItemName)
        local itemKey = item and (item.Name or item.ItemName or bindingKey)
        local handle = active and room.resolve(state, active, generationKey
            and { kind = "generation", generationKey = generationKey }
            or { kind = "offer", offerKey = bindingKey }) or nil
        handle = materializedHandle(state, active, room, handle, itemKey)
        handle = room.bind(state, active, handle, item)
        local payload = handle and room.begin(state, handle) or nil
        pendingTwist = item and item.__runPlannerTwistResultKey
        local purchasesBefore = _G.CurrentRun and _G.CurrentRun.WellPurchases
        local ok, result = pcall(base, screen, button, args)
        pendingTwist = nil
        if not ok then error(result, 0) end
        local purchasesAfter = _G.CurrentRun and _G.CurrentRun.WellPurchases
        local transaction = payload and payload.transaction
        local purchased = payload ~= nil and (transaction.kind ~= "wellPurchase"
            or type(purchasesBefore) ~= "number" or purchasesAfter == purchasesBefore + 1)
        local nativeEligible = transaction == nil or transaction.kind ~= "wellPurchase"
            or carriers.eligible(itemKey, args, true)
        local exact = transaction and (
            transaction.kind == "wellPurchase"
            and transaction.offerKey == itemKey
            or transaction.kind == "shopPurchase"
            and shopBinding(payload, bindingKey)
        )
        if payload and not exact then
            session.mismatch(state, "purchase-selection",
                transaction.kind == "wellPurchase" and transaction.offerKey or transaction.offerKey,
                itemKey or bindingKey)
        elseif transaction and (not nativeEligible or not purchased or result == false) then
            session.mismatch(state, "purchase-selection", itemKey,
                not nativeEligible and "native-ineligible" or "native-rejected")
        elseif purchased and completesAtPurchase(transaction) then
            session.complete(state, handle)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetRandomValue", "run-planner-well-twist", function(_, _, base, values, args)
        if pendingTwist and type(values) == "table" then
            for _, value in pairs(values) do
                if type(value) == "table" and value.Name == pendingTwist then return value end
            end
        end
        return base(values, args)
    end)

    module.hooks.wrap("RemoveStoreItem", "run-planner-world-shop-purchase", function(_, runtime, base, args)
        local state = getState(runtime)
        local binding = type(args) == "table" and inventoryBindings.find(args.Id) or nil
        local handle = binding and binding.handle
        local payload = handle and room.begin(state, handle) or nil
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local before = nativeRoom and nativeRoom.StoreItemsPurchased or 0
        local result = base(args)
        local after = nativeRoom and nativeRoom.StoreItemsPurchased or 0
        if payload and payload.transaction.kind == "shopPurchase" and completesAtPurchase(payload.transaction) then
            if after ~= before + 1 or not shopBinding(payload, binding.bindingKey) then
                session.mismatch(state, "purchase-selection", binding.bindingKey, binding.itemKey)
            else
                session.complete(state, handle)
            end
        end
        if type(args) == "table" then inventoryBindings.forget(args.Id) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("HandleSellChoiceSelection", "run-planner-pool-sale", function(_, runtime, base, screen,
        button, args)
        local state = getState(runtime)
        local active = current(state, room)
        local slot = type(button) == "table" and button.__runPlannerPoolSlotKey
        local trait = type(button) == "table" and button.UpgradeName
        local handle = slot and active and room.resolve(state, active, { kind = "slot", slotKey = slot }) or nil
        handle = room.bind(state, active, handle, button)
        local payload = handle and room.begin(state, handle) or nil
        local result = base(screen, button, args)
        if payload then
            if payload.transaction.slotKey ~= slot or payload.transaction.traitKey ~= trait then
                session.mismatch(state, "pool-sale-selection", {
                    slotKey = payload.transaction.slotKey, traitKey = payload.transaction.traitKey,
                }, { slotKey = slot, traitKey = trait })
            else
                session.complete(state, handle)
            end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseHealthFountain", "run-planner-fountain", function(_, runtime, base, source, args)
        local state = getState(runtime)
        local active = current(state, room)
        local handle = active and room.resolve(state, active,
            { kind = "interaction", interactionKey = "fountain" })
        handle = room.bind(state, active, handle, source)
        local payload = handle and room.begin(state, handle) or nil
        local result = base(source, args)
        if payload ~= nil then
            session.complete(state, handle)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GrantElementFromTool", "run-planner-resource", function(_, runtime, base, toolName, args)
        local state = getState(runtime)
        local active = current(state, room)
        local expected
        local tools = { ToolPickaxe2 = "FireEssence", ToolExorcismBook2 = "AirEssence",
            ToolShovel2 = "EarthEssence", ToolFishingRod2 = "WaterEssence" }
        for _, resource in ipairs(active and active.occurrence.overview.resources or {}) do
            if resource.grantedTraitKey == tools[toolName] then expected = resource; break end
        end
        local result = base(toolName, args)
        if expected and result ~= expected.grantedTraitKey then
            session.mismatch(state, "resource-element", expected.grantedTraitKey, result)
        end
        report(runtime)
        return result
    end)
end

return hooks
