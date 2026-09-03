-- Timeline contacts for interacting with already-realized room features.
-- Feature adapters own native inventory construction and expose only stable
-- item bindings; this module owns purchases, sales, uses, and acquired effects.
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods.native_timeline_adapters")
local carriers = type(import) == "function" and import("mods/room/features/store_carriers.lua")
    or require("mods.room.features.store_carriers")
local hooks = {}

local function current(state, room)
    return room.current(state)
end

local function verifyShopBinding(row, bindingKey, itemKey)
    if row == nil or row.node == nil or row.node.kind ~= "shopPurchase" then return false end
    if row.realizedKey ~= nil then return row.realizedKey == itemKey end
    return row.node.offerKey == bindingKey
end

local function completesAtPurchase(node)
    for _, role in ipairs(node and node.roles or {}) do
        if role.lifecyclePoint ~= "purchase" or role.traitOffer ~= nil or role.levelResolution ~= nil then
            return false
        end
    end
    return true
end

function hooks.attach(module, session, getState, report, room, inventoryBindings)
    local pendingTwist

    module.hooks.wrap("HandleStorePurchase", "execution-v10-store-purchase", function(_, runtime, base, screen,
        button, args)
        local state = getState(runtime)
        local active = current(state, room)
        local item = type(button) == "table" and (button.Data or button) or nil
        local generationKey = item and item.__runPlannerGenerationKey
        local bindingKey = item and (item.__runPlannerOfferKey or item.Name or item.ItemName)
        local itemKey = item and (item.Name or item.ItemName or bindingKey)
        local bindings = active and active.bindings
        local row = bindings and (generationKey and adapter.generation(bindings, generationKey, item)
            or bindingKey and adapter.offer(bindings, bindingKey, item)) or nil
        if row and row.node ~= false then
            for _, fallback in ipairs(row.node.runtimeFallbacks or {}) do
                if fallback.availabilityContact == "storePurchase" then
                    local key = session.resolveFallback(state, row, "storePurchase", fallback, function(candidate)
                        return carriers.eligible(candidate, args, true)
                    end, item)
                    if key == nil then report(runtime); return base(screen, button, args) end
                    if carriers.materialize(item, key) == nil then
                        report(runtime)
                        return base(screen, button, args)
                    end
                    itemKey = key
                end
            end
        end
        pendingTwist = item and item.__runPlannerTwistResultKey
        local purchasesBefore = _G.CurrentRun and _G.CurrentRun.WellPurchases
        local ok, result = pcall(base, screen, button, args)
        pendingTwist = nil
        if not ok then error(result, 0) end
        local purchasesAfter = _G.CurrentRun and _G.CurrentRun.WellPurchases
        local purchased = row ~= nil and (row.node.kind ~= "wellPurchase"
            or type(purchasesBefore) ~= "number" or purchasesAfter == purchasesBefore + 1)
        if purchased and completesAtPurchase(row.node) then
            local verified = row.node.kind == "wellPurchase"
                and adapter.verifyWell(row, generationKey, itemKey, item.__runPlannerTwistResultKey)
                or verifyShopBinding(row, bindingKey, itemKey)
            session.complete(state, row, verified, row.node, {
                generationKey = generationKey, bindingKey = bindingKey, itemKey = itemKey,
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetRandomValue", "execution-v10-well-twist", function(_, _, base, values, args)
        if pendingTwist and type(values) == "table" then
            for _, value in pairs(values) do
                if type(value) == "table" and value.Name == pendingTwist then return value end
            end
        end
        return base(values, args)
    end)

    module.hooks.wrap("RemoveStoreItem", "execution-v10-world-shop-purchase", function(_, runtime, base, args)
        local state = getState(runtime)
        local binding = type(args) == "table" and inventoryBindings.find(args.Id) or nil
        local row = binding and binding.row
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local before = nativeRoom and nativeRoom.StoreItemsPurchased or 0
        local result = base(args)
        local after = nativeRoom and nativeRoom.StoreItemsPurchased or 0
        if row and row.node and row.node.kind == "shopPurchase" and completesAtPurchase(row.node) then
            local verified = after == before + 1
                and verifyShopBinding(row, binding.bindingKey, binding.itemKey)
            session.complete(state, row, verified, row.node, binding.itemKey)
        end
        if type(args) == "table" then inventoryBindings.forget(args.Id) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("HandleSellChoiceSelection", "execution-v10-pool-sale", function(_, runtime, base, screen,
        button, args)
        local state = getState(runtime)
        local active = current(state, room)
        local slot = type(button) == "table" and button.__runPlannerPoolSlotKey
        local trait = type(button) == "table" and button.UpgradeName
        local row = slot and active and adapter.lookup(active.bindings, "slot", slot) or nil
        local result = base(screen, button, args)
        if row then session.complete(state, row, adapter.verifyPool(row, slot, trait), row.node, trait) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseHealthFountain", "execution-v10-fountain", function(_, runtime, base, source, args)
        local state = getState(runtime)
        local active = current(state, room)
        local row
        for _, node in pairs(active and active.occurrence.transactionsByOwner or {}) do
            if node.kind == "fountainUse" then row = active.bindings.owner[node.owner]; break end
        end
        local result = base(source, args)
        local target = row and row.node.aromaticPhialTarget or nil
        session.complete(state, row, adapter.verifyFountain(row, target), row and row.node, target)
        report(runtime)
        return result
    end)

    module.hooks.wrap("GrantElementFromTool", "execution-v10-resource", function(_, runtime, base, toolName, args)
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
