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
local npc = type(import) == "function" and import("mods/room/timeline/acquisitions/npc/hooks.lua")
    or require("mods.room.timeline.acquisitions.npc.hooks")
local circe = type(import) == "function" and import("mods/room/timeline/acquisitions/npc/circe.lua")
    or require("mods.room.timeline.acquisitions.npc.circe")
local icarus = type(import) == "function" and import("mods/room/timeline/acquisitions/npc/icarus.lua")
    or require("mods.room.timeline.acquisitions.npc.icarus")
local echo = type(import) == "function" and import("mods/room/timeline/acquisitions/npc/echo.lua")
    or require("mods.room.timeline.acquisitions.npc.echo")
local mystery = type(import) == "function" and import("mods/room/timeline/acquisitions/mystery/hooks.lua")
    or require("mods.room.timeline.acquisitions.mystery.hooks")
local spell = type(import) == "function" and import("mods/room/timeline/acquisitions/spell/hooks.lua")
    or require("mods.room.timeline.acquisitions.spell.hooks")
local path = type(import) == "function" and import("mods/room/timeline/acquisitions/path/hooks.lua")
    or require("mods.room.timeline.acquisitions.path.hooks")
local seaStar = type(import) == "function" and import("mods/room/timeline/acquisitions/sea_star.lua")
    or require("mods.room.timeline.acquisitions.sea_star")

local acquisitions = {}

function acquisitions.attach(module, session, getState, report, room)
    seaStar.attach(module)
    binding.attach(module, session, getState, report, room)
    local traitScopes = traits.attach(module, session, getState, report, room)
    local npcScope = npc.attach(module, session, getState, report, room)
    circe.attach(module, session, report, npcScope)
    icarus.attach(module, session, report, npcScope)
    echo.attach(module, session, report, npcScope, traitScopes)
    mystery.attach(module, session, getState, report, room)
    spell.attach(module, session, getState, report, room)
    path.attach(module, session, getState, report, room)
    pickups.attach(module, session, getState, report, room)
    levels.attach(module, session, getState, report, room)
end

return acquisitions
