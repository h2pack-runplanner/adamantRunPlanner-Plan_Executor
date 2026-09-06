-- Explicit composition for carrier-specific commerce contacts.
local shrine = type(import) == "function"
    and import("mods/room/timeline/commerce/hermes_shrine.lua")
    or require("mods.room.timeline.commerce.hermes_shrine")
local storePurchase = type(import) == "function"
    and import("mods/room/timeline/commerce/store_purchase.lua")
    or require("mods.room.timeline.commerce.store_purchase")
local consumableUse = type(import) == "function"
    and import("mods/room/timeline/commerce/consumable_use.lua")
    or require("mods.room.timeline.commerce.consumable_use")
local worldShop = type(import) == "function"
    and import("mods/room/timeline/commerce/world_shop.lua")
    or require("mods.room.timeline.commerce.world_shop")
local hooks = {}

function hooks.attach(module, session, getState, report, room, inventoryBindings)
    shrine.attach(module, session, getState, report, room, inventoryBindings)
    storePurchase.attach(module, session, getState, report, room, inventoryBindings)
    consumableUse.attach(module, session, getState, report, room)
    worldShop.attach(module, session, getState, report, room, inventoryBindings)
end

return hooks
