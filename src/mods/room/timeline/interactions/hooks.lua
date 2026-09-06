-- Explicit composition for non-commerce room interactions.
local fountain = type(import) == "function"
    and import("mods/room/timeline/interactions/fountain.lua")
    or require("mods.room.timeline.interactions.fountain")
local resources = type(import) == "function"
    and import("mods/room/timeline/interactions/resources.lua")
    or require("mods.room.timeline.interactions.resources")
local hooks = {}

function hooks.attach(module, session, getState, report, room)
    fountain.attach(module, session, getState, report, room)
    resources.attach(module, session, getState, report, room)
end

return hooks
