-- Native spawning contacts for structural room features. Resulting exit
-- binding remains navigation-owned; later interactions remain Timeline-owned.
local hooks = {}

function hooks.attach(module, _, getState, report, room)
    local secretScope
    local pendingAdditional

    module.hooks.wrap("HandleSecretSpawns", "run-planner-room-features", function(_, runtime, base, currentRun)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun) end
        secretScope = room.additional(state, "chaos") ~= nil
        local ok, result = pcall(base, currentRun)
        secretScope = nil
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("IsSecretDoorEligible", "run-planner-chaos-eligibility", function(_, runtime, base,
        currentRun, currentRoom)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, currentRoom) end
        if secretScope ~= nil then return secretScope end
        return base(currentRun, currentRoom)
    end)

    module.hooks.wrap("IsSellTraitShopEligible", "run-planner-purging-pool-presence", function(_, runtime, base,
        currentRoom)
        local state = getState(runtime)
        if state == nil then return base(currentRoom) end
        if room.current(state) ~= nil then return room.feature(state, "purgingPool") ~= nil end
        return base(currentRoom)
    end)

    module.hooks.wrap("IsWellShopEligible", "run-planner-well-presence", function(_, runtime, base, currentRun,
        currentRoom)
        local state = getState(runtime)
        if state == nil then return base(currentRun, currentRoom) end
        if room.current(state) ~= nil then return room.feature(state, "stygianWell") ~= nil end
        return base(currentRun, currentRoom)
    end)

    module.hooks.wrap("SpawnZagContract", "run-planner-zagreus-contract", function(_, runtime, base, nativeRoom,
        args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(nativeRoom, args) end
        local additional, occurrence = room.additional(state, "zagreusContract")
        pendingAdditional = occurrence and { occurrence = occurrence, additional = additional } or nil
        if type(nativeRoom) == "table" then nativeRoom.ZagreusContractSuccess = additional ~= nil end
        local ok, result = pcall(base, nativeRoom, args)
        pendingAdditional = nil
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    return {
        currentAdditional = function() return pendingAdditional end,
    }
end

return hooks
