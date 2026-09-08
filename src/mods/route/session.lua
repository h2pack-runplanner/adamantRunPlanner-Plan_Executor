-- Sole outer cursor for the configured route. Room exit advances the cursor;
-- the next room entry proves the next published occurrence identity.
local routeSession = {}

function routeSession.new(plan)
    return {
        plan = plan, index = 1, currentOccurrence = nil,
        firstMismatch = nil, diagnostics = {},
    }
end

-- Recovery starts at one exact selected occurrence.  The cursor remains
-- otherwise identical to an ordinary new-run cursor: only exit advances it,
-- and entry still proves the occurrence identity at that index.
function routeSession.newAt(plan, index)
    local selected = plan and plan.selectedOccurrenceIds
    if type(selected) ~= "table"
        or type(index) ~= "number" or index ~= math.floor(index)
        or index < 1 or index > #selected then
        return nil, {
            checkpoint = "route-index",
            expected = "valid selected occurrence index",
            observed = index,
        }
    end
    local route = routeSession.new(plan)
    route.index = index
    return route
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
    return occurrence
end

function routeSession.exit(route)
    if route.currentOccurrence == nil then
        route.firstMismatch = route.firstMismatch or {
            checkpoint = "room-exit", expected = "active room", observed = nil,
        }
        return nil, route.firstMismatch
    end
    route.index = route.index + 1
    route.lastExitedOccurrence = route.currentOccurrence
    route.currentOccurrence = nil
    return true
end

-- N Hub and completed-parent reloads are native restoration transitions, not
-- execution rooms. They must not consume the single fresh-occurrence cursor.
function routeSession.transparent(route, gameName)
    if route == nil or route.currentOccurrence ~= nil or route.lastExitedOccurrence == nil then return false end
    if gameName == "N_Hub" then
        for _, occurrence in pairs(route.plan.occurrencesById or {}) do
            local hub = occurrence.overview and occurrence.overview.hub
            if hub and hub.room and hub.room.gameName == gameName then return true end
        end
        return false
    end
    -- A generated side reloads its declared main parent. Derive that relation
    -- from the published local slots instead of equating parent and side names.
    for _, parent in pairs(route.plan.occurrencesById or {}) do
        for _, slot in ipairs(parent.overview and parent.overview.localSlots or {}) do
            if slot.room and slot.room.id == route.lastExitedOccurrence.id
                and parent.gameName == gameName then return true end
        end
    end
    return false
end

function routeSession.enterTransparent(route, gameName)
    if routeSession.transparent(route, gameName) then
        route.transparentNativeRoom = gameName
        return true
    end
    return false
end

function routeSession.leaveTransparent(route)
    if route and route.transparentNativeRoom ~= nil then
        route.transparentNativeRoom = nil
        return true
    end
    return false
end

return routeSession
