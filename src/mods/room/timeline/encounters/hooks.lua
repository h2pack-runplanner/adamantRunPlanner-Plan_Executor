-- Encounter selection, native encounter identity, and lifecycle contacts for
-- one active room occurrence. Encounter-owned outcomes attach beside this
-- boundary; native encounter names never recover a phase after selection.
local automatic = type(import) == "function" and import("mods/room/timeline/encounters/automatic.lua")
    or require("mods.room.timeline.encounters.automatic")
local boss = type(import) == "function" and import("mods/room/timeline/encounters/boss.lua")
    or require("mods.room.timeline.encounters.boss")
local nemesis = type(import) == "function" and import("mods/room/timeline/encounters/nemesis.lua")
    or require("mods.room.timeline.encounters.nemesis")
local figLeaf = type(import) == "function" and import("mods/keepsakes/fig_leaf.lua")
    or require("mods.keepsakes.fig_leaf")
local gorgon = type(import) == "function" and import("mods/keepsakes/gorgon.lua")
    or require("mods.keepsakes.gorgon")

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
    local directEncounterSequences = setmetatable({}, { __mode = "k" })

    module.hooks.wrap("SetupRoomMultipleEncountersData", "run-planner-encounter-assembly", function(_, runtime,
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

    module.hooks.wrap("ChooseEncounter", "run-planner-encounter-choice", function(_, runtime, base, currentRun,
        nativeRoom, args)
        local state = getState(runtime)
        if state == nil or state.state ~= "synchronized" then return base(currentRun, nativeRoom, args) end

        local phase
        if encounterIndex ~= nil then
            encounterIndex = encounterIndex + 1
            phase = room.encounterAt(state, encounterIndex, nativeRoom)
        else
            local first = room.encounterAt(state, 1, nativeRoom)
            local second = room.encounterAt(state, 2, nativeRoom)
            if second == nil then
                phase = first
            elseif type(nativeRoom) == "table" then
                local sequence = directEncounterSequences[nativeRoom]
                local occurrenceId = nativeRoom.__runPlannerExecutionRoomId
                if sequence == nil or sequence.occurrenceId ~= occurrenceId then
                    sequence = { index = 1, occurrenceId = occurrenceId, done = false }
                    directEncounterSequences[nativeRoom] = sequence
                end
                if not sequence.done then
                    phase = room.encounterAt(state, sequence.index, nativeRoom)
                    sequence.index = sequence.index + 1
                    if phase == nil then sequence.done = true end
                end
            end
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
            room.bindEncounter(state, result, phase.slotKey, nativeRoom)
        end
        return result
    end)

    module.hooks.wrap("StartEncounter", "run-planner-encounter-start", function(_, runtime, base, currentRun,
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

    module.hooks.wrap("EndEncounterEffects", "run-planner-encounter-end", function(_, runtime, base, currentRun,
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
    figLeaf.attach(module, getState, report, room)
    gorgon.attach(module, getState, report, room)
end

return hooks
