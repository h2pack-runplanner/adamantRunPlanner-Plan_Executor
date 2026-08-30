-- Decoder for the current Run Planner execution-only protocol. This is a
-- closed wire contract: no project schema, callbacks, Lua code, or fallback
-- route is accepted here.

local json = require("mods/json")
local protocol = {}

protocol.FORMAT = "run-planner-execution"
protocol.VERSION = 1
protocol.CATALOG_VERSION = "0.51.0-biome-i-encounter-profiles"
protocol.MAX_STRING = 512
protocol.MAX_ROOMS = 1
protocol.MAX_TRACE = 64
protocol.MAX_TARGETS = 16

local function fail(message)
    return nil, message
end

local function object(value, label)
    if not json.isObject(value) then return fail(label .. " must be a JSON object") end
    return value
end

local function array(value, label, maximum)
    if not json.isArray(value) then return fail(label .. " must be a JSON array") end
    local count = #value
    if count > maximum then return fail(label .. " exceeds bound") end
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > count then
            return fail(label .. " contains a non-contiguous index")
        end
    end
    return value
end

local function keys(value, required, optional, label)
    local checked, errorMessage = object(value, label)
    if not checked then return nil, errorMessage end
    for _, key in ipairs(required) do
        if value[key] == nil then return fail(label .. " is missing " .. key) end
    end
    for key in pairs(value) do
        local allowed = false
        for _, requiredKey in ipairs(required) do if key == requiredKey then allowed = true end end
        for _, optionalKey in ipairs(optional or {}) do if key == optionalKey then allowed = true end end
        if not allowed then return fail(label .. " has unknown field " .. tostring(key)) end
    end
    return value
end

local function stringValue(value, label)
    if type(value) ~= "string" or value == "" or #value > protocol.MAX_STRING then
        return fail(label .. " must be a bounded non-empty string")
    end
    return value
end

local function parseReward(value)
    local reward, errorMessage = keys(
        value, { "rewardType", "producerLifecycleKey" },
        { "resolvedStoreKey", "source" }, "incomingReward")
    if not reward then return nil, errorMessage end
    local rewardType, rewardError = stringValue(reward.rewardType, "incomingReward.rewardType")
    if not rewardType then return nil, rewardError end
    local producer, producerError = stringValue(reward.producerLifecycleKey, "incomingReward.producerLifecycleKey")
    if not producer then return nil, producerError end
    local result = { rewardType = rewardType, producerLifecycleKey = producer }
    for _, field in ipairs({ "resolvedStoreKey", "source" }) do
        if reward[field] ~= nil then
            local valueText, valueError = stringValue(reward[field], "incomingReward." .. field)
            if not valueText then return nil, valueError end
            result[field] = valueText
        end
    end
    return result
end

local function parseRoom(value, index)
    local label = "rooms[" .. index .. "]"
    local room, errorMessage = keys(
        value, { "id", "owner", "biomeKey", "gameName", "contents", "trace", "outgoing" },
        nil, label)
    if not room then return nil, errorMessage end
    local result = {}
    for _, field in ipairs({ "id", "owner", "biomeKey", "gameName" }) do
        local valueText, valueError = stringValue(room[field], label .. "." .. field)
        if not valueText then return nil, valueError end
        result[field] = valueText
    end
    local contents, contentsError = keys(room.contents, { "incomingReward" }, nil, label .. ".contents")
    if not contents then return nil, contentsError end
    local reward, rewardError = parseReward(contents.incomingReward)
    if not reward then return nil, rewardError end
    result.contents = { incomingReward = reward }

    local trace, traceError = array(room.trace, label .. ".trace", protocol.MAX_TRACE)
    if not trace then return nil, traceError end
    if #trace ~= 1 then return fail(label .. ".trace must contain its owned room-entry step") end
    result.trace = {}
    for traceIndex, entry in ipairs(trace) do
        local step, stepError = keys(
            entry, { "id", "kind", "checkpoint", "owner" }, nil,
            label .. ".trace[" .. traceIndex .. "]")
        if not step then return nil, stepError end
        if step.kind ~= "roomEntered" or step.checkpoint ~= "roomEntered" then
            return fail(label .. ".trace[" .. traceIndex .. "] kind unsupported")
        end
        local id, idError = stringValue(step.id, label .. ".trace[" .. traceIndex .. "].id")
        local owner, ownerError = stringValue(step.owner, label .. ".trace[" .. traceIndex .. "].owner")
        if not id then return nil, idError end
        if not owner then return nil, ownerError end
        if owner ~= result.owner then
            return fail(label .. ".trace must contain its owned room-entry step")
        end
        result.trace[#result.trace + 1] = { id = id, kind = "roomEntered", checkpoint = "roomEntered", owner = owner }
    end

    local outgoing, outgoingError = keys(
        room.outgoing, { "owner", "targets", "selectedExitKey" }, nil,
        label .. ".outgoing")
    if not outgoing then return nil, outgoingError end
    local outgoingOwner, ownerError = stringValue(outgoing.owner, label .. ".outgoing.owner")
    if not outgoingOwner then return nil, ownerError end
    local targets, targetsError = array(outgoing.targets, label .. ".outgoing.targets", protocol.MAX_TARGETS)
    if not targets then return nil, targetsError end
    if type(outgoing.selectedExitKey) ~= "string" then
        return fail(label .. ".outgoing.selectedExitKey invalid")
    end
    result.outgoing = { owner = outgoingOwner, targets = {}, selectedExitKey = outgoing.selectedExitKey }
    local seenExit, seenIndex = {}, {}
    local pickedCount, pickedExitKey = 0, nil
    for targetIndex, targetValue in ipairs(targets) do
        local targetLabel = label .. ".outgoing.targets[" .. targetIndex .. "]"
        local target, targetError = keys(
            targetValue, { "exitKey", "index", "type", "room", "picked" }, nil, targetLabel)
        if not target then return nil, targetError end
        local exitKey, exitError = stringValue(target.exitKey, targetLabel .. ".exitKey")
        local targetType, typeError = stringValue(target.type, targetLabel .. ".type")
        if not exitKey then return nil, exitError end
        if not targetType then return nil, typeError end
        if type(target.index) ~= "number"
            or target.index ~= math.floor(target.index)
            or target.index < 1
            or target.index > protocol.MAX_TARGETS
        then
            return fail(targetLabel .. ".index invalid")
        end
        if type(target.picked) ~= "boolean" then return fail(targetLabel .. ".picked invalid") end
        if seenExit[exitKey] or seenIndex[target.index] then
            return fail(targetLabel .. " duplicates target identity")
        end
        seenExit[exitKey], seenIndex[target.index] = true, true
        if target.picked then
            pickedCount = pickedCount + 1
            pickedExitKey = exitKey
        end
        local targetRoom, targetRoomError = keys(
            target.room, { "id", "biomeKey", "gameName" }, nil, targetLabel .. ".room")
        if not targetRoom then return nil, targetRoomError end
        local targetId, targetIdError = stringValue(targetRoom.id, targetLabel .. ".room.id")
        local targetBiome, targetBiomeError = stringValue(
            targetRoom.biomeKey, targetLabel .. ".room.biomeKey")
        local targetGameName, targetGameError = stringValue(targetRoom.gameName, targetLabel .. ".room.gameName")
        if not targetId then return nil, targetIdError end
        if not targetBiome then return nil, targetBiomeError end
        if not targetGameName then return nil, targetGameError end
        result.outgoing.targets[#result.outgoing.targets + 1] = {
            exitKey = exitKey,
            index = target.index,
            type = targetType,
            room = { id = targetId, biomeKey = targetBiome, gameName = targetGameName },
            picked = target.picked,
        }
    end
    if pickedCount ~= 1 or pickedExitKey ~= outgoing.selectedExitKey then
        return fail(label .. ".outgoing must select exactly one picked target")
    end
    return result
end

function protocol.decode(value)
    local record, errorMessage = keys(
        value,
        {
            "format", "protocolVersion", "catalogVersion", "projectId", "planFingerprint",
            "routeKey", "extent", "rooms",
        },
        nil, "execution plan")
    if not record then return nil, errorMessage end
    if record.format ~= protocol.FORMAT then return fail("unsupported execution plan format") end
    if record.protocolVersion ~= protocol.VERSION then return fail("unsupported execution protocol version") end
    if record.catalogVersion ~= protocol.CATALOG_VERSION then return fail("unsupported execution catalog version") end
    if record.routeKey ~= "Underworld" then return fail("unsupported execution route") end
    local catalogVersion, catalogError = stringValue(record.catalogVersion, "catalogVersion")
    local projectId, projectError = stringValue(record.projectId, "projectId")
    local planFingerprint, fingerprintError = stringValue(record.planFingerprint, "planFingerprint")
    if not catalogVersion then return nil, catalogError end
    if not projectId then return nil, projectError end
    if not planFingerprint then return nil, fingerprintError end
    if not planFingerprint:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") then
        return fail("planFingerprint must be an eight-character lowercase hexadecimal value")
    end
    local extent, extentError = keys(record.extent, { "kind", "biomeKeys", "terminalBiomeKey" }, nil, "extent")
    if not extent then return nil, extentError end
    if extent.kind ~= "configuredPrefix" or extent.terminalBiomeKey ~= "F" then
        return fail("unsupported execution extent")
    end
    local biomeKeys, biomeError = array(extent.biomeKeys, "extent.biomeKeys", 1)
    if not biomeKeys then return nil, biomeError end
    if #biomeKeys ~= 1 or biomeKeys[1] ~= "F" then return fail("unsupported execution biome prefix") end
    local rooms, roomsError = array(record.rooms, "rooms", protocol.MAX_ROOMS)
    if not rooms then return nil, roomsError end
    if #rooms ~= 1 then return fail("Gate A requires one opening room") end
    local room, roomError = parseRoom(rooms[1], 1)
    if not room then return nil, roomError end
    return {
        kind = "ready",
        format = protocol.FORMAT,
        protocolVersion = protocol.VERSION,
        catalogVersion = catalogVersion,
        projectId = projectId,
        planFingerprint = planFingerprint,
        routeKey = "Underworld",
        extent = { kind = "configuredPrefix", biomeKeys = { "F" }, terminalBiomeKey = "F" },
        rooms = { room },
    }
end

return protocol
