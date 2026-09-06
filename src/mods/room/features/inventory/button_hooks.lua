-- Preserves planner bindings through native store button copies and applies
-- Hermes Shrine delivery disposition to the corresponding native rows.
local current = type(import) == "function"
    and import("mods/room/features/inventory/current.lua")
    or require("mods.room.features.inventory.current")
local hooks = {}

local bindingFields = {
    "__runPlannerOfferKey", "__runPlannerGenerationKey", "__runPlannerTwistResultKey",
    "__runPlannerSourceOwner", "__runPlannerContractSourceOwner", "__runPlannerPaidShopOffer",
    "__runPlannerShrine", "__runPlannerShrineSourceKey",
}

local function capture()
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

local function restore(bindings, screen)
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

function hooks.attach(module, _, getState, report, room, route)
    module.hooks.wrap("CreateStoreButtons", "run-planner-store-button-bindings", function(_, _, base, screen,
        instant)
        local bindings = capture()
        local result = base(screen, instant)
        restore(bindings, screen)
        return result
    end)

    module.hooks.wrap("CreateSurfaceShopButtons", "run-planner-shrine-disposition", function(_, runtime, base,
        screen, ...)
        local bindings = capture()
        local result = base(screen, ...)
        restore(bindings, screen)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local shrine = active and active.occurrence.overview.hermesShrine
        local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
            and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
        for _, offer in ipairs(shrine and shrine.offers or {}) do
            local option = options and options[offer.slotIndex]
            local button = type(screen) == "table" and type(screen.Components) == "table"
                and screen.Components["PurchaseButton" .. offer.slotIndex] or nil
            if type(option) == "table" and offer.purchase ~= nil then
                option.RoomDelay = offer.purchase.roomDelay
            end
            if type(button) == "table" and type(button.Data) == "table" and offer.purchase ~= nil then
                button.Data.RoomDelay = offer.purchase.roomDelay
            end
        end
        local refill = shrine and shrine.travelDealRefill
        local refillOption = refill and options and options[refill.slotIndex]
        if type(refillOption) == "table" and refill.purchase ~= nil then
            refillOption.RoomDelay = refill.purchase.roomDelay
        end
        report(runtime)
        return result
    end)
end

return hooks
