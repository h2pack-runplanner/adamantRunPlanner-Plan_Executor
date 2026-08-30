-- Strict decoder for the current Run Planner execution-only protocol.
-- This module accepts resolved facts, not project commands or game policy.

local json = require("mods/json")
local protocol = {}

protocol.FORMAT = "run-planner-execution"
protocol.VERSION = 2
protocol.CATALOG_VERSION = "0.51.0-biome-i-encounter-profiles"
protocol.MAX_STRING = 512
protocol.MAX_ROOMS = 256
protocol.MAX_TRACE = 8
protocol.MAX_TARGETS = 16
protocol.MAX_PHASES = 16
protocol.MAX_OBJECTS = 32
protocol.MAX_BAGS = 64

local function fail(message) return nil, message end

local function object(value, label)
    if not json.isObject(value) then return fail(label .. " must be a JSON object") end
    return value
end

local function array(value, label, maximum)
    if not json.isArray(value) then return fail(label .. " must be a JSON array") end
    if #value > maximum then return fail(label .. " exceeds bound") end
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > #value then
            return fail(label .. " contains a non-contiguous index")
        end
    end
    return value
end

local function keys(value, required, optional, label)
    local checked, errorMessage = object(value, label)
    if not checked then return nil, errorMessage end
    for _, key in ipairs(required) do if value[key] == nil then return fail(label .. " is missing " .. key) end end
    for key in pairs(value) do
        local allowed = false
        for _, requiredKey in ipairs(required) do if key == requiredKey then allowed = true end end
        for _, optionalKey in ipairs(optional or {}) do if key == optionalKey then allowed = true end end
        if not allowed then return fail(label .. " has unknown field " .. tostring(key)) end
    end
    return value
end

local function stringValue(value, label, allowEmpty)
    if type(value) ~= "string" or (not allowEmpty and value == "") or #value > protocol.MAX_STRING then
        return fail(label .. " must be a bounded " .. (allowEmpty and "string" or "non-empty string"))
    end
    return value
end

local function integer(value, label, minimum, maximum)
    if type(value) ~= "number" or value ~= math.floor(value) or value < (minimum or 0) or (maximum and value > maximum) then
        return fail(label .. " must be an integer in range")
    end
    return value
end

local function parseCount(value, label)
    local count, errorMessage = keys(value, { "kind" }, { "count", "min", "max" }, label)
    if not count then return nil, errorMessage end
    if count.kind == "exact" then
        local exact, exactError = keys(count, { "kind", "count" }, nil, label)
        if not exact then return nil, exactError end
        local number, numberError = integer(exact.count, label .. ".count")
        if not number then return nil, numberError end
        return { kind = "exact", count = number }
    end
    if count.kind == "range" then
        local range, rangeError = keys(count, { "kind", "min", "max" }, nil, label)
        if not range then return nil, rangeError end
        local minimum, minimumError = integer(range.min, label .. ".min")
        if not minimum then return nil, minimumError end
        local maximum, maximumError = integer(range.max, label .. ".max")
        if not maximum then return nil, maximumError end
        if minimum > maximum then return fail(label .. ".min must not exceed max") end
        return { kind = "range", min = minimum, max = maximum }
    end
    return fail(label .. ".kind unsupported")
end

local function parseReward(value, label)
    local reward, errorMessage = keys(value, { "rewardType", "producerLifecycleKey" }, { "resolvedStoreKey", "source", "spurnedSource" }, label)
    if not reward then return nil, errorMessage end
    local rewardType, rewardError = stringValue(reward.rewardType, label .. ".rewardType")
    if not rewardType then return nil, rewardError end
    local producer, producerError = stringValue(reward.producerLifecycleKey, label .. ".producerLifecycleKey")
    if not producer then return nil, producerError end
    local result = { rewardType = rewardType, producerLifecycleKey = producer }
    for _, field in ipairs({ "resolvedStoreKey", "source", "spurnedSource" }) do
        if reward[field] ~= nil then
            local text, textError = stringValue(reward[field], label .. "." .. field)
            if not text then return nil, textError end
            result[field] = text
        end
    end
    return result
end

local function parseDiagnostic(value, label)
    local diagnostic, errorMessage = keys(value, { "owner", "checkpoint", "counters", "bags" }, nil, label)
    if not diagnostic then return nil, errorMessage end
    if diagnostic.checkpoint ~= "roomEntered" and diagnostic.checkpoint ~= "beforeRoomExit" then return fail(label .. ".checkpoint unsupported") end
    local counters, countersError = keys(diagnostic.counters, { "biomeDepthCache", "biomeEncounterDepth", "routeEncounterDepth", "roomHistoryOrdinal" }, nil, label .. ".counters")
    if not counters then return nil, countersError end
    local result = { owner = nil, checkpoint = diagnostic.checkpoint, counters = {}, bags = {} }
    local owner, ownerError = stringValue(diagnostic.owner, label .. ".owner")
    if not owner then return nil, ownerError end
    result.owner = owner
    for _, field in ipairs({ "biomeDepthCache", "biomeEncounterDepth", "routeEncounterDepth", "roomHistoryOrdinal" }) do
        local number, numberError = integer(counters[field], label .. ".counters." .. field)
        if not number then return nil, numberError end
        result.counters[field] = number
    end
    local bags, bagsError = array(diagnostic.bags, label .. ".bags", protocol.MAX_BAGS)
    if not bags then return nil, bagsError end
    local seen = {}
    for index, valueItem in ipairs(bags) do
        local bag, bagError = keys(valueItem, { "storeKey", "remaining" }, nil, label .. ".bags[" .. index .. "]")
        if not bag then return nil, bagError end
        local storeKey, storeError = stringValue(bag.storeKey, label .. ".bags[" .. index .. "].storeKey")
        if not storeKey then return nil, storeError end
        if seen[storeKey] then return fail(label .. ".bags has duplicate stores") end
        seen[storeKey] = true
        local remaining, remainingError = parseCount(bag.remaining, label .. ".bags[" .. index .. "].remaining")
        if not remaining then return nil, remainingError end
        result.bags[index] = { storeKey = storeKey, remaining = remaining }
    end
    return result
end

local function parseRoom(value, index)
    local label = "rooms[" .. index .. "]"
    local room, errorMessage = keys(value, { "id", "owner", "biomeKey", "gameName", "kind", "entered", "contents", "trace", "outgoing" }, nil, label)
    if not room then return nil, errorMessage end
    local result = {}
    for _, field in ipairs({ "id", "owner", "biomeKey", "gameName", "kind" }) do
        local text, textError = stringValue(room[field], label .. "." .. field)
        if not text then return nil, textError end
        result[field] = text
    end
    if type(room.entered) ~= "boolean" then return fail(label .. ".entered invalid") end
    result.entered = room.entered
    local contents, contentsError = keys(room.contents, { "encounterPhases", "requiredObjects" }, { "incomingReward" }, label .. ".contents")
    if not contents then return nil, contentsError end
    result.contents = { encounterPhases = {}, requiredObjects = {} }
    if contents.incomingReward ~= nil then
        local reward, rewardError = parseReward(contents.incomingReward, label .. ".contents.incomingReward")
        if not reward then return nil, rewardError end
        result.contents.incomingReward = reward
    end
    local phases, phasesError = array(contents.encounterPhases, label .. ".contents.encounterPhases", protocol.MAX_PHASES)
    if not phases then return nil, phasesError end
    for phaseIndex, valuePhase in ipairs(phases) do
        local phase, phaseError = keys(valuePhase, { "slotKey", "encounterKey", "kind" }, nil, label .. ".contents.encounterPhases[" .. phaseIndex .. "]")
        if not phase then return nil, phaseError end
        local slot, slotError = stringValue(phase.slotKey, label .. ".contents.encounterPhases[" .. phaseIndex .. "].slotKey")
        if not slot then return nil, slotError end
        local encounter, encounterError = stringValue(phase.encounterKey, label .. ".contents.encounterPhases[" .. phaseIndex .. "].encounterKey")
        if not encounter then return nil, encounterError end
        local kind, kindError = stringValue(phase.kind, label .. ".contents.encounterPhases[" .. phaseIndex .. "].kind")
        if not kind then return nil, kindError end
        result.contents.encounterPhases[phaseIndex] = { slotKey = slot, encounterKey = encounter, kind = kind }
    end
    local objects, objectsError = array(contents.requiredObjects, label .. ".contents.requiredObjects", protocol.MAX_OBJECTS)
    if not objects then return nil, objectsError end
    for objectIndex, valueObject in ipairs(objects) do
        local objectKey, objectError = stringValue(valueObject, label .. ".contents.requiredObjects[" .. objectIndex .. "]")
        if not objectKey then return nil, objectError end
        result.contents.requiredObjects[objectIndex] = objectKey
    end
    local trace, traceError = array(room.trace, label .. ".trace", protocol.MAX_TRACE)
    if not trace then return nil, traceError end
    if room.entered and #trace == 0 then return fail(label .. ".trace cannot be empty for entered room") end
    if room.entered and (#trace ~= 2 or trace[1].checkpoint ~= "roomEntered" or trace[2].checkpoint ~= "beforeRoomExit") then
        return fail(label .. ".trace must contain owned room-entry and before-room-exit steps")
    end
    if not room.entered and #trace ~= 0 then return fail(label .. ".trace cannot exist for an unentered room") end
    result.trace = {}
    for traceIndex, valueStep in ipairs(trace) do
        local step, stepError = keys(valueStep, { "id", "kind", "checkpoint", "owner", "runState" }, nil, label .. ".trace[" .. traceIndex .. "]")
        if not step then return nil, stepError end
        if step.kind ~= "roomEntered" and step.kind ~= "beforeRoomExit" then return fail(label .. ".trace kind unsupported") end
        if step.checkpoint ~= step.kind then return fail(label .. ".trace checkpoint mismatch") end
        local id, idError = stringValue(step.id, label .. ".trace[" .. traceIndex .. "].id")
        local owner, ownerError = stringValue(step.owner, label .. ".trace[" .. traceIndex .. "].owner")
        if not id then return nil, idError end
        if not owner then return nil, ownerError end
        if owner ~= result.owner then return fail(label .. ".trace owner mismatch") end
        local parsed = { id = id, kind = step.kind, checkpoint = step.checkpoint, owner = owner }
        local state, stateError = parseDiagnostic(step.runState, label .. ".trace[" .. traceIndex .. "].runState")
        if not state then return nil, stateError end
        if state.checkpoint ~= step.checkpoint then return fail(label .. ".trace runState checkpoint mismatch") end
        parsed.runState = state
        result.trace[traceIndex] = parsed
    end
    local outgoing, outgoingError = keys(room.outgoing, { "owner", "kind" }, { "targets", "selectedExitKey", "target", "resolvedSharedRewardStoreKey" }, label .. ".outgoing")
    if not outgoing then return nil, outgoingError end
    local outgoingOwner, outgoingOwnerError = stringValue(outgoing.owner, label .. ".outgoing.owner")
    if not outgoingOwner then return nil, outgoingOwnerError end
    if outgoing.kind == "batch" then
        local checked, checkedError = keys(outgoing, { "owner", "kind", "targets", "selectedExitKey" }, { "resolvedSharedRewardStoreKey" }, label .. ".outgoing")
        if not checked then return nil, checkedError end
        local targets, targetsError = array(outgoing.targets, label .. ".outgoing.targets", protocol.MAX_TARGETS)
        if not targets then return nil, targetsError end
        if #targets == 0 then return fail(label .. ".outgoing.targets cannot be empty") end
        local selectedExit, selectedError = stringValue(outgoing.selectedExitKey, label .. ".outgoing.selectedExitKey")
        if not selectedExit then return nil, selectedError end
        result.outgoing = { owner = outgoingOwner, kind = "batch", targets = {}, selectedExitKey = selectedExit }
        if outgoing.resolvedSharedRewardStoreKey ~= nil then
            local store, storeError = stringValue(outgoing.resolvedSharedRewardStoreKey, label .. ".outgoing.resolvedSharedRewardStoreKey")
            if not store then return nil, storeError end
            result.outgoing.resolvedSharedRewardStoreKey = store
        end
        local exits, indices, picked = {}, {}, 0
        for targetIndex, valueTarget in ipairs(targets) do
            local target, targetError = keys(valueTarget, { "exitKey", "index", "type", "room", "picked" }, nil, label .. ".outgoing.targets[" .. targetIndex .. "]")
            if not target then return nil, targetError end
            local exitKey, exitError = stringValue(target.exitKey, label .. ".outgoing.targets[" .. targetIndex .. "].exitKey")
            if not exitKey then return nil, exitError end
            local exitIndex, exitIndexError = integer(target.index, label .. ".outgoing.targets[" .. targetIndex .. "].index", 1, protocol.MAX_TARGETS)
            if not exitIndex then return nil, exitIndexError end
            if exitIndex ~= targetIndex then return fail(label .. ".outgoing.targets must preserve physical order") end
            local exitType, exitTypeError = stringValue(target.type, label .. ".outgoing.targets[" .. targetIndex .. "].type")
            if not exitType then return nil, exitTypeError end
            if type(target.picked) ~= "boolean" then return fail(label .. ".outgoing.targets picked invalid") end
            if exits[exitKey] or indices[exitIndex] then return fail(label .. ".outgoing.targets duplicate identity") end
            exits[exitKey], indices[exitIndex] = true, true
            if target.picked then picked = picked + 1 end
            local targetRoom, targetRoomError = keys(target.room, { "id", "biomeKey", "gameName" }, nil, label .. ".outgoing.targets[" .. targetIndex .. "].room")
            if not targetRoom then return nil, targetRoomError end
            local targetId, targetIdError = stringValue(targetRoom.id, label .. ".outgoing.targets[" .. targetIndex .. "].room.id")
            local targetBiome, targetBiomeError = stringValue(targetRoom.biomeKey, label .. ".outgoing.targets[" .. targetIndex .. "].room.biomeKey")
            local targetName, targetNameError = stringValue(targetRoom.gameName, label .. ".outgoing.targets[" .. targetIndex .. "].room.gameName")
            if not targetId then return nil, targetIdError end
            if not targetBiome then return nil, targetBiomeError end
            if not targetName then return nil, targetNameError end
            result.outgoing.targets[targetIndex] = { exitKey = exitKey, index = exitIndex, type = exitType, room = { id = targetId, biomeKey = targetBiome, gameName = targetName }, picked = target.picked }
            if target.picked and selectedExit ~= exitKey then return fail(label .. ".outgoing selected target mismatch") end
        end
        if picked ~= 1 then return fail(label .. ".outgoing must select exactly one picked target") end
    elseif outgoing.kind == "fixed" then
        local checked, checkedError = keys(outgoing, { "owner", "kind", "target" }, nil, label .. ".outgoing")
        if not checked then return nil, checkedError end
        local target, targetError = keys(outgoing.target, { "id", "biomeKey", "gameName" }, nil, label .. ".outgoing.target")
        if not target then return nil, targetError end
        result.outgoing = { owner = outgoingOwner, kind = "fixed", target = { id = stringValue(target.id, label .. ".outgoing.target.id"), biomeKey = stringValue(target.biomeKey, label .. ".outgoing.target.biomeKey"), gameName = stringValue(target.gameName, label .. ".outgoing.target.gameName") } }
    elseif outgoing.kind == "terminal" then
        local checked, checkedError = keys(outgoing, { "owner", "kind" }, nil, label .. ".outgoing")
        if not checked then return nil, checkedError end
        result.outgoing = { owner = outgoingOwner, kind = "terminal" }
    else
        return fail(label .. ".outgoing.kind unsupported")
    end
    return result
end

function protocol.decode(value)
    local record, errorMessage = keys(value, { "format", "protocolVersion", "catalogVersion", "projectId", "planFingerprint", "routeKey", "extent", "rooms" }, nil, "execution plan")
    if not record then return nil, errorMessage end
    if record.format ~= protocol.FORMAT then return fail("unsupported execution plan format") end
    if record.protocolVersion ~= protocol.VERSION then return fail("unsupported execution protocol version") end
    if record.catalogVersion ~= protocol.CATALOG_VERSION then return fail("unsupported execution catalog version") end
    if record.routeKey ~= "Underworld" then return fail("unsupported execution route") end
    local projectId, projectError = stringValue(record.projectId, "projectId")
    local fingerprint, fingerprintError = stringValue(record.planFingerprint, "planFingerprint")
    if not projectId then return nil, projectError end
    if not fingerprint then return nil, fingerprintError end
    if not fingerprint:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") then return fail("planFingerprint must be an eight-character lowercase hexadecimal value") end
    local extent, extentError = keys(record.extent, { "kind", "biomeKeys", "terminalBiomeKey" }, nil, "extent")
    if not extent then return nil, extentError end
    if extent.kind ~= "configuredPrefix" then return fail("unsupported execution extent") end
    local biomeKeys, biomeError = array(extent.biomeKeys, "extent.biomeKeys", 2)
    if not biomeKeys then return nil, biomeError end
    if not ((#biomeKeys == 1 and biomeKeys[1] == "F") or (#biomeKeys == 2 and biomeKeys[1] == "F" and biomeKeys[2] == "G")) then return fail("unsupported execution biome prefix") end
    if extent.terminalBiomeKey ~= biomeKeys[#biomeKeys] then return fail("extent terminal biome mismatch") end
    local rooms, roomsError = array(record.rooms, "rooms", protocol.MAX_ROOMS)
    if not rooms then return nil, roomsError end
    if #rooms == 0 then return fail("execution plan requires rooms") end
    local resultRooms, ids = {}, {}
    for index, valueRoom in ipairs(rooms) do
        local room, roomError = parseRoom(valueRoom, index)
        if not room then return nil, roomError end
        if ids[room.id] then return fail("execution plan has duplicate room ids") end
        ids[room.id] = true
        if room.biomeKey ~= "F" and room.biomeKey ~= "G" then return fail("room has unsupported biome") end
        resultRooms[index] = room
    end
    if not resultRooms[1].entered or resultRooms[1].biomeKey ~= "F" then return fail("execution plan must start with entered F room") end
    local roomsById = {}
    for _, room in ipairs(resultRooms) do roomsById[room.id] = room end
    for _, room in ipairs(resultRooms) do
        if room.outgoing.kind == "batch" then
            for _, target in ipairs(room.outgoing.targets) do
                local referenced = roomsById[target.room.id]
                if not referenced then return fail("outgoing target references unknown room") end
                if referenced.biomeKey ~= target.room.biomeKey or referenced.gameName ~= target.room.gameName then
                    return fail("outgoing target room identity mismatch")
                end
            end
        elseif room.outgoing.kind == "fixed" then
            local referenced = roomsById[room.outgoing.target.id]
            if not referenced then return fail("fixed target references unknown room") end
            if referenced.biomeKey ~= room.outgoing.target.biomeKey or referenced.gameName ~= room.outgoing.target.gameName then
                return fail("fixed target room identity mismatch")
            end
        end
    end
    return { kind = "ready", format = protocol.FORMAT, protocolVersion = protocol.VERSION, catalogVersion = record.catalogVersion, projectId = projectId, planFingerprint = fingerprint, routeKey = "Underworld", extent = { kind = "configuredPrefix", biomeKeys = biomeKeys, terminalBiomeKey = extent.terminalBiomeKey }, rooms = resultRooms }
end

return protocol
