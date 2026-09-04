-- Native construction of inventories owned by room features. Purchase, sale,
-- use, and acquired-effect contacts remain in room/timeline/.
local inventory = type(import) == "function" and import("mods/room/features/inventory.lua")
    or require("mods.room.features.inventory")
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods/native_timeline_adapters")
local carriers = type(import) == "function" and import("mods/room/features/store_carriers.lua")
    or require("mods/room/features/store_carriers")
local hooks = {}

local function current(_, state, room, route)
    local active = room.current(state)
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local occurrenceId = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId
    if occurrenceId ~= nil and (active == nil or active.occurrence.id ~= occurrenceId)
        and route ~= nil then
        local expected = route.expected(state.route)
        if expected ~= nil and expected.id == occurrenceId then return room.prepare(state, expected) end
    end
    return active
end

local function mismatch(session, state, errorValue)
    if errorValue then
        return session.mismatch(state, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
end

local function materializedHandle(state, active, room, root, itemKey)
    if root == nil or itemKey == nil then return root end
    return room.resolve(state, active, {
        kind = "materialized", source = root, gameName = itemKey,
    }) or root
end

function hooks.attach(module, session, getState, report, room, route)
    local inventorySources
    local refillScope
    local worldItemsById = {}

    local bindingFields = {
        "__runPlannerOfferKey", "__runPlannerGenerationKey", "__runPlannerTwistResultKey",
    }

    local function captureStoreBindings()
        local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
            and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
        local bindings = {}
        for index, option in pairs(options or {}) do
            if type(option) == "table" then
                local binding = {}
                for _, field in ipairs(bindingFields) do binding[field] = option[field] end
                bindings[index] = binding
            end
        end
        return bindings
    end

    local function restoreStoreBindings(bindings, screen)
        local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
            and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
        for index, binding in pairs(bindings or {}) do
            local option = options and options[index]
            local button = type(screen) == "table" and type(screen.Components) == "table"
                and screen.Components["PurchaseButton" .. index] or nil
            for _, target in ipairs({ option, button and button.Data }) do
                if type(target) == "table" then
                    for _, field in ipairs(bindingFields) do target[field] = binding[field] end
                end
            end
        end
    end

    module.hooks.wrap("FillInShopOptions", "run-planner-inventory", function(_, runtime, base, args)
        local state = getState(runtime)
        local active = current(session, state, room, route)
        local prepared, errorValue = inventory.prepare(active and active.occurrence, args,
            refillScope ~= nil,
            function(fallback, defaultKey, offer)
                if fallback.availabilityContact ~= "storeInventoryGeneration" then return defaultKey end
                local handle = active and room.resolve(state, active, offer.offerKey
                    and { kind = "offer", offerKey = offer.offerKey }
                    or { kind = "generation", generationKey = offer.generationKey })
                local payload = handle and room.begin(state, handle) or nil
                local key = session.resolveFallback(state, handle, payload, "storeInventoryGeneration", fallback,
                    function(candidate)
                        return carriers.available(args and args.StoreData, candidate, args)
                    end, nil, active)
                return key
            end)
        if errorValue then mismatch(session, state, errorValue); report(runtime); return base(args) end
        inventorySources = {}
        for _, offer in ipairs(prepared and prepared.expected or {}) do
            if offer.source then inventorySources[#inventorySources + 1] = offer.source end
            if offer.reward and offer.reward.source then
                inventorySources[#inventorySources + 1] = offer.reward.source
            end
        end
        local result = base(prepared and prepared.args or args)
        inventorySources = nil
        result = inventory.order(prepared, result)
        local ok, verifyError = inventory.verify(prepared, result)
        if not ok then mismatch(session, state, verifyError) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetEligibleInteractedGod", "run-planner-inventory-source", function(_, _, base, ignored)
        if inventorySources and inventorySources[1] then return table.remove(inventorySources, 1) end
        return base(ignored)
    end)

    module.hooks.wrap("CreateSellButtons", "run-planner-pool-inventory", function(_, runtime, base, screen)
        local state = getState(runtime)
        local active = current(session, state, room, route)
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local ok, errorValue = inventory.applyPool(active and active.occurrence, nativeRoom)
        if not ok then mismatch(session, state, errorValue) end
        local result = base(screen)
        report(runtime)
        return result
    end)

    module.hooks.wrap("CreateStoreButtons", "run-planner-store-button-bindings", function(_, _, base, screen,
        instant)
        local bindings = captureStoreBindings()
        local result = base(screen, instant)
        restoreStoreBindings(bindings, screen)
        return result
    end)

    module.hooks.wrap("RestockWorldItem", "run-planner-travel-deal-refill", function(_, runtime, base, index, kitId,
        args)
        local state = getState(runtime)
        local active = current(session, state, room, route)
        local handle = active and room.resolve(state, active,
            { kind = "generation", generationKey = "travelDealRefill" })
        if handle ~= nil and room.begin(state, handle) == nil then
            report(runtime)
            return base(index, kitId, args)
        end
        local prior = refillScope
        refillScope = active and { index = index, kitId = kitId } or nil
        local ok, result = pcall(base, index, kitId, args)
        refillScope = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SpawnStoreItemInWorld", "run-planner-bind-world-shop-item", function(_, runtime, base,
        itemData, kitId)
        local state = getState(runtime)
        local active = current(session, state, room, route)
        local result = base(itemData, kitId)
        if active and type(itemData) == "table" and result ~= nil then
            local generationKey = itemData.__runPlannerGenerationKey
            local bindingKey = itemData.__runPlannerOfferKey or itemData.Name or itemData.ItemName
            local itemKey = itemData.Name or itemData.ItemName or bindingKey
            local handle = generationKey and room.resolve(state, active,
                { kind = "generation", generationKey = generationKey })
                or bindingKey and room.resolve(state, active, { kind = "offer", offerKey = bindingKey }) or nil
            handle = materializedHandle(state, active, room, handle, itemKey)
            handle = room.bind(state, active, handle, result)
            local payload = handle and room.begin(state, handle) or nil
            if payload and payload.transaction.kind == "wellRefill" then
                local verified = adapter.verifyWell(payload, generationKey, itemKey,
                    itemData.__runPlannerTwistResultKey)
                session.complete(state, handle, verified, payload.transaction, itemKey)
            end
            if type(result) == "table" and result.ObjectId ~= nil and handle ~= nil then
                worldItemsById[result.ObjectId] = {
                    handle = handle, bindingKey = bindingKey, itemKey = itemKey,
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
