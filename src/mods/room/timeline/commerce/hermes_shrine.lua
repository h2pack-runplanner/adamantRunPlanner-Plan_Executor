-- Hermes Shrine purchase and rush contacts. Native code owns delivery clocks,
-- rushing, spawning, and acquisition after inventory is steered.
local shrine = {}

local function dispositionFor(overview, generationKey)
    if overview == nil or generationKey == nil then return nil end
    if generationKey == "travelDealRefill" then
        return overview.travelDealRefill and overview.travelDealRefill.purchase
    end
    for _, offer in ipairs(overview.offers or {}) do
        if offer.generationKey == generationKey then return offer.purchase end
    end
    return nil
end

function shrine.attach(module, session, getState, report, room, inventoryBindings)
    module.hooks.wrap("HandleSurfaceShopAction", "run-planner-shrine-purchase", function(_, runtime, base,
        screen, button, args)
        local state = getState(runtime)
        local active = room.current(state)
        local overview = active and active.occurrence.overview.hermesShrine
        local item = type(button) == "table" and (button.Data or button) or nil
        local generationKey = item and item.__runPlannerGenerationKey
        local disposition = dispositionFor(overview, generationKey)
        local refill = overview and overview.travelDealRefill
        local wasPurchased = type(item) == "table" and item.Purchased == true
        if type(item) == "table" and disposition ~= nil then
            item.RoomDelay = disposition.roomDelay
            if type(button.Data) == "table" then button.Data.RoomDelay = disposition.roomDelay end
        end
        local function invoke(withRefillScope)
            if withRefillScope then
                inventoryBindings.setShrineRefillScope({
                    kind = "shrine", slotIndex = refill.slotIndex,
                    sourceGenerationKey = refill.sourceGenerationKey,
                })
            end
            local ok, result = pcall(base, screen, button, args)
            if withRefillScope then inventoryBindings.setShrineRefillScope(nil) end
            if not ok then error(result, 0) end
            return result
        end
        local sourceRush = refill ~= nil and generationKey == refill.sourceGenerationKey
            and wasPurchased
        if disposition ~= nil and wasPurchased and not disposition.rushed then
            session.mismatch(state, "shrine-rush-disposition", "delayed", "rushed")
        end
        local result = invoke(sourceRush)
        if overview ~= nil and disposition == nil and not wasPurchased
            and type(item) == "table" and item.Purchased == true then
            -- Inventory includes all three offers; only rows with a published
            -- purchase disposition participate in the Timeline contract.
            session.mismatch(state, "shrine-purchase-disposition", "published purchase", generationKey)
        end
        report(runtime)
        return result
    end)
end

return shrine
