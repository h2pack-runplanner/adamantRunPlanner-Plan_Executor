-- Encounter selection, native encounter identity, and lifecycle contacts for
-- one active room occurrence. Encounter-owned outcomes attach beside this
-- boundary; native encounter names never recover a phase after selection.
local automatic = type(import) == "function" and import("mods/room/timeline/encounters/automatic.lua")
    or require("mods.room.timeline.encounters.automatic")
local boss = type(import) == "function" and import("mods/room/timeline/encounters/boss.lua")
    or require("mods.room.timeline.encounters.boss")
local nemesis = type(import) == "function" and import("mods/room/timeline/encounters/nemesis.lua")
    or require("mods.room.timeline.encounters.nemesis")

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

function hooks.attach(module, session, getState, report, room)
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

        local phase
        if encounterIndex ~= nil then
            encounterIndex = encounterIndex + 1
            phase = room.encounterAt(state, encounterIndex)
        else
            local active = room.current(state)
            local first = active and room.encounterAt(state, 1) or nil
            phase = first and room.encounterAt(state, 2) == nil and first or nil
        end
        local declaration
        if phase ~= nil then
            local gameValue = _G.game or game
            declaration = gameValue and gameValue.EncounterData
                and gameValue.EncounterData[phase.encounterKey] or nil
        end
        local result = declaration ~= nil
            and chooseForcedEncounter(base, currentRun, nativeRoom, args, declaration)
            or base(currentRun, nativeRoom, args)
        if phase ~= nil and type(result) == "table" then
            room.bindEncounter(state, result, phase.slotKey)
        end
        return result
    end)

    module.hooks.wrap("StartEncounter", "execution-v10-encounter-start", function(_, runtime, base, currentRun,
        nativeRoom, encounter)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then
            return base(currentRun, nativeRoom, encounter)
        end
        room.startEncounter(state, encounter)
        local result = base(currentRun, nativeRoom, encounter)
        report(runtime)
        return result
    end)

    module.hooks.wrap("EndEncounterEffects", "execution-v10-encounter-end", function(_, runtime, base, currentRun,
        nativeRoom, encounter)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, nativeRoom, encounter) end
        local phase = room.encounterPhase(state, encounter)
        local final = phase ~= nil and room.encounterIsFinal(state, encounter) or false
        if phase ~= nil then room.window(state, "encounterEnd:" .. phase.slotKey) end
        local result = base(currentRun, nativeRoom, encounter)
        if final then room.window(state, "afterCombat") end
        report(runtime)
        return result
    end)

    automatic.attach(module, session, getState, report, room)
    boss.attach(module, session, getState, report, room)
    nemesis.attach(module, session, getState, report, room)
end

return hooks
