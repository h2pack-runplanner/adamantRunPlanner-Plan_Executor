-- Explicit assembly of feature-owned inventory contacts and their narrow
-- Timeline binding surface.
local inventoryHooks = type(import) == "function"
    and import("mods/room/features/inventory/hooks.lua")
    or require("mods.room.features.inventory.hooks")
local buttonHooks = type(import) == "function"
    and import("mods/room/features/inventory/button_hooks.lua")
    or require("mods.room.features.inventory.button_hooks")
local poolHooks = type(import) == "function"
    and import("mods/room/features/inventory/purging_pool_hooks.lua")
    or require("mods.room.features.inventory.purging_pool_hooks")
local worldItemHooks = type(import) == "function"
    and import("mods/room/features/inventory/world_item_hooks.lua")
    or require("mods.room.features.inventory.world_item_hooks")
local attach = {}

function attach.attach(module, session, getState, report, room, route)
    local scope = {}
    inventoryHooks.attach(module, session, getState, report, room, route, scope)
    buttonHooks.attach(module, session, getState, report, room, route)
    poolHooks.attach(module, session, getState, report, room, route)
    local bindings = worldItemHooks.attach(module, session, getState, report, room, route, scope)
    bindings.setWellRefillScope = function(value) scope.wellRefill = value end
    bindings.setShrineRefillScope = function(value) scope.shrineRefill = value end
    return bindings
end

return attach
