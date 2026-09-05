-- Strict execution-protocol composition. Fact-family modules validate closed wire
-- shapes; this root owns only the execution-plan envelope and derived indexes.
local p = type(import) == "function" and import("mods/protocol_primitives.lua")
    or require("mods/protocol_primitives")
local rewards = type(import) == "function" and import("mods/protocol_rewards.lua")
    or require("mods/protocol_rewards")
local occurrences = type(import) == "function" and import("mods/protocol_occurrences.lua")
    or require("mods/protocol_occurrences")
local loadout = type(import) == "function" and import("mods/loadout/protocol.lua")
    or require("mods.loadout.protocol")

local protocol = {
    FORMAT = "run-planner-execution",
    VERSION = 21,
    CATALOG_VERSION = "0.54.0-required-boss-rewards",
    MAX_ITEMS = p.MAX_ITEMS,
    MAX_STRING = p.MAX_STRING,
    fingerprint = p.fingerprint,
}

local function extent(value)
    local record, errorMessage = p.exact(
        value,
        { "kind", "biomeKeys", "terminalBiomeKey" },
        {},
        "execution plan.extent"
    )
    if not record then return nil, errorMessage end
    local biomeKeys, biomeError = p.strings(
        record.biomeKeys,
        "execution plan.extent.biomeKeys",
        2
    )
    if not biomeKeys then return nil, biomeError end
    local supported = (#biomeKeys == 1 and biomeKeys[1] == "F")
        or (#biomeKeys == 2 and biomeKeys[1] == "F" and biomeKeys[2] == "G")
    if record.kind ~= "configuredPrefix" or not supported
        or record.terminalBiomeKey ~= biomeKeys[#biomeKeys] then
        return p.fail("execution plan.extent is unsupported")
    end
    return record
end

local function startingKeepsake(value)
    local record, errorMessage = p.exact(
        value,
        { "keepsakeKey" },
        { "equipResults" },
        "execution plan.startingKeepsake"
    )
    if not record then return nil, errorMessage end
    if not p.str(record.keepsakeKey, "execution plan.startingKeepsake.keepsakeKey") then
        return p.fail("execution plan has invalid starting keepsake")
    end
    if record.equipResults ~= nil then
        local _, equipError = rewards.equip(
            record.equipResults,
            "execution plan.startingKeepsake.equipResults"
        )
        if equipError then return nil, equipError end
    end
    return record
end

local function fingerprintBody(plan, decodedOccurrences)
    return {
        format = plan.format,
        protocolVersion = plan.protocolVersion,
        catalogVersion = plan.catalogVersion,
        projectId = plan.projectId,
        routeKey = plan.routeKey,
        startingLoadout = plan.startingLoadout,
        startingKeepsake = plan.startingKeepsake,
        extent = plan.extent,
        selectedOccurrenceIds = plan.selectedOccurrenceIds,
        occurrences = decodedOccurrences,
    }
end

local function detachDerived(rows)
    local derived = {}
    for index, row in ipairs(rows) do
        derived[index] = {
            transactionsByOwner = row.transactionsByOwner,
            conformanceExpected = row.conformanceExpected,
        }
        row.transactionsByOwner = nil
        row.conformanceExpected = nil
    end
    return derived
end

local function attachDerived(rows, derived)
    for index, row in ipairs(rows) do
        row.transactionsByOwner = derived[index].transactionsByOwner
        row.conformanceExpected = derived[index].conformanceExpected
    end
end

function protocol.decode(value)
    local plan, errorMessage = p.exact(
        value,
        {
            "format", "protocolVersion", "catalogVersion", "projectId", "planFingerprint",
            "routeKey", "startingLoadout", "startingKeepsake", "extent", "selectedOccurrenceIds", "occurrences",
        },
        {},
        "execution plan"
    )
    if not plan then return nil, errorMessage end
    if plan.format ~= protocol.FORMAT
        or plan.protocolVersion ~= protocol.VERSION
        or plan.catalogVersion ~= protocol.CATALOG_VERSION
        or plan.routeKey ~= "Underworld"
        or not p.str(plan.projectId, "execution plan.projectId")
        or type(plan.planFingerprint) ~= "string"
        or not plan.planFingerprint:match("^[0-9a-f]+$")
        or #plan.planFingerprint ~= 8 then
        return p.fail("execution plan has unsupported identity")
    end
    local _, extentError = extent(plan.extent)
    if extentError then return nil, extentError end
    local _, loadoutError = loadout.decode(plan.startingLoadout)
    if loadoutError then return nil, loadoutError end
    local _, keepsakeError = startingKeepsake(plan.startingKeepsake)
    if keepsakeError then return nil, keepsakeError end
    local selected, selectedError = p.strings(
        plan.selectedOccurrenceIds,
        "execution plan.selectedOccurrenceIds"
    )
    if not selected then return nil, selectedError end
    local decoded, idsOrError = occurrences.decode(
        plan.occurrences,
        selected,
        "execution plan.occurrences"
    )
    if not decoded then return nil, idsOrError end
    local derived = detachDerived(decoded)
    if p.fingerprint(fingerprintBody(plan, decoded)) ~= plan.planFingerprint then
        return p.fail("execution plan fingerprint does not match contents")
    end
    attachDerived(decoded, derived)
    plan.occurrences = decoded
    plan.occurrencesById = idsOrError
    plan.kind = "ready"
    return plan
end

return protocol
