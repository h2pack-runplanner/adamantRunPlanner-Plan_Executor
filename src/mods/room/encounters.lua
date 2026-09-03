-- Encounter realization and proof inside one active room occurrence.
local encounters = {}

local function name(value)
    return type(value) == "table" and (value.GenusName or value.Name or value.EncounterName)
end

local function nativePhases(room)
    if type(room.Encounters) == "table" and #room.Encounters > 0 then return room.Encounters end
    if room.Encounter ~= nil then return { room.Encounter } end
    return {}
end

function encounters.choose(occurrence, slotKey)
    for _, phase in ipairs(occurrence.overview.encounterPhases or {}) do
        if phase.slotKey == slotKey then return phase.encounterKey end
    end
    return nil
end

function encounters.prove(occurrence, nativeRoom)
    local actual = nativePhases(nativeRoom)
    local expected = occurrence.overview.encounterPhases or {}
    if #actual ~= #expected then
        return nil, { kind = "encounterCount", expected = #expected, observed = #actual }
    end
    for index, phase in ipairs(expected) do
        local native = actual[index]
        if name(native) ~= phase.encounterKey and native ~= phase.encounterKey then
            return nil, { kind = "encounter", expected = phase.encounterKey, observed = name(native) or native }
        end
    end
    return true
end

return encounters
