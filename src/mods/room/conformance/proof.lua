-- Pure room-exit proof over the planner-published conformance facts. Native
-- observation is injected so this module owns comparison without owning hooks.
local proof = {}

local function equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

function proof.prove(occurrence, read)
    for _, fact in ipairs((occurrence.roomExitConformance or {}).facts or {}) do
        local expected = occurrence.conformanceExpected and occurrence.conformanceExpected[fact.kind]
        local observed = type(read) == "function" and read(fact.kind, expected) or nil
        if expected == nil or observed == nil or not equal(expected, observed) then
            return nil, {
                checkpoint = "room-exit-conformance:" .. fact.kind,
                expected = expected,
                observed = observed,
            }
        end
    end
    return true
end

return proof
