-- Purging Pool inventory contacts over the native legal sale domain.
local current = type(import) == "function"
    and import("mods/room/features/inventory/current.lua")
    or require("mods.room.features.inventory.current")
local poolInventory = type(import) == "function"
    and import("mods/room/features/inventory/purging_pool.lua")
    or require("mods.room.features.inventory.purging_pool")
local hooks = {}

local function steer(session, state, active, nativeRoom)
    local ok, errorValue = poolInventory.steer(active and active.occurrence, nativeRoom)
    if not ok then
        session.mismatch(state, errorValue.checkpoint, errorValue.expected, errorValue.observed)
    end
end

function hooks.attach(module, session, getState, report, room, route)
    module.hooks.wrap("GenerateSellTraitShop", "run-planner-pool-inventory", function(_, runtime, base,
        nativeRoom, args)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local result = base(nativeRoom, args)
        -- Native generation owns legal trait filtering and SellValues.
        steer(session, state, active, nativeRoom)
        report(runtime)
        return result
    end)

    -- Initial generation can precede room entry; reapply at button creation to
    -- the already-generated native candidate set.
    module.hooks.wrap("CreateSellButtons", "run-planner-pool-inventory", function(_, runtime, base, screen)
        local state = getState(runtime)
        local active = current.resolve(state, room, route)
        local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        steer(session, state, active, nativeRoom)
        local result = base(screen)
        report(runtime)
        return result
    end)
end

return hooks
