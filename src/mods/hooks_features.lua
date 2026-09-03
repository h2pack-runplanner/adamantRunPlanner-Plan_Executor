-- Deferred Overview inventory plus consequential cleanup transactions.
local inventory = type(import) == "function" and import("mods/native_inventory.lua")
    or require("mods/native_inventory")
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods/native_timeline_adapters")
local hooks = {}

local function current(session, state)
    local active = session.current(state)
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local occurrenceId = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId
    if occurrenceId ~= nil and (active == nil or active.occurrence.id ~= occurrenceId)
        and type(session.prepareOccurrence) == "function" then
        return session.prepareOccurrence(state, occurrenceId)
    end
    return active
end

local function mismatch(session, state, errorValue)
    if errorValue then
        return session.mismatch(state, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
end

function hooks.attach(module, session, getState, report)
    local inventorySources
    local pendingTwist
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

    local function availableIn(value, key, seen)
        if type(value) ~= "table" then return value == key end
        seen = seen or {}
        if seen[value] then return false end
        seen[value] = true
        if value.Name == key or value.ItemName == key then return true end
        for _, nested in pairs(value) do if availableIn(nested, key, seen) then return true end end
        return false
    end

    local function namedEntry(value, key, seen)
        if type(value) ~= "table" then return nil end
        seen = seen or {}
        if seen[value] then return nil end
        seen[value] = true
        if value.Name == key or value.ItemName == key then return value end
        for _, nested in pairs(value) do
            local found = namedEntry(nested, key, seen)
            if found ~= nil then return found end
        end
        return nil
    end

    local function copy(value)
        if type(value) ~= "table" then return value end
        local result = {}
        for key, nested in pairs(value) do result[key] = copy(nested) end
        return result
    end

    local function carrier(key)
        local traits = _G.TraitData or {}
        local consumables = _G.ConsumableData or {}
        if traits[key] ~= nil then return traits[key], "Trait" end
        if consumables[key] ~= nil then return consumables[key], "Consumable" end
        return nil
    end

    local function eligibleCarrier(key, args, purchase)
        local data, kind = carrier(key)
        if data == nil then return false end
        if kind == "Trait" then
            return type(_G.IsTraitEligible) ~= "function" or _G.IsTraitEligible(data, args) == true
        end
        if type(_G.StoreItemEligible) == "function" and not _G.StoreItemEligible(data, args or {}) then
            return false
        end
        return not purchase or data.PurchaseRequirements == nil or type(_G.IsGameStateEligible) ~= "function"
            or _G.IsGameStateEligible(data, data.PurchaseRequirements) == true
    end

    local function storeCandidateAvailable(storeData, key, args)
        if not availableIn(storeData, key) then return false end
        local entry = namedEntry(storeData, key)
        if entry and entry.AdditionalRequirements and type(_G.IsGameStateEligible) == "function"
            and not _G.IsGameStateEligible(entry, entry.AdditionalRequirements) then return false end
        if entry and entry.ReplaceRequirements and type(_G.IsGameStateEligible) == "function" then
            return _G.IsGameStateEligible(entry, entry.ReplaceRequirements) == true
        end
        if entry and entry.SkipRequirements then return true end
        return eligibleCarrier(key, args, false)
    end

    local function materializeCarrier(item, key)
        local data, kind = carrier(key)
        if type(item) ~= "table" or data == nil then return nil end
        local retained = {
            __runPlannerOfferKey = item.__runPlannerOfferKey,
            __runPlannerGenerationKey = item.__runPlannerGenerationKey,
            __runPlannerTwistResultKey = item.__runPlannerTwistResultKey,
            Index = item.Index, ObjectId = item.ObjectId,
        }
        for field in pairs(item) do item[field] = nil end
        for field, value in pairs(data) do item[field] = copy(value) end
        item.Name, item.Type = key, kind
        for field, value in pairs(retained) do if value ~= nil then item[field] = value end end
        return item
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

    module.hooks.wrap("FillInShopOptions", "execution-v10-inventory", function(_, runtime, base, args)
        local state = getState(runtime)
        local active = current(session, state)
        local prepared, errorValue = inventory.prepare(active and active.occurrence, args,
            refillScope ~= nil,
            function(fallback, defaultKey, offer)
                if fallback.availabilityContact ~= "storeInventoryGeneration" then return defaultKey end
                local row = active and (adapter.offer(active.bindings, offer.offerKey)
                    or adapter.generation(active.bindings, offer.generationKey))
                local key = session.resolveFallback(state, row, "storeInventoryGeneration", fallback,
                    function(candidate)
                        return storeCandidateAvailable(args and args.StoreData, candidate, args)
                    end)
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

    module.hooks.wrap("GetEligibleInteractedGod", "execution-v10-inventory-source", function(_, _, base, ignored)
        if inventorySources and inventorySources[1] then return table.remove(inventorySources, 1) end
        return base(ignored)
    end)

    module.hooks.wrap("CreateSellButtons", "execution-v10-pool-inventory", function(_, runtime, base, screen)
        local state = getState(runtime)
        local active = current(session, state)
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        local ok, errorValue = inventory.applyPool(active and active.occurrence, nativeRoom)
        if not ok then mismatch(session, state, errorValue) end
        local result = base(screen)
        report(runtime)
        return result
    end)

    module.hooks.wrap("CreateStoreButtons", "execution-v10-store-button-bindings", function(_, _, base, screen,
        instant)
        local bindings = captureStoreBindings()
        local result = base(screen, instant)
        restoreStoreBindings(bindings, screen)
        return result
    end)

    module.hooks.wrap("HandleStorePurchase", "execution-v10-store-purchase", function(_, runtime, base, screen, button,
        args)
        local state = getState(runtime)
        local active = current(session, state)
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
                        return eligibleCarrier(candidate, args, true)
                    end, item)
                    if key == nil then report(runtime); return base(screen, button, args) end
                    if materializeCarrier(item, key) == nil then report(runtime); return base(screen, button, args) end
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

    module.hooks.wrap("RestockWorldItem", "execution-v10-travel-deal-refill", function(_, runtime, base, index, kitId,
        args)
        local state = getState(runtime)
        local active = current(session, state)
        local prior = refillScope
        refillScope = active and { index = index, kitId = kitId } or nil
        local ok, result = pcall(base, index, kitId, args)
        refillScope = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SpawnStoreItemInWorld", "execution-v10-bind-world-shop-item", function(_, runtime, base,
        itemData, kitId)
        local state = getState(runtime)
        local active = current(session, state)
        local result = base(itemData, kitId)
        if active and type(itemData) == "table" and result ~= nil then
            local generationKey = itemData.__runPlannerGenerationKey
            local bindingKey = itemData.__runPlannerOfferKey or itemData.Name or itemData.ItemName
            local itemKey = itemData.Name or itemData.ItemName or bindingKey
            local row = generationKey and adapter.generation(active.bindings, generationKey, result)
                or bindingKey and adapter.offer(active.bindings, bindingKey, result) or nil
            if row and row.node and row.node.kind == "wellRefill" then
                local verified = adapter.verifyWell(row, generationKey, itemKey,
                    itemData.__runPlannerTwistResultKey)
                session.complete(state, row, verified, row.node, itemKey)
            end
            if type(result) == "table" and result.ObjectId ~= nil and row ~= nil then
                worldItemsById[result.ObjectId] = {
                    row = row, bindingKey = bindingKey, itemKey = itemKey,
                }
            end
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("RemoveStoreItem", "execution-v10-world-shop-purchase", function(_, runtime, base, args)
        local state = getState(runtime)
        local binding = type(args) == "table" and worldItemsById[args.Id] or nil
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
        if type(args) == "table" then worldItemsById[args.Id] = nil end
        report(runtime)
        return result
    end)

    module.hooks.wrap("HandleSellChoiceSelection", "execution-v10-pool-sale", function(_, runtime, base, screen,
        button, args)
        local state = getState(runtime)
        local active = current(session, state)
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
        local active = current(session, state)
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
        local active = current(session, state)
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
