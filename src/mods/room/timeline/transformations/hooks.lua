-- Reward transformation composition.  Each native transformation owns its
-- accepted contact and bounded terminal; the returned capability is limited
-- to Artificer's already-resolved reward selection for navigation.
local artificer = type(import) == "function" and import("mods/room/timeline/transformations/artificer.lua")
    or require("mods.room.timeline.transformations.artificer")

local transformations = {}

function transformations.attach(module, session, getState, report, room)
    local artificerScope = artificer.attach(module, session, getState, report, room)
    return artificerScope
end

return transformations
