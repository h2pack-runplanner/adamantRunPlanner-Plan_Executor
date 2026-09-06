-- Sole outer cursor for the configured route. A room exit starts a native
-- transition while retaining the departing occurrence; the LeaveRoom wrapper
-- advances the cursor immediately after the native call returns.
local routeSession = {}

function routeSession.new(plan)
    local resourcesById = {}
    for _, row in ipairs(plan and plan.resources and plan.resources.occurrences or {}) do
        resourcesById[row.occurrenceId] = row
    end
    return {
        plan = plan, index = 1, currentOccurrence = nil,
        resourcesById = resourcesById, transitioning = false,
        firstMismatch = nil, diagnostics = {},
    }
end

function routeSession.expected(route)
    local id = route and route.plan.selectedOccurrenceIds[route.index]
    return id and route.plan.occurrencesById[id] or nil
end

function routeSession.current(route)
    return route and route.currentOccurrence or nil
end

function routeSession.isTransitioning(route)
    return route ~= nil and route.transitioning == true
end

function routeSession.next(route)
    if route == nil or route.plan == nil then return nil end
    local id = route.plan.selectedOccurrenceIds[route.index + 1]
    return id and route.plan.occurrencesById[id] or nil
end

function routeSession.currentResource(route)
    local occurrence = routeSession.current(route)
    return occurrence and route.resourcesById and route.resourcesById[occurrence.id] or nil
end

function routeSession.enter(route, occurrenceId, gameName)
    if route.firstMismatch then return nil, route.firstMismatch end
    if route.transitioning then
        route.firstMismatch = {
            checkpoint = "route-transition",
            expected = "transition must settle before entry",
            observed = occurrenceId,
        }
        return nil, route.firstMismatch
    end
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
    return occurrence
end

function routeSession.exit(route)
    if route.currentOccurrence == nil then
        route.firstMismatch = route.firstMismatch or {
            checkpoint = "room-exit", expected = "active room", observed = nil,
        }
        return nil, route.firstMismatch
    end
    if route.transitioning then
        route.firstMismatch = {
            checkpoint = "route-transition",
            expected = "one transition at a time",
            observed = "repeated exit",
        }
        return nil, route.firstMismatch
    end
    route.transitioning = true
    return true
end

function routeSession.advance(route)
    if route == nil or not route.transitioning or route.currentOccurrence == nil then
        return nil
    end
    route.index = route.index + 1
    route.currentOccurrence = nil
    route.transitioning = false
    return true
end

return routeSession
