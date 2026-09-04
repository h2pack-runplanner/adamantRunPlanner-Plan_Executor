-- Exact Fig Leaf phase-result steering. Native spawn handlers retain the
-- skip lifecycle, use consumption, and biome latch; this module only fixes
-- the one RandomChance call belonging to the named handler.
local figLeaf = {}
local unpackValues = table.unpack

local function packValues(...)
    return { n = select("#", ...), ... }
end

local function decision(room, state, encounter)
    if state == nil or state.state ~= "synchronized" or type(encounter) ~= "table" then return nil end
    local current = room.current(state)
    if current == nil or type(room.encounterPhase) ~= "function" then return nil end
    local phase = room.encounterPhase(state, encounter)
    if phase == nil or phase.figLeafSkip == nil then return nil end
    return { skip = phase.figLeafSkip, used = false }
end

function figLeaf.attach(module, getState, report, room)
    local active

    local function attachSpawnHandler(functionName, hookId)
        module.hooks.wrap(functionName, hookId, function(_, runtime, base, ...)
            local encounter = select(1, ...)
            local prior = active
            active = decision(room, getState(runtime), encounter)
            local results = packValues(pcall(base, ...))
            local ok = results[1]
            active = prior
            if not ok then error(results[2], 0) end
            report(runtime)
            return unpackValues(results, 2, results.n)
        end)
    end

    attachSpawnHandler("HandleEncounterPreSpawns", "run-planner-fig-leaf-pre-spawns")
    attachSpawnHandler("HandleEnemySpawns", "run-planner-fig-leaf-enemy-spawns")

    module.hooks.wrap("RandomChance", "run-planner-fig-leaf-decision", function(_, _, base,
        chance, args, ...)
        if active ~= nil and not active.used then
            active.used = true
            return active.skip
        end
        return base(chance, args, ...)
    end)
end

return figLeaf
