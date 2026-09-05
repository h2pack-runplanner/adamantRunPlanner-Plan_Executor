-- Resolve named room-exit conformance facts against an already-expanded
-- diagnostic state. The diagnostic decoder owns sparse-frame validation; this
-- module owns only the fact-kind-to-state projection.
local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")

local conformance = {}

local readers = {
    steadyGrowth = function(state) return state.retainedEffects.steadyGrowth end,
    chaos = function(state) return state.chaos end,
    keepsakeEffects = function(state) return state.retainedEffects.keepsakes end,
    rewardPriorities = function(state) return state.rewardPriorities end,
    pathOfStars = function(state) return state.hexProgress end,
    forfeit = function(state) return state.forfeit end,
    stygianWell = function(state) return state.retainedEffects.stygianWell end,
}

function conformance.resolve(value, state, label)
    local record, errorMessage = p.exact(value, { "facts" }, {}, label)
    if not record then return nil, errorMessage end
    local facts, factsError = p.arr(record.facts, label .. ".facts")
    if not facts then return nil, factsError end
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
        expected[fact.kind] = read(state)
    end
    return expected
end

return conformance
