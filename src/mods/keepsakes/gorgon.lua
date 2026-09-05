-- Gorgon Amulet observes the native Athena contact. Native eligibility,
-- dispatch, spawning, and use consumption remain entirely game-owned; this
-- adapter binds the physical Athena to the already-published interaction so
-- the ordinary acquisition carrier can realize its exact offer.
local gorgon = {}
local unpackValues = table.unpack

local function packValues(...)
    return { n = select("#", ...), ... }
end

function gorgon.attach(module, getState, report, room)
    module.hooks.wrap("AthenaUse", "run-planner-gorgon-athena-use", function(_, runtime, base,
        athena, args, user, ...)
        local state = getState(runtime)
        -- encounterHandle performs the existing exact phase resolve and binds
        -- this native Athena so the ordinary UseLoot carrier can begin the
        -- published trait offer while the native call is in flight.
        room.encounterHandle(state, athena)
        local results = packValues(base(athena, args, user, ...))
        report(runtime)
        return unpackValues(results, 1, results.n)
    end)
end

return gorgon
