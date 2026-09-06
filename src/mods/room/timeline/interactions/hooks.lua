-- Explicit composition for non-commerce room interactions.
local fountain = type(import) == "function"
    and import("mods/room/timeline/interactions/fountain.lua")
    or require("mods.room.timeline.interactions.fountain")
local hooks = {}

function hooks.attach(module, session, getState, report, room)
    fountain.attach(module, session, getState, report, room)
end

return hooks
