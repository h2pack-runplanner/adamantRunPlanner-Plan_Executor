-- Sole outer cursor for the configured route. It records which published
-- destination navigation reports, but owns no room-local lifecycle state.
local routeSession = {}

function routeSession.new(plan)
    return {
        plan = plan, index = 1, currentOccurrence = nil,
        selectedDestinationId = nil, firstMismatch = nil, diagnostics = {},
    }
end

function routeSession.expected(route)
    local id = route and route.plan.selectedOccurrenceIds[route.index]
    return id and route.plan.occurrencesById[id] or nil
end

function routeSession.current(route)
    return route and route.currentOccurrence or nil
end

function routeSession.enter(route, occurrenceId, gameName)
    if route.firstMismatch then return nil, route.firstMismatch end
    if route.currentOccurrence ~= nil then
        route.firstMismatch = {
            checkpoint = "room-entry",
            expected = "current room must exit",
            observed = occurrenceId,
        }
        return nil, route.firstMismatch
    end
    local occurrence = routeSession.expected(route)
    if occurrence == nil then return true end -- configured prefix already completed
    if occurrenceId ~= occurrence.id or gameName ~= occurrence.gameName then
        route.firstMismatch = {
            checkpoint = "room-entry",
            expected = occurrence,
            observed = { id = occurrenceId, gameName = gameName },
        }
        return nil, route.firstMismatch
    end
    route.currentOccurrence = occurrence
    route.selectedDestinationId = nil
    return occurrence
end

function routeSession.reportDestination(route, occurrenceId)
    if route.currentOccurrence == nil then
        route.firstMismatch = route.firstMismatch or {
            checkpoint = "door-selection", expected = "active room", observed = occurrenceId,
        }
        return nil, route.firstMismatch
    end
    local expectedId = route.plan.selectedOccurrenceIds[route.index + 1]
    if expectedId ~= occurrenceId then
        route.firstMismatch = {
            checkpoint = "door-selection", expected = expectedId, observed = occurrenceId,
        }
        return nil, route.firstMismatch
    end
    route.selectedDestinationId = occurrenceId
    return true
end

function routeSession.exit(route)
    if route.currentOccurrence == nil then
        route.firstMismatch = route.firstMismatch or {
            checkpoint = "room-exit", expected = "active room", observed = nil,
        }
        return nil, route.firstMismatch
    end
    local nextId = route.plan.selectedOccurrenceIds[route.index + 1]
    if nextId ~= nil and route.selectedDestinationId ~= nextId then
        route.firstMismatch = {
            checkpoint = "door-selection", expected = nextId,
            observed = route.selectedDestinationId,
        }
        return nil, route.firstMismatch
    end
    route.index = route.index + 1
    route.currentOccurrence = nil
    route.selectedDestinationId = nil
    return true
end

return routeSession
