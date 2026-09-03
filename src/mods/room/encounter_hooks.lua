-- Native encounter contacts for one active room session.
local hooks = {}

local function chooseForcedEncounter(base, currentRun, nativeRoom, args, declaration)
    if type(currentRun) ~= "table" or declaration == nil then return nil end
    local priorRunForce = currentRun.ForceNextEncounterData
    local priorGlobalForce = _G.ForceNextEncounter
    currentRun.ForceNextEncounterData = declaration
    _G.ForceNextEncounter = nil
    local ok, result = pcall(base, currentRun, nativeRoom, args)
    currentRun.ForceNextEncounterData = priorRunForce
    _G.ForceNextEncounter = priorGlobalForce
    if not ok then error(result, 0) end
    return result
end

function hooks.attach(module, _, getState, report, room)
    local encounterIndex

    module.hooks.wrap("SetupRoomMultipleEncountersData", "execution-v10-encounter-assembly", function(_, runtime,
        base, nativeRoom, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(nativeRoom, args) end
        encounterIndex = 0
        local ok, result = pcall(base, nativeRoom, args)
        encounterIndex = nil
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("ChooseEncounter", "execution-v10-encounter-choice", function(_, runtime, base, currentRun,
        nativeRoom, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, nativeRoom, args) end
        local declaration
        local active = room.current(state)
        if encounterIndex ~= nil then
            encounterIndex = encounterIndex + 1
            local phase = active and active.occurrence.overview.encounterPhases[encounterIndex]
            declaration = phase and (_G.game or game).EncounterData[phase.encounterKey]
        elseif active and #active.occurrence.overview.encounterPhases == 1 then
            local phase = active.occurrence.overview.encounterPhases[1]
            declaration = (_G.game or game).EncounterData[phase.encounterKey]
        end
        if declaration ~= nil then return chooseForcedEncounter(base, currentRun, nativeRoom, args, declaration) end
        return base(currentRun, nativeRoom, args)
    end)

    module.hooks.wrap("EndEncounterEffects", "execution-v10-encounter-end", function(_, runtime, base, currentRun,
        nativeRoom, encounter)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, nativeRoom, encounter) end
        local active = room.current(state)
        local observedName = type(encounter) == "table" and (encounter.Name or encounter.EncounterName)
        local phaseKey
        for _, phase in ipairs(active and active.occurrence.overview.encounterPhases or {}) do
            if phase.encounterKey == observedName then phaseKey = phase.slotKey; break end
        end
        if phaseKey then room.window(state, "encounterEnd:" .. phaseKey) end
        local result = base(currentRun, nativeRoom, encounter)
        room.window(state, "afterCombat")
        report(runtime)
        return result
    end)
end

return hooks
