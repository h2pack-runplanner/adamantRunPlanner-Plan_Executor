-- Timeline contacts for interacting with already-realized room features.
-- Feature adapters own native inventory construction and expose only stable
-- item bindings; this module owns purchases, sales, uses, and acquired effects.
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local aromaticPhial = type(import) == "function" and import("mods/keepsakes/aromatic_phial.lua")
    or require("mods.keepsakes.aromatic_phial")
local anvil = type(import) == "function" and import("mods/room/timeline/transformations/anvil.lua")
    or require("mods.room.timeline.transformations.anvil")
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
    if node and node.anvilResult ~= nil then return false end
    if node and node.twistResultKey ~= nil then return false end
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

local function storeButtonIndex(button, item)
    if type(button) == "table" and type(button.Index) == "number" then return button.Index end
    if type(item) == "table" and type(item.Index) == "number" then return item.Index end
    local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
    for index, option in pairs(options or {}) do
        if option == item then return index end
    end
    return nil
end

local function shrineDisposition(shrine, generationKey)
    if shrine == nil or generationKey == nil then return nil end
    if generationKey == "travelDealRefill" then
        return shrine.travelDealRefill and shrine.travelDealRefill.purchase
    end
    for _, offer in ipairs(shrine.offers or {}) do
        if offer.generationKey == generationKey then return offer.purchase end
    end
    return nil
end

function hooks.attach(module, session, getState, report, room, inventoryBindings)
    local materializationScope
    local activeWellTwist
    local phial = aromaticPhial.attach(module, {
        session = session,
        getState = getState,
        report = report,
        room = room,
        phialTraitKey = nativeBindings.conformance.keepsakeTraits.phial,
    })
    local anvilScope = anvil.attach(module, session, report)

    module.hooks.wrap("HandleSurfaceShopAction", "run-planner-shrine-purchase", function(_, runtime, base,
        screen, button, args)
        local state = getState(runtime)
        local active = current(state, room)
        local shrine = active and active.occurrence.overview.hermesShrine
        local item = type(button) == "table" and (button.Data or button) or nil
        local generationKey = item and item.__runPlannerGenerationKey
        local disposition = shrineDisposition(shrine, generationKey)
        local refill = shrine and shrine.travelDealRefill
        local wasPurchased = type(item) == "table" and item.Purchased == true
        if type(item) == "table" and disposition ~= nil then
            item.RoomDelay = disposition.roomDelay
            if type(button.Data) == "table" then button.Data.RoomDelay = disposition.roomDelay end
        end
        local function invoke(withRefillScope)
            if withRefillScope and inventoryBindings and inventoryBindings.setShrineRefillScope then
                inventoryBindings.setShrineRefillScope({
                    kind = "shrine", slotIndex = refill.slotIndex,
                    sourceGenerationKey = refill.sourceGenerationKey,
                })
            end
            local ok, result = pcall(base, screen, button, args)
            if withRefillScope and inventoryBindings and inventoryBindings.setShrineRefillScope then
                inventoryBindings.setShrineRefillScope(nil)
            end
            if not ok then error(result, 0) end
            return result
        end
        local sourceRush = refill ~= nil and generationKey == refill.sourceGenerationKey
            and wasPurchased
        if disposition ~= nil and wasPurchased and not disposition.rushed then
            session.mismatch(state, "shrine-rush-disposition", "delayed", "rushed")
        end
        local result = invoke(sourceRush)
        if shrine ~= nil and disposition == nil and not wasPurchased
            and type(item) == "table" and item.Purchased == true then
            -- An authored Shrine inventory is complete, but only rows with a
            -- purchase disposition participate in the execution contract.
            -- Keep native purchase behavior while reporting this off-plan use;
            -- no Timeline transaction is created for it.
            session.mismatch(state, "shrine-purchase-disposition", "published purchase", generationKey)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("HandleStorePurchase", "run-planner-store-purchase", function(_, runtime, base, screen,
        button, args)
        local state = getState(runtime)
        local active = current(state, room)
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
        handle = materializedHandle(state, active, room, handle, itemKey)
        handle = room.bind(state, active, handle, item)
        local payload = handle and room.begin(state, handle) or nil
        local transaction = payload and payload.transaction
        local wellRefillScope
        local wellRefillHandle
        if transaction and transaction.kind == "wellPurchase"
            and transaction.generationKey ~= "travelDealRefill"
            and inventoryBindings and inventoryBindings.setWellRefillScope then
            local slotIndex = storeButtonIndex(button, item)
            wellRefillHandle = room.resolve(state, active,
                { kind = "wellRefill", generationKey = "travelDealRefill" })
            local refillPayload = wellRefillHandle and room.peek(state, wellRefillHandle) or nil
            if slotIndex ~= nil and refillPayload and refillPayload.transaction.kind == "wellRefill" then
                wellRefillScope = {
                    kind = "well",
                    slotIndex = slotIndex,
                }
                inventoryBindings.setWellRefillScope(wellRefillScope)
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
            and _G.CurrentRun and _G.CurrentRun.WellPurchases or nil
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
            transaction.kind == "wellPurchase"
            and transaction.offerKey == itemKey
            or transaction.kind == "shopPurchase"
            and shopBinding(payload, bindingKey)
        )
        if transaction == nil or transaction.kind ~= "shopPurchase" then
            if payload and not exact then
                session.mismatch(state, "purchase-selection", transaction.offerKey,
                    itemKey or bindingKey)
            elseif transaction and (not purchased or result == false) then
                session.mismatch(state, "purchase-selection", itemKey,
                    "native-rejected")
            elseif purchased and completesAtPurchase(transaction) then
                session.complete(state, handle)
            end
            -- Travel Deal realization is an independent transaction.  The
            -- source may itself be a RandomStoreItem whose Twist settles
            -- later in this native contact; only the DAG readiness check may
            -- decide whether the refill can close here.
            if purchased and exact and result ~= false and wellRefillScope and wellRefillHandle ~= nil then
                local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
                local options = nativeRoom and nativeRoom.Store and nativeRoom.Store.StoreOptions
                local replacement = options and options[wellRefillScope.slotIndex]
                if type(replacement) == "table"
                    and replacement.__runPlannerGenerationKey == "travelDealRefill" then
                    local refillPayload = room.begin(state, wellRefillHandle)
                    if refillPayload ~= nil then session.complete(state, wellRefillHandle) end
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

    module.hooks.wrap("UseConsumableItem", "run-planner-anvil-use", function(_, runtime, base,
        item, args, user)
        local state = getState(runtime)
        local active = current(state, room)
        local handle = active and room.bound(state, active, item) or nil
        if handle == nil and active and type(item) == "table"
            and item.__runPlannerGenerationKey ~= nil
            and item.__runPlannerTwistResultKey ~= nil then
            handle = room.resolve(state, active, {
                kind = "wellPurchase", generationKey = item.__runPlannerGenerationKey,
            })
            handle = room.bind(state, active, handle, item)
        end
        local payload = handle and room.peek(state, handle) or nil
        local transaction = payload and payload.transaction
        local twistScope = transaction and transaction.kind == "wellPurchase"
            and transaction.twistResultKey ~= nil and {
                state = state, handle = handle, target = transaction.twistResultKey,
                awarded = false, unavailable = false,
            } or nil
        local priorTwist = activeWellTwist
        activeWellTwist = twistScope
        local scope = anvilScope.beginUse(state, payload)
        if scope == nil and twistScope == nil then
            activeWellTwist = priorTwist
            return base(item, args, user)
        end
        local ok, result = pcall(base, item, args, user)
        activeWellTwist = priorTwist
        local called = scope and anvilScope.finishUse(scope) or false
        if not ok then error(result, 0) end
        if called then session.complete(state, handle) end
        if twistScope and twistScope.awarded and result ~= false then session.complete(state, handle) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AwardRandomStoreItem", "run-planner-well-twist-award", function(_, runtime, base, ...)
        local scope = activeWellTwist
        local ok, result = pcall(base, ...)
        if not ok then error(result, 0) end
        if scope ~= nil then scope.awarded = result ~= false end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetRandomValue", "run-planner-well-twist-use", function(_, runtime, base, values, args)
        local scope = activeWellTwist
        if scope ~= nil and type(values) == "table" then
            for _, value in pairs(values) do
                local key = type(value) == "table" and (value.Name or value.ItemName) or value
                if key == scope.target then return value end
            end
            if not scope.unavailable then
                scope.unavailable = true
                session.mismatch(scope.state, "well-twist-result", scope.target, "unavailable")
            end
        end
        report(runtime)
        return base(values, args)
    end)

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
        elseif payload and completesAtPurchase(payload.transaction) then
            if not accepted or not shopBinding(payload, binding.bindingKey) then
                session.mismatch(state, "purchase-selection", binding.bindingKey, binding.itemKey)
            else
                session.complete(state, handle)
            end
        end
        if type(args) == "table" then inventoryBindings.forget(args.Id) end
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
        local phialScope = phial.begin(state, active, handle, payload)
        local ok, result = pcall(base, source, args)
        if not ok then
            phial.cancel(phialScope)
            error(result, 0)
        end
        if payload ~= nil and phialScope == nil then
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
