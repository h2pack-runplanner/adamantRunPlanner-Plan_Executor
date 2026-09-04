-- Acquisition-family composition.  Producer correlation is shared by the
-- concrete carriers; each carrier owns its accepted contact and terminal
-- proof below this boundary.
local binding = type(import) == "function" and import("mods/room/timeline/acquisitions/binding.lua")
    or require("mods.room.timeline.acquisitions.binding")
local traits = type(import) == "function" and import("mods/room/timeline/acquisitions/traits/hooks.lua")
    or require("mods.room.timeline.acquisitions.traits.hooks")
local levels = type(import) == "function" and import("mods/room/timeline/acquisitions/levels/hooks.lua")
    or require("mods.room.timeline.acquisitions.levels.hooks")
local pickups = type(import) == "function" and import("mods/room/timeline/acquisitions/pickups/hooks.lua")
    or require("mods.room.timeline.acquisitions.pickups.hooks")

local acquisitions = {}

function acquisitions.attach(module, session, getState, report, room)
    binding.attach(module, session, getState, report, room)
    traits.attach(module, session, getState, report, room)
    pickups.attach(module, session, getState, report, room)
    levels.attach(module, session, getState, report, room)
end

return acquisitions
