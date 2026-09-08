-- Strict execution-protocol composition. Fact-family modules validate closed wire
-- shapes; this root owns only the execution-plan envelope and derived indexes.
local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")
local rewards = type(import) == "function" and import("mods/protocol/rewards.lua")
    or require("mods.protocol.rewards")
local occurrences = type(import) == "function" and import("mods/protocol/occurrences.lua")
    or require("mods.protocol.occurrences")
local loadout = type(import) == "function" and import("mods/protocol/loadout.lua")
    or require("mods.protocol.loadout")
local resources = type(import) == "function" and import("mods/protocol/resources.lua")
    or require("mods.protocol.resources")

local protocol = {
    FORMAT = "run-planner-execution",
    VERSION = 33,
    CATALOG_VERSION = "0.55.0-anvil-of-fates",
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
        4
    )
    if not biomeKeys then return nil, biomeError end
    local supported = (#biomeKeys == 1 and biomeKeys[1] == "F")
        or (#biomeKeys == 2 and biomeKeys[1] == "F" and biomeKeys[2] == "G")
        or (#biomeKeys == 3 and biomeKeys[1] == "F" and biomeKeys[2] == "G" and biomeKeys[3] == "H")
        or (#biomeKeys == 4 and biomeKeys[1] == "F" and biomeKeys[2] == "G" and biomeKeys[3] == "H"
            and biomeKeys[4] == "I")
        or (#biomeKeys == 1 and biomeKeys[1] == "N")
        or (#biomeKeys == 2 and biomeKeys[1] == "N" and biomeKeys[2] == "O")
        or (#biomeKeys == 3 and biomeKeys[1] == "N" and biomeKeys[2] == "O" and biomeKeys[3] == "P")
        or (#biomeKeys == 4 and biomeKeys[1] == "N" and biomeKeys[2] == "O" and biomeKeys[3] == "P"
            and biomeKeys[4] == "Q")
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
        resources = plan.resources,
        occurrences = decodedOccurrences,
    }
end

local function validateResources(resourcePolicy, selected, occurrenceIds)
    local rows = resourcePolicy.occurrences
    if #rows ~= #selected then
        return p.fail("execution plan.resources must follow selectedOccurrenceIds exactly")
    end
    for index, row in ipairs(rows) do
        if row.occurrenceId ~= selected[index] or occurrenceIds[row.occurrenceId] == nil then
            return p.fail("execution plan.resources has an unresolved or misordered occurrence")
        end
    end
    return true
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
            "routeKey", "startingLoadout", "startingKeepsake", "extent", "selectedOccurrenceIds", "resources",
            "occurrences",
        },
        {},
        "execution plan"
    )
    if not plan then return nil, errorMessage end
    if plan.format ~= protocol.FORMAT
        or plan.protocolVersion ~= protocol.VERSION
        or plan.catalogVersion ~= protocol.CATALOG_VERSION
        or (plan.routeKey ~= "Underworld" and plan.routeKey ~= "Surface")
        or not p.str(plan.projectId, "execution plan.projectId")
        or type(plan.planFingerprint) ~= "string"
        or not plan.planFingerprint:match("^[0-9a-f]+$")
        or #plan.planFingerprint ~= 8 then
        return p.fail("execution plan has unsupported identity")
    end
    local _, extentError = extent(plan.extent)
    if extentError then return nil, extentError end
    if (plan.routeKey == "Underworld" and plan.extent.biomeKeys[1] ~= "F")
        or (plan.routeKey == "Surface" and plan.extent.biomeKeys[1] ~= "N") then
        return p.fail("execution plan.routeKey disagrees with extent")
    end
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
    for _, occurrence in ipairs(decoded) do
        local included = false
        for _, biomeKey in ipairs(plan.extent.biomeKeys) do
            if occurrence.biomeKey == biomeKey then included = true break end
        end
        if not included then return p.fail("execution plan.occurrences contains a biome outside extent") end
    end
    local resourcePolicy, resourceError = resources.decode(plan.resources, "execution plan.resources")
    if not resourcePolicy then return nil, resourceError end
    local resourcesValid, resourcesValidationError = validateResources(
        resourcePolicy, selected, idsOrError
    )
    if not resourcesValid then return nil, resourcesValidationError end
    local derived = detachDerived(decoded)
    if p.fingerprint(fingerprintBody(plan, decoded)) ~= plan.planFingerprint then
        return p.fail("execution plan fingerprint does not match contents")
    end
    attachDerived(decoded, derived)
    plan.resources = resourcePolicy
    plan.occurrences = decoded
    plan.occurrencesById = idsOrError
    plan.kind = "ready"
    return plan
end

return protocol
