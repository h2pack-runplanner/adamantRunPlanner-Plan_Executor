-- Single coordinator for the shared native inventory-construction callback.
-- Carrier modules decide which native rows participate.
local current = type(import) == "function"
    and import("mods/room/features/inventory/current.lua")
    or require("mods.room.features.inventory.current")
local primitives = type(import) == "function"
    and import("mods/room/features/inventory/primitives.lua")
    or require("mods.room.features.inventory.primitives")
local worldShop = type(import) == "function"
    and import("mods/room/features/inventory/world_shop.lua")
    or require("mods.room.features.inventory.world_shop")
local shrineInventory = type(import) == "function"
    and import("mods/room/features/inventory/hermes_shrine.lua")
    or require("mods.room.features.inventory.hermes_shrine")
local wellInventory = type(import) == "function"
    and import("mods/room/features/inventory/stygian_well.lua")
    or require("mods.room.features.inventory.stygian_well")
local hooks = {}

local function prepareInventory(occurrence, args, refillScope, contractOnly)
    local expected = occurrence and occurrence.overview or {}
    local storeData = primitives.copy(type(args) == "table" and args.StoreData or nil)
    if type(storeData) ~= "table" then return nil end
    local prepared, errorValue
    if type(refillScope) == "table" and refillScope.kind == "shop" then
        prepared, errorValue = worldShop.prepareRefill(expected.shop, storeData, args, refillScope)
    elseif type(refillScope) == "table" and refillScope.kind == "well" then
        prepared, errorValue = wellInventory.prepareRefill(expected.stygianWell, storeData, args, refillScope)
    elseif type(refillScope) == "table" and refillScope.kind == "shrine" then
        prepared, errorValue = shrineInventory.prepareRefill(expected.hermesShrine, storeData, args, refillScope)
    end
    if prepared ~= nil or errorValue ~= nil then return prepared, errorValue end
    if contractOnly then return worldShop.prepareContract(expected.shop, storeData, args) end
    if expected.shop ~= nil then return worldShop.prepare(expected.shop, storeData, args) end
    if expected.hermesShrine ~= nil then
        return shrineInventory.prepare(expected.hermesShrine, storeData, args)
    end
    return wellInventory.prepare(expected.stygianWell, storeData, args)
end

function hooks.attach(module, session, getState, report, room, route, scope)
    module.hooks.wrap("FillInShopOptions", "run-planner-inventory", function(_, runtime, base, args)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local prepared, errorValue = prepareInventory(active and active.occurrence, args,
            scope.shrineRefill or scope.wellRefill or scope.worldShopRefill,
            scope.contract ~= nil)
        if errorValue then
            session.mismatch(state, errorValue.checkpoint, errorValue.expected, errorValue.observed)
            report(runtime)
            return base(args)
        end
        scope.inventorySources = {}
        for _, offer in ipairs(prepared and prepared.expected or {}) do
            if offer.source then scope.inventorySources[#scope.inventorySources + 1] = offer.source end
            if offer.reward and offer.reward.source then
                scope.inventorySources[#scope.inventorySources + 1] = offer.reward.source
            end
        end
        local baseOk, result = pcall(base, prepared and prepared.args or args)
        if not baseOk then scope.inventorySources = nil; error(result, 0) end
        scope.inventorySources = nil
        result = primitives.placeRefill(prepared, result)
        result = primitives.order(prepared, result)
        local ok, verifyError = primitives.verify(prepared, result)
        if not ok then
            session.mismatch(state, verifyError.checkpoint, verifyError.expected, verifyError.observed)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetEligibleInteractedGod", "run-planner-inventory-source", function(_, _, base, ignored)
        if scope.inventorySources and scope.inventorySources[1] then
            return table.remove(scope.inventorySources, 1)
        end
        return base(ignored)
    end)
end

return hooks
