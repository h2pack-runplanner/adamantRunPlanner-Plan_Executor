local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")
local rewards = type(import) == "function" and import("mods/protocol/rewards.lua")
    or require("mods.protocol.rewards")
local overview = type(import) == "function" and import("mods/protocol/overview.lua")
    or require("mods.protocol.overview")
local timeline = type(import) == "function" and import("mods/protocol/timeline.lua")
    or require("mods.protocol.timeline")
local diagnostics = type(import) == "function" and import("mods/protocol/diagnostics.lua")
    or require("mods.protocol.diagnostics")
local conformance = type(import) == "function" and import("mods/protocol/conformance.lua")
    or require("mods.protocol.conformance")

local occurrences = {}

local function validateFieldsCageSlots(row, label)
    local layout = row.overview.fields
    if layout == nil then return true end
    local activeCagePhases = {}
    for _, phase in ipairs(row.overview.encounterPhases or {}) do
        if string.match(phase.slotKey, "^Cage%d+$") then
            activeCagePhases[#activeCagePhases + 1] = phase
        end
    end
    if #activeCagePhases ~= #layout.cagePoints then
        return p.fail(label .. ".cagePoints must match the active cage encounter phases")
    end
    for index, phase in ipairs(activeCagePhases) do
        local expectedPhase = string.format("Cage%02d", index)
        local expectedSlot = "cage" .. index
        if phase.slotKey ~= expectedPhase or layout.cagePoints[index].slotKey ~= expectedSlot then
            return p.fail(label .. ".cagePoints must use canonical ordered cage slots")
        end
    end
    return true
end

local function anomaly(value, biomeKey, label)
    local record, errorMessage = p.exact(
        value,
        { "replacedRoomGameName", "success" },
        {},
        label
    )
    if not record then return nil, errorMessage end
    if biomeKey ~= "G"
        or not p.str(record.replacedRoomGameName, label .. ".replacedRoomGameName")
        or not p.bool(record.success, label .. ".success") then
        return p.fail(label .. " is invalid")
    end
    return record
end

local function assertRoomReference(value, ids, label)
    local reference, errorMessage = p.roomRef(value, label)
    if not reference then return nil, errorMessage end
    local target = ids[reference.id]
    if target == nil
        or target.biomeKey ~= reference.biomeKey
        or target.gameName ~= reference.gameName then
        return p.fail(label .. " is unresolved or contradicts occurrence identity")
    end
    return reference
end

local function doors(value, ids, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    if record.kind == "batch" then
        local batch, batchError = p.exact(
            record,
            { "kind", "owner", "targets" },
            { "resolvedSharedRewardStoreKey" },
            label
        )
        if not batch then return nil, batchError end
        if not p.str(batch.owner, label .. ".owner", p.MAX_OWNER_STRING)
            or (batch.resolvedSharedRewardStoreKey ~= nil
                and not p.str(batch.resolvedSharedRewardStoreKey, label .. ".resolvedSharedRewardStoreKey")) then
            return p.fail(label .. " is malformed")
        end
        local targets, targetsError = p.arr(batch.targets, label .. ".targets")
        if not targets then return nil, targetsError end
        local exitKeys = {}
        local continuations = {}
        for index, valueTarget in ipairs(targets) do
            local target, targetError = p.exact(
                valueTarget,
                { "exitKey", "index", "room" },
                { "reward", "cageRewards" },
                label .. ".targets[" .. index .. "]"
            )
            if not target then return nil, targetError end
            if not p.str(target.exitKey, label .. ".exitKey")
                or exitKeys[target.exitKey]
                or not p.int(target.index, label .. ".index", 0) then
                return p.fail(label .. " has invalid door target")
            end
            exitKeys[target.exitKey] = true
            local reference, referenceError = assertRoomReference(target.room, ids, label .. ".room")
            if not reference then return nil, referenceError end
            continuations[reference.id] = true
            local targetOccurrence = ids[reference.id]
            local targetLabel = label .. ".targets[" .. index .. "]"
            if targetOccurrence.kind == "FieldsEncounter" then
                if target.cageRewards == nil then
                    return p.fail(targetLabel .. ".cageRewards is required for FieldsEncounter target")
                end
                if #target.cageRewards ~= #targetOccurrence.overview.fields.cagePoints then
                    return p.fail(targetLabel .. ".cageRewards must match Fields target cagePoints length")
                end
            elseif target.cageRewards ~= nil then
                return p.fail(targetLabel .. ".cageRewards is only valid for FieldsEncounter target")
            end
            if target.reward ~= nil then
                local _, rewardError = rewards.reward(target.reward, label .. ".reward")
                if rewardError then return nil, rewardError end
            end
            if target.cageRewards ~= nil then
                local cageRewards, cageError = p.arr(target.cageRewards, label .. ".cageRewards")
                if not cageRewards then return nil, cageError end
                for cageIndex, cageReward in ipairs(cageRewards) do
                    local _, cageRewardError = rewards.reward(
                        cageReward, label .. ".cageRewards[" .. cageIndex .. "]"
                    )
                    if cageRewardError then return nil, cageRewardError end
                end
            end
        end
        return batch, continuations
    end
    if record.kind == "fixed" then
        local fixed, fixedError = p.exact(record, { "kind", "owner", "target" }, {}, label)
        if not fixed then return nil, fixedError end
        if not p.str(fixed.owner, label .. ".owner", p.MAX_OWNER_STRING) then return p.fail(label .. " invalid owner") end
        local reference, referenceError = assertRoomReference(fixed.target, ids, label .. ".target")
        if not reference then return nil, referenceError end
        return fixed, { [reference.id] = true }
    end
    if record.kind == "terminal" then
        local terminal, terminalError = p.exact(record, { "kind", "owner" }, {}, label)
        if not terminal then return nil, terminalError end
        if not p.str(terminal.owner, label .. ".owner", p.MAX_OWNER_STRING) then
            return p.fail(label .. " has invalid owner")
        end
        return terminal, {}
    end
    return p.fail(label .. ".kind is unsupported")
end

function occurrences.decode(value, selected, label)
    local rows, errorMessage = p.arr(value, label)
    if not rows then return nil, errorMessage end
    local ids = {}
    local globalOwners = {}
    local framing = { next = 0, values = {} }
    local result = setmetatable({}, getmetatable(rows))
    for index, valueRow in ipairs(rows) do
        local row, rowError = p.exact(
            valueRow,
            { "id", "owner", "biomeKey", "gameName", "kind", "overview", "timeline", "doors" },
            { "anomaly", "roomExitConformance", "diagnostics" },
            label .. "[" .. index .. "]"
        )
        if not row then return nil, rowError end
        if not p.str(row.id, label .. ".id", 256)
            or ids[row.id]
            or not p.str(row.owner, label .. ".owner", p.MAX_OWNER_STRING)
            or not p.one(row.biomeKey, { F = true, G = true, H = true }, label .. ".biomeKey")
            or not p.str(row.gameName, label .. ".gameName")
            or not p.str(row.kind, label .. ".kind") then
            return p.fail(label .. " has invalid occurrence identity")
        end
        ids[row.id] = row
        local _, overviewError = overview.decode(row.overview, label .. ".overview")
        if overviewError then return nil, overviewError end
        if (row.kind == "FieldsEncounter") ~= (row.overview.fields ~= nil) then
            return p.fail(label .. ".overview.fields is required for FieldsEncounter")
        end
        if row.overview.fields ~= nil and row.biomeKey ~= "H" then
            return p.fail(label .. ".overview.fields is only valid for H FieldsEncounter")
        end
        local fieldsSlotsOk, fieldsSlotsError = validateFieldsCageSlots(
            row, label .. ".overview.fields"
        )
        if not fieldsSlotsOk then return nil, fieldsSlotsError end
        if row.anomaly ~= nil then
            local _, anomalyError = anomaly(row.anomaly, row.biomeKey, label .. ".anomaly")
            if anomalyError then return nil, anomalyError end
        end
        local _, byOwnerOrError = timeline.decode(
            row.timeline,
            label .. ".timeline",
            globalOwners
        )
        if type(byOwnerOrError) == "string" then return nil, byOwnerOrError end
        row.transactionsByOwner = byOwnerOrError
        local hadDiagnostics = row.diagnostics ~= nil
        local expanded, diagnosticError = diagnostics.expand(
            row.diagnostics,
            label .. ".diagnostics",
            framing
        )
        if not expanded then return nil, diagnosticError end
        if hadDiagnostics then row.diagnostics = expanded end
        if row.roomExitConformance ~= nil then
            if expanded.beforeRoomExit == nil then
                return p.fail(label .. " conformance requires beforeRoomExit diagnostic")
            end
            local expected, conformanceError = conformance.resolve(
                row.roomExitConformance,
                expanded,
                label .. ".roomExitConformance"
            )
            if not expected then return nil, conformanceError end
            if expected.elementCounts == nil then
                return p.fail(label .. " conformance is missing elementCounts")
            end
            row.conformanceExpected = expected
        elseif expanded.beforeRoomExit ~= nil then
            return p.fail(label .. " beforeRoomExit diagnostic is missing room-exit conformance")
        end
        result[index] = row
    end
    if #selected == 0 or result[1] == nil or selected[1] ~= result[1].id then
        return p.fail("selected route must start at opening occurrence")
    end
    local selectedSeen = {}
    for _, id in ipairs(selected) do
        if ids[id] == nil or selectedSeen[id] then return p.fail("invalid selected occurrence") end
        selectedSeen[id] = true
    end
    local continuations = {}
    for _, row in ipairs(result) do
        local _, rowContinuationsOrError = doors(row.doors, ids, label .. ".doors")
        if type(rowContinuationsOrError) == "string" then return nil, rowContinuationsOrError end
        continuations[row.id] = rowContinuationsOrError
        for _, additional in ipairs(row.overview.additional or {}) do
            local reference, referenceError = assertRoomReference(
                additional.room,
                ids,
                label .. ".additional.room"
            )
            if not reference then return nil, referenceError end
            continuations[row.id][reference.id] = true
        end
    end
    for index = 1, #selected - 1 do
        if not continuations[selected[index]][selected[index + 1]] then
            return p.fail("selected route is disconnected")
        end
    end
    return result, ids
end

return occurrences
