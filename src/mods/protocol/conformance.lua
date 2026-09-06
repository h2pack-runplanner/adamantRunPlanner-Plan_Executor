-- Resolve named room-exit conformance facts against an already-expanded
-- diagnostic state. The diagnostic decoder owns sparse-frame validation; this
-- module owns only the fact-kind-to-state projection.
local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")

local conformance = {}

local function traitInventoryExpected(frames)
    local entry = frames and frames.roomEntered
    local exit = frames and frames.beforeRoomExit
    if type(entry) ~= "table" or type(exit) ~= "table"
        or type(entry.traits) ~= "table" or type(exit.traits) ~= "table" then
        return nil
    end
    local modeled = {}
    for _, row in ipairs(entry.traits.equipped or {}) do
        if type(row) == "table" and type(row.traitKey) == "string" then modeled[row.traitKey] = true end
    end
    for _, row in ipairs(exit.traits.equipped or {}) do
        if type(row) == "table" and type(row.traitKey) == "string" then modeled[row.traitKey] = true end
    end
    local present, observed = {}, {}
    for _, row in ipairs(exit.traits.equipped or {}) do
        if type(row) == "table" and modeled[row.traitKey] then
            local projected = { traitKey = row.traitKey }
            if row.rarity ~= nil then projected.rarity = row.rarity end
            if row.level ~= nil then projected.level = row.level end
            if row.hammerRank ~= nil then projected.hammerRank = row.hammerRank end
            present[#present + 1] = projected
            observed[row.traitKey] = true
        end
    end
    local absent = {}
    for _, row in ipairs(entry.traits.equipped or {}) do
        if type(row) == "table" and modeled[row.traitKey] and not observed[row.traitKey] then
            absent[#absent + 1] = row.traitKey
        end
    end
    table.sort(present, function(left, right) return left.traitKey < right.traitKey end)
    table.sort(absent)
    return { present = present, absent = absent }
end

local readers = {
    elementCounts = function(state) return state.traits.elements end,
    steadyGrowth = function(state) return state.retainedEffects.steadyGrowth end,
    chaos = function(state) return state.chaos end,
    keepsakeEffects = function(state) return state.retainedEffects.keepsakes end,
    rewardPriorities = function(state) return state.rewardPriorities end,
    pathOfStars = function(state) return state.hexProgress end,
    forfeit = function(state) return state.forfeit end,
    stygianWell = function(state) return state.retainedEffects.stygianWell end,
    traitInventory = traitInventoryExpected,
}

function conformance.resolve(value, state, label)
    local record, errorMessage = p.exact(value, { "facts" }, {}, label)
    if not record then return nil, errorMessage end
    local facts, factsError = p.arr(record.facts, label .. ".facts")
    if not facts then return nil, factsError end
    local exitState = state and state.beforeRoomExit or state
    local expected = {}
    for index, factValue in ipairs(facts) do
        local fact, factError = p.exact(
            factValue,
            { "kind" },
            {},
            label .. ".facts[" .. index .. "]"
        )
        if not fact then return nil, factError end
        local read = readers[fact.kind]
        if not read or expected[fact.kind] ~= nil then
            return p.fail(label .. " has unsupported or duplicate conformance fact")
        end
        expected[fact.kind] = read(fact.kind == "traitInventory" and state or exitState)
        if expected[fact.kind] == nil then
            return p.fail(label .. ".facts[" .. index .. "] requires complete diagnostic frames")
        end
    end
    return expected
end

return conformance
