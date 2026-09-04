-- Declaration-driven encounter phases and exact native encounter identity.
-- The native encounter table is the carrier identity; its declaration name is
-- only a structural fact used by room-entry proof.
local phases = {}
local nativeBindings = setmetatable({}, { __mode = "k" })

local function nativePhases(room)
    if type(room.Encounters) == "table" and #room.Encounters > 0 then return room.Encounters end
    if room.Encounter ~= nil then return { room.Encounter } end
    return {}
end

local function phaseAt(occurrence, slotKey)
    for _, phase in ipairs(occurrence.overview.encounterPhases or {}) do
        if phase.slotKey == slotKey then return phase end
    end
    return nil
end

function phases.at(occurrence, index)
    return occurrence and occurrence.overview and occurrence.overview.encounterPhases
        and occurrence.overview.encounterPhases[index] or nil
end

local function nativeName(value)
    return type(value) == "table" and (value.GenusName or value.Name or value.EncounterName) or value
end

function phases.choose(occurrence, slotKey)
    local phase = phaseAt(occurrence, slotKey)
    return phase and phase.encounterKey or nil
end

function phases.bind(occurrence, nativeEncounter, slotKey)
    if type(nativeEncounter) ~= "table" then
        return nil, {
            checkpoint = "encounter-binding", expected = "native encounter object", observed = nativeEncounter,
        }
    end
    local phase = phaseAt(occurrence, slotKey)
    if phase == nil then
        return nil, { checkpoint = "encounter-binding", expected = "published encounter phase", observed = slotKey }
    end
    local prior = nativeBindings[nativeEncounter]
    if prior ~= nil then
        if prior.occurrenceId ~= occurrence.id or prior.phase.slotKey ~= phase.slotKey then
            return nil, {
                checkpoint = "encounter-binding", expected = "one phase per native encounter object",
                observed = slotKey,
            }
        end
        return phase
    end
    nativeBindings[nativeEncounter] = { occurrenceId = occurrence.id, phase = phase }
    return phase
end

function phases.forNative(nativeEncounter)
    return type(nativeEncounter) == "table" and nativeBindings[nativeEncounter] or nil
end

function phases.isFinal(occurrence, phase)
    local expected = occurrence and occurrence.overview and occurrence.overview.encounterPhases or {}
    return #expected > 0 and expected[#expected] == phase
end

function phases.prove(occurrence, nativeRoom)
    local actual = nativePhases(nativeRoom)
    local expected = occurrence.overview.encounterPhases or {}
    if #actual ~= #expected then
        return nil, { kind = "encounterCount", expected = #expected, observed = #actual }
    end
    for index, expectedPhase in ipairs(expected) do
        local native = actual[index]
        if nativeName(native) ~= expectedPhase.encounterKey then
            return nil, {
                kind = "encounter", expected = expectedPhase.encounterKey,
                observed = nativeName(native),
            }
        end
    end
    return true
end

return phases
