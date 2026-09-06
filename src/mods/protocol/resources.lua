-- Strict decoding for the route-owned physical resource-point policy.
local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")

local resources = {}
local families = { Pickaxe = true, Exorcism = true, Shovel = true, Fishing = true }
local function occurrence(value, label)
    local record, errorMessage = p.exact(
        value,
        { "occurrenceId", "pointDispositions" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    if not p.str(record.occurrenceId, label .. ".occurrenceId") then
        return p.fail(label .. " has invalid occurrenceId")
    end
    local pointRecord, pointError = p.exact(
        record.pointDispositions,
        { "Pickaxe", "Exorcism", "Shovel", "Fishing" },
        {},
        label .. ".pointDispositions"
    )
    if not pointRecord then return nil, pointError end
    local pointDispositions = {}
    for family in pairs(families) do
        local disposition = p.one(
            pointRecord[family],
            { native = true, suppress = true, force = true },
            label .. ".pointDispositions." .. family
        )
        if not disposition then return nil, label .. " has invalid point disposition" end
        pointDispositions[family] = disposition
    end
    local result = {
        occurrenceId = record.occurrenceId,
        pointDispositions = pointDispositions,
    }
    return result
end

function resources.decode(value, label)
    local record, errorMessage = p.exact(value, { "occurrences" }, {}, label)
    if not record then return nil, errorMessage end
    local rows, rowsError = p.arr(record.occurrences, label .. ".occurrences")
    if not rows then return nil, rowsError end
    local seen = {}
    local result = {}
    for index, valueRow in ipairs(rows) do
        local row, rowError = occurrence(valueRow, label .. ".occurrences[" .. index .. "]")
        if not row then return nil, rowError end
        if seen[row.occurrenceId] then return p.fail(label .. " has duplicate occurrenceId") end
        seen[row.occurrenceId] = true
        result[index] = row
    end
    return { occurrences = result }
end

return resources
