-- Resolves the occurrence whose native inventory is currently being built.
local current = {}

function current.resolve(state, room, route)
    local active = room.current(state)
    local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
    local occurrenceId = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId
    if occurrenceId ~= nil and (active == nil or active.occurrence.id ~= occurrenceId)
        and route ~= nil then
        local expected = type(route.isTransitioning) == "function"
            and route.isTransitioning(state.route) and route.next(state.route)
            or route.expected(state.route)
        if expected ~= nil and expected.id == occurrenceId then return room.prepare(state, expected) end
    end
    return active
end

return current
