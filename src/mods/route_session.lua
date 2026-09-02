-- The only cursor in v10 is the selected occurrence cursor.
local roomSession = type(import) == "function" and import("mods/room_session.lua")
    or require("mods/room_session")
local routeSession = {}

function routeSession.new(plan)
    return { plan = plan, index = 1, current = nil, firstMismatch = nil, diagnostics = {} }
end

function routeSession.enter(route, occurrenceId, gameName)
    if route.firstMismatch then return nil, route.firstMismatch end
    if route.current ~= nil then
        route.firstMismatch = {
            checkpoint = "room-entry",
            expected = "current room must exit",
            observed = occurrenceId,
        }
        return nil, route.firstMismatch
    end
    local expectedId = route.plan.selectedOccurrenceIds[route.index]
    if expectedId == nil then return true end -- configured prefix already completed
    local occurrence = route.plan.occurrencesById[expectedId]
    if occurrenceId ~= expectedId or gameName ~= occurrence.gameName then
        route.firstMismatch = {
            checkpoint = "room-entry",
            expected = occurrence,
            observed = { id = occurrenceId, gameName = gameName },
        }
        return nil, route.firstMismatch
    end
    route.current = roomSession.new(occurrence)
    return route.current
end

function routeSession.exit(route, readConformance)
    if route.current == nil then
        route.firstMismatch = route.firstMismatch or {
            checkpoint = "room-exit",
            expected = "active room",
            observed = nil,
        }
        return nil, route.firstMismatch
    end
    local ok, errorValue = roomSession.close(route.current, readConformance)
    if not ok then route.firstMismatch = errorValue; return nil, errorValue end
    route.index, route.current = route.index + 1, nil
    return true
end

return routeSession
