-- Strict, data-only decoder for the Run Planner bundle/execution protocol.
-- The project section is checked only at the envelope boundary. Every
-- execution-owned product is validated against the closed TypeScript model;
-- this module never interprets project semantics or game rules.

local protocol = {}

protocol.FILE_FORMAT = "run-planner-bundle"
protocol.FILE_VERSION = 1
protocol.EXECUTION_PROTOCOL_VERSION = 1
protocol.MAX_ROUTES = 2
protocol.MAX_BIOMES = 8
protocol.MAX_INSTRUCTIONS = 512
protocol.MAX_TARGETS = 64
protocol.MAX_ADDITIONAL = 16
protocol.MAX_VISITS = 16
protocol.MAX_COLLECTION = 128
protocol.MAX_STRING = 512

local ROUTES = { Underworld = true, Surface = true }
local INSTRUCTION_KINDS = {
    authored = true,
    completion = true,
    batch = true,
    localChild = true,
    hubRoom = true,
    hub = true,
}
local ENCOUNTER_KINDS = { boss = true, combat = true, miniboss = true, nonCombat = true, story = true }
local ADDITIONAL_KINDS = { naturalChaos = true, zagreusContract = true }
local BATCH_STATE_KINDS = { standard = true, clockwork = true, fields = true }
local PRODUCER_KINDS = { countedChoice = true, fixed = true, freeReward = true, shop = true }
local ROOM_ROLES = { boss = true, postboss = true }
local ROOM_GENERATIONS = { generated = true, notGenerated = true }
local TARGET_CONTINUATIONS = { continuesSpine = true, deadLeaf = true, startsCompletion = true }
local EXIT_BEHAVIORS = { playerSelected = true, automaticHostContinuation = true }

local function fail(message)
    error(message, 0)
end

local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function isNull(value)
    local meta = type(value) == "table" and getmetatable(value) or nil
    return meta and meta.__json_null == true or false
end

local function isJsonObject(value)
    local meta = type(value) == "table" and getmetatable(value) or nil
    return meta and meta.__json_object == true or false
end

local function isJsonArray(value)
    local meta = type(value) == "table" and getmetatable(value) or nil
    return meta and meta.__json_array == true or false
end

local function object(value, label)
    if not isJsonObject(value) then
        fail(label .. " must be a JSON object")
    end
    for key in pairs(value) do
        if type(key) ~= "string" then
            fail(label .. " contains a non-string key")
        end
    end
end

local function isArray(value, maximum, label)
    if not isJsonArray(value) then
        fail(label .. " must be a JSON array")
    end
    local count = #value
    if count > maximum then
        fail(label .. " exceeds bound")
    end
    for key in pairs(value) do
        if type(key) ~= "number" or not isInteger(key) or key < 1 or key > count then
            fail(label .. " contains a non-contiguous index")
        end
    end
    return count
end

local function keys(value, required, optional, label)
    object(value, label)
    for key in pairs(required) do
        if value[key] == nil then
            fail(label .. " is missing " .. key)
        end
    end
    for key in pairs(value) do
        if not required[key] and not (optional and optional[key]) then
            fail(label .. " has unknown field " .. key)
        end
    end
end

local function stringValue(value, label, optional)
    if optional and (value == nil or isNull(value)) then
        return
    end
    if type(value) ~= "string" or value == "" or #value > protocol.MAX_STRING then
        fail(label .. " must be a bounded non-empty string")
    end
    return value
end

local function booleanValue(value, label)
    if type(value) ~= "boolean" then
        fail(label .. " must be boolean")
    end
end

local function positiveInteger(value, label)
    if not isInteger(value) or value < 1 then
        fail(label .. " must be positive integer")
    end
end

local function fingerprint(value, label)
    stringValue(value, label)
    if not value:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
        fail(label .. " must be a 16-digit hexadecimal fingerprint")
    end
end

local function reference(value, ids, label)
    stringValue(value, label)
    if not ids[value] then
        fail(label .. " references missing instruction " .. value)
    end
end

local function referenceObject(value, ids, label)
    keys(value, { instructionId = true }, nil, label)
    reference(value.instructionId, ids, label .. ".instructionId")
end

local function validateExitSource(value, label)
    object(value, label)
    if value.kind == "occurrence" then
        keys(value, { kind = true, occurrenceId = true }, nil, label)
        stringValue(value.occurrenceId, label .. ".occurrenceId")
    elseif value.kind == "hubDecision" then
        keys(value, { kind = true, decisionKey = true }, nil, label)
        stringValue(value.decisionKey, label .. ".decisionKey")
    else
        fail(label .. " has unknown kind " .. tostring(value.kind))
    end
end

local function validateOrigin(value, routeKey, label, expectedKind)
    object(value, label)
    stringValue(value.kind, label .. ".kind")
    stringValue(value.routeKey, label .. ".routeKey")
    stringValue(value.biomeKey, label .. ".biomeKey")
    if value.routeKey ~= routeKey then
        fail(label .. ".routeKey does not match route")
    end
    if expectedKind and value.kind ~= expectedKind then
        fail(label .. ".kind does not match instruction")
    end
    if value.kind == "occurrence" then
        keys(value, { kind = true, routeKey = true, biomeKey = true, occurrenceId = true }, nil, label)
        stringValue(value.occurrenceId, label .. ".occurrenceId")
    elseif value.kind == "localChild" then
        keys(value, {
            kind = true, routeKey = true, biomeKey = true, occurrenceId = true,
            groupKey = true, slotKey = true,
        }, nil, label)
        stringValue(value.occurrenceId, label .. ".occurrenceId")
        stringValue(value.groupKey, label .. ".groupKey")
        stringValue(value.slotKey, label .. ".slotKey")
    elseif value.kind == "hubRoom" then
        keys(value, { kind = true, routeKey = true, biomeKey = true, hubKey = true }, nil, label)
        stringValue(value.hubKey, label .. ".hubKey")
    elseif value.kind == "completionRoom" then
        keys(value, { kind = true, routeKey = true, biomeKey = true, role = true }, nil, label)
        if not ROOM_ROLES[value.role] then fail(label .. ".role has unknown value") end
    elseif value.kind == "exitDecision" then
        keys(value, { kind = true, routeKey = true, biomeKey = true, source = true }, nil, label)
        validateExitSource(value.source, label .. ".source")
    elseif value.kind == "hubDecision" then
        keys(value, { kind = true, routeKey = true, biomeKey = true, hubKey = true }, nil, label)
        stringValue(value.hubKey, label .. ".hubKey")
    else
        fail(label .. " has unknown kind " .. tostring(value.kind))
    end
end

local function validateRewardOffer(value, label)
    keys(value, { rewardType = true }, { payload = true }, label)
    stringValue(value.rewardType, label .. ".rewardType")
    if value.payload ~= nil then
        if isNull(value.payload) then fail(label .. ".payload must not be null") end
        object(value.payload, label .. ".payload")
        if value.payload.kind == "BoonSource" then
            keys(value.payload, { kind = true, source = true }, nil, label .. ".payload")
            stringValue(value.payload.source, label .. ".payload.source")
        elseif value.payload.kind == "DevotionPair" then
            keys(value.payload, { kind = true, chosenSource = true, spurnedSource = true }, nil,
                label .. ".payload")
            stringValue(value.payload.chosenSource, label .. ".payload.chosenSource")
            stringValue(value.payload.spurnedSource, label .. ".payload.spurnedSource")
        else
            fail(label .. ".payload has unknown kind " .. tostring(value.payload.kind))
        end
    end
end

local function validateReward(value, label)
    if value == nil then return end
    if isNull(value) then fail(label .. " must be an object") end
    keys(value, { offer = true, producerKind = true }, { resolvedStoreKey = true, acquisitionEnabled = true }, label)
    if not PRODUCER_KINDS[value.producerKind] then
        fail(label .. ".producerKind has unknown value")
    end
    if value.resolvedStoreKey ~= nil then stringValue(value.resolvedStoreKey, label .. ".resolvedStoreKey") end
    if value.acquisitionEnabled ~= nil then booleanValue(value.acquisitionEnabled, label .. ".acquisitionEnabled") end
    object(value.offer, label .. ".offer")
    validateRewardOffer(value.offer, label .. ".offer")
end

local function validateRequiredObjects(value, label)
    local count = isArray(value, protocol.MAX_COLLECTION, label)
    for index = 1, count do
        local descriptor = value[index]
        keys(descriptor, { key = true, spawnTiming = true, completionRequirement = true }, nil,
            label .. "[" .. index .. "]")
        if descriptor.key ~= "SoulPylon" then fail(label .. "[" .. index .. "].key has unknown value") end
        if descriptor.spawnTiming ~= "roomEntry" then
            fail(label .. "[" .. index .. "].spawnTiming has unknown value")
        end
        if descriptor.completionRequirement ~= "destroyBeforeExit" then
            fail(label .. "[" .. index .. "].completionRequirement has unknown value")
        end
    end
end

local function validateEncounterPhases(value, label)
    local count = isArray(value, 16, label)
    for index = 1, count do
        local phase = value[index]
        keys(phase, { encounterKey = true, kind = true, slotKey = true }, { rewardAttachment = true },
            label .. "[" .. index .. "]")
        stringValue(phase.encounterKey, label .. "[" .. index .. "].encounterKey")
        stringValue(phase.slotKey, label .. "[" .. index .. "].slotKey")
        if not ENCOUNTER_KINDS[phase.kind] then
            fail(label .. "[" .. index .. "].kind has unknown value")
        end
        if phase.rewardAttachment ~= nil then
            object(phase.rewardAttachment, label .. "[" .. index .. "].rewardAttachment")
            if phase.rewardAttachment.kind == "localReward" then
                keys(phase.rewardAttachment, { groupKey = true, kind = true, slotKey = true }, nil,
                    label .. "[" .. index .. "].rewardAttachment")
                stringValue(phase.rewardAttachment.groupKey, label .. ".rewardAttachment.groupKey")
                stringValue(phase.rewardAttachment.slotKey, label .. ".rewardAttachment.slotKey")
            elseif phase.rewardAttachment.kind == "rewardWheel" then
                keys(phase.rewardAttachment, { key = true, kind = true, offerKeys = true }, nil,
                    label .. "[" .. index .. "].rewardAttachment")
                stringValue(phase.rewardAttachment.key, label .. ".rewardAttachment.key")
                local offerCount = isArray(phase.rewardAttachment.offerKeys, protocol.MAX_COLLECTION,
                    label .. ".rewardAttachment.offerKeys")
                for offerIndex = 1, offerCount do
                    stringValue(phase.rewardAttachment.offerKeys[offerIndex], label .. ".rewardAttachment.offerKeys[]")
                end
            else
                fail(label .. ".rewardAttachment has unknown kind")
            end
        end
    end
end

local function validateShop(value, label)
    keys(value, { kind = true, profileKey = true, offers = true, purchaseOrder = true }, nil, label)
    if value.kind ~= "shop" then fail(label .. ".kind has unknown value") end
    stringValue(value.profileKey, label .. ".profileKey")
    local offerCount = isArray(value.offers, protocol.MAX_COLLECTION, label .. ".offers")
    if offerCount == 0 then fail(label .. ".offers cannot be empty") end
    local offerKeys = {}
    for index = 1, offerCount do
        local item = value.offers[index]
        keys(item, { offer = true, offerKey = true }, nil, label .. ".offers[" .. index .. "]")
        stringValue(item.offerKey, label .. ".offers[].offerKey")
        if offerKeys[item.offerKey] then fail(label .. " has duplicate offerKey") end
        offerKeys[item.offerKey] = true
        object(item.offer, label .. ".offers[].offer")
        validateRewardOffer(item.offer, label .. ".offers[].offer")
    end
    local purchaseCount = isArray(value.purchaseOrder, protocol.MAX_COLLECTION, label .. ".purchaseOrder")
    for index = 1, purchaseCount do
        local key = value.purchaseOrder[index]
        stringValue(key, label .. ".purchaseOrder[]")
        if not offerKeys[key] then fail(label .. ".purchaseOrder references missing offer " .. key) end
    end
end

local function validateLocalRewards(value, label)
    local count = isArray(value, protocol.MAX_COLLECTION, label)
    for index = 1, count do
        local reward = value[index]
        keys(reward,
            { groupKey = true, slotKey = true, encounterPhaseKey = true, offer = true, resolvedStoreKey = true }, nil,
            label .. "[" .. index .. "]")
        stringValue(reward.groupKey, label .. "[].groupKey")
        stringValue(reward.slotKey, label .. "[].slotKey")
        stringValue(reward.encounterPhaseKey, label .. "[].encounterPhaseKey")
        stringValue(reward.resolvedStoreKey, label .. "[].resolvedStoreKey")
        object(reward.offer, label .. "[].offer")
        validateRewardOffer(reward.offer, label .. "[].offer")
    end
end

local function validateRewardWheels(value, label)
    local count = isArray(value, protocol.MAX_COLLECTION, label)
    for index = 1, count do
        local wheel = value[index]
        keys(wheel,
            { wheelKey = true, encounterPhaseKey = true, storeKey = true, offers = true, pickedOfferIndex = true }, nil,
            label .. "[" .. index .. "]")
        stringValue(wheel.wheelKey, label .. "[].wheelKey")
        stringValue(wheel.encounterPhaseKey, label .. "[].encounterPhaseKey")
        stringValue(wheel.storeKey, label .. "[].storeKey")
        local offerCount = isArray(wheel.offers, protocol.MAX_COLLECTION, label .. "[].offers")
        if offerCount == 0 then fail(label .. "[].offers cannot be empty") end
        positiveInteger(wheel.pickedOfferIndex, label .. "[].pickedOfferIndex")
        if wheel.pickedOfferIndex > offerCount then fail(label .. "[].pickedOfferIndex is out of range") end
        local offerKeys = {}
        local pickedCount = 0
        for offerIndex = 1, offerCount do
            local offer = wheel.offers[offerIndex]
            keys(offer, { offerKey = true, offer = true, picked = true }, nil,
                label .. "[].offers[]")
            stringValue(offer.offerKey, label .. "[].offers[].offerKey")
            if offerKeys[offer.offerKey] then fail(label .. " has duplicate offerKey") end
            offerKeys[offer.offerKey] = true
            booleanValue(offer.picked, label .. "[].offers[].picked")
            if offer.picked then pickedCount = pickedCount + 1 end
            object(offer.offer, label .. "[].offers[].offer")
            validateRewardOffer(offer.offer, label .. "[].offers[].offer")
        end
        if pickedCount ~= 1 or not wheel.offers[wheel.pickedOfferIndex].picked then
            fail(label .. "[].pickedOfferIndex does not identify the picked offer")
        end
    end
end

local function validateRoom(instruction, routeKey, label)
    local optional = { requiredObjects = true, incomingReward = true }
    local required = { id = true, kind = true, origin = true, gameName = true, encounterPhases = true, entered = true }
    if instruction.kind == "authored" then
        optional.anomalyReplacement = true; optional.clockworkReward = true
        optional.localRewards = true; optional.rewardWheels = true; optional.shop = true
    elseif instruction.kind == "completion" then
        required.role = true; optional.enteredRewardStoreKey = true
    elseif instruction.kind == "localChild" then
        required.groupKey = true; required.slotKey = true; required.physicalDoorId = true
        required.generation = true; required.enteredOrdinal = true
    end
    keys(instruction, required, optional, label)
    stringValue(instruction.id, label .. ".id")
    stringValue(instruction.gameName, label .. ".gameName")
    booleanValue(instruction.entered, label .. ".entered")
    local expected = instruction.kind == "authored" and "occurrence"
        or instruction.kind == "completion" and "completionRoom"
        or instruction.kind == "localChild" and "localChild"
        or "hubRoom"
    validateOrigin(instruction.origin, routeKey, label .. ".origin", expected)
    validateEncounterPhases(instruction.encounterPhases, label .. ".encounterPhases")
    if instruction.requiredObjects ~= nil then
        validateRequiredObjects(instruction.requiredObjects, label .. ".requiredObjects")
    end
    validateReward(instruction.incomingReward, label .. ".incomingReward")
    if instruction.kind == "authored" then
        if instruction.anomalyReplacement ~= nil then
            keys(instruction.anomalyReplacement, { replacedRoomGameName = true }, nil,
                label .. ".anomalyReplacement")
            stringValue(instruction.anomalyReplacement.replacedRoomGameName,
                label .. ".anomalyReplacement.replacedRoomGameName")
        end
        if instruction.clockworkReward ~= nil and instruction.clockworkReward ~= "goal"
            and instruction.clockworkReward ~= "nonGoal" then
            fail(label .. ".clockworkReward has unknown value")
        end
        if instruction.localRewards ~= nil then
            validateLocalRewards(instruction.localRewards, label .. ".localRewards")
        end
        if instruction.rewardWheels ~= nil then
            validateRewardWheels(instruction.rewardWheels, label .. ".rewardWheels")
        end
        if instruction.shop ~= nil then
            object(instruction.shop, label .. ".shop")
            validateShop(instruction.shop, label .. ".shop")
        end
    elseif instruction.kind == "completion" then
        if not ROOM_ROLES[instruction.role] then fail(label .. ".role has unknown value") end
        if instruction.enteredRewardStoreKey ~= nil then
            stringValue(instruction.enteredRewardStoreKey, label .. ".enteredRewardStoreKey")
        end
    elseif instruction.kind == "localChild" then
        stringValue(instruction.groupKey, label .. ".groupKey")
        stringValue(instruction.slotKey, label .. ".slotKey")
        positiveInteger(instruction.physicalDoorId, label .. ".physicalDoorId")
        if not ROOM_GENERATIONS[instruction.generation] then fail(label .. ".generation has unknown value") end
        if not isNull(instruction.enteredOrdinal) then
            positiveInteger(instruction.enteredOrdinal, label .. ".enteredOrdinal")
        end
    end
end

local function validatePhysicalExit(value, label)
    keys(value, { kind = true, exitKey = true, index = true, type = true, behavior = true }, nil, label)
    if value.kind ~= "available" then fail(label .. ".kind has unknown value") end
    stringValue(value.exitKey, label .. ".exitKey")
    stringValue(value.type, label .. ".type")
    positiveInteger(value.index, label .. ".index")
    if not EXIT_BEHAVIORS[value.behavior] then fail(label .. ".behavior has unknown value") end
end

local function validateContinuationClosure(selected, targets, additional, ids, label)
    reference(selected.instructionId, ids, label .. ".instructionId")
    if selected.kind == "normal" then
        local matches = 0
        for index = 1, #targets do
            if targets[index].exit.exitKey == selected.exitKey
                and targets[index].room.instructionId == selected.instructionId then
                matches = matches + 1
            end
        end
        if matches ~= 1 then fail(label .. " does not match exactly one target") end
    else
        local matches = 0
        for index = 1, #additional do
            if additional[index].key == selected.additionalExitKey
                and additional[index].room.instructionId == selected.instructionId then
                matches = matches + 1
            end
        end
        if matches ~= 1 then fail(label .. " does not match exactly one additional continuation") end
    end
end

local function validateInstruction(instruction, routeKey, ids, label)
    object(instruction, label)
    stringValue(instruction.kind, label .. ".kind")
    if not INSTRUCTION_KINDS[instruction.kind] then fail(label .. " has unknown instruction kind") end
    if instruction.kind == "batch" then
        keys(instruction, {
            id = true, kind = true, origin = true, parent = true, batchState = true,
            selectedContinuation = true, targets = true, additional = true,
            resolvedSharedRewardStoreKey = true,
        }, nil, label)
        stringValue(instruction.id, label .. ".id")
        validateOrigin(instruction.origin, routeKey, label .. ".origin", "exitDecision")
        referenceObject(instruction.parent, ids, label .. ".parent")
        if not BATCH_STATE_KINDS[instruction.batchState.kind] then fail(label .. ".batchState has unknown kind") end
        if instruction.batchState.kind == "standard" or instruction.batchState.kind == "clockwork" then
            keys(instruction.batchState, { kind = true }, nil, label .. ".batchState")
            -- The discriminator-only variants intentionally have no other keys.
        else
            keys(instruction.batchState, {
                kind = true, batchCapacity = true, cageOutcome = true,
                cageTargetCount = true, doorCageRewardCount = true,
            }, nil, label .. ".batchState")
            positiveInteger(instruction.batchState.batchCapacity, label .. ".batchState.batchCapacity")
            if instruction.batchState.cageOutcome ~= "min" and instruction.batchState.cageOutcome ~= "max" then
                fail(label .. ".batchState.cageOutcome has unknown value")
            end
            for _, field in ipairs({ "cageTargetCount", "doorCageRewardCount" }) do
                if not isInteger(instruction.batchState[field]) or instruction.batchState[field] < 0 then
                    fail(label .. ".batchState." .. field .. " must be non-negative integer")
                end
            end
        end
        if instruction.resolvedSharedRewardStoreKey ~= nil and not isNull(instruction.resolvedSharedRewardStoreKey) then
            stringValue(instruction.resolvedSharedRewardStoreKey, label .. ".resolvedSharedRewardStoreKey")
        end
        object(instruction.selectedContinuation, label .. ".selectedContinuation")
        stringValue(instruction.selectedContinuation.kind, label .. ".selectedContinuation.kind")
        if instruction.selectedContinuation.kind == "normal" then
            keys(instruction.selectedContinuation, { kind = true, exitKey = true, instructionId = true }, nil,
                label .. ".selectedContinuation")
            stringValue(instruction.selectedContinuation.exitKey, label .. ".selectedContinuation.exitKey")
        elseif instruction.selectedContinuation.kind == "additional" then
            keys(instruction.selectedContinuation, { kind = true, additionalExitKey = true, instructionId = true }, nil,
                label .. ".selectedContinuation")
            if not ADDITIONAL_KINDS[instruction.selectedContinuation.additionalExitKey] then
                fail(label .. ".selectedContinuation.additionalExitKey has unknown value")
            end
        else
            fail(label .. ".selectedContinuation has unknown kind")
        end
        local targetCount = isArray(instruction.targets, protocol.MAX_TARGETS, label .. ".targets")
        for index = 1, targetCount do
            local target = instruction.targets[index]
            keys(target, { continuation = true, exit = true, picked = true, room = true }, nil,
                label .. ".targets[" .. index .. "]")
            if not TARGET_CONTINUATIONS[target.continuation] then
                fail(label .. ".target.continuation has unknown value")
            end
            booleanValue(target.picked, label .. ".target.picked")
            referenceObject(target.room, ids, label .. ".target.room")
            validatePhysicalExit(target.exit, label .. ".target.exit")
        end
        local additionalCount = isArray(instruction.additional, protocol.MAX_ADDITIONAL, label .. ".additional")
        for index = 1, additionalCount do
            local extra = instruction.additional[index]
            keys(extra, { key = true, picked = true, room = true }, nil, label .. ".additional[" .. index .. "]")
            if not ADDITIONAL_KINDS[extra.key] then fail(label .. ".additional has unknown key") end
            booleanValue(extra.picked, label .. ".additional.picked")
            referenceObject(extra.room, ids, label .. ".additional.room")
        end
        validateContinuationClosure(instruction.selectedContinuation, instruction.targets, instruction.additional, ids,
            label .. ".selectedContinuation")
    elseif instruction.kind == "hub" then
        keys(instruction, {
            id = true, kind = true, origin = true, source = true, room = true, board = true, visits = true,
        }, nil, label)
        stringValue(instruction.id, label .. ".id")
        validateOrigin(instruction.origin, routeKey, label .. ".origin", "hubDecision")
        referenceObject(instruction.source, ids, label .. ".source")
        referenceObject(instruction.room, ids, label .. ".room")
        keys(instruction.board, { room = true, targets = true }, nil, label .. ".board")
        referenceObject(instruction.board.room, ids, label .. ".board.room")
        local boardCount = isArray(instruction.board.targets, protocol.MAX_TARGETS, label .. ".board.targets")
        for index = 1, boardCount do
            local target = instruction.board.targets[index]
            keys(target, { hubSlotKey = true, physicalDoorId = true, room = true }, nil,
                label .. ".board.targets[]")
            stringValue(target.hubSlotKey, label .. ".hubSlotKey")
            positiveInteger(target.physicalDoorId, label .. ".physicalDoorId")
            referenceObject(target.room, ids, label .. ".board.target.room")
        end
        local visitCount = isArray(instruction.visits, protocol.MAX_VISITS, label .. ".visits")
        for index = 1, visitCount do
            local visit = instruction.visits[index]
            keys(visit, {
                enteredLocalRooms = true, hubRestore = true, localSlots = true,
                parentRestores = true, target = true, visitIndex = true,
            }, nil, label .. ".visits[]")
            if not isInteger(visit.visitIndex) or visit.visitIndex ~= index then
                fail(label .. ".visitIndex must be ordered")
            end
            keys(visit.target, { hubSlotKey = true, physicalDoorId = true, room = true }, nil,
                label .. ".visit.target")
            stringValue(visit.target.hubSlotKey, label .. ".visit.target.hubSlotKey")
            positiveInteger(visit.target.physicalDoorId, label .. ".visit.target.physicalDoorId")
            referenceObject(visit.target.room, ids, label .. ".visit.target.room")
            keys(visit.hubRestore, { room = true }, nil, label .. ".visit.hubRestore")
            referenceObject(visit.hubRestore.room, ids, label .. ".visit.hubRestore.room")
            for _, field in ipairs({ "enteredLocalRooms", "localSlots", "parentRestores" }) do
                local count = isArray(visit[field], protocol.MAX_COLLECTION, label .. ".visit." .. field)
                for item = 1, count do
                    if field == "parentRestores" then
                        keys(visit[field][item], { room = true }, nil, label .. ".visit.parentRestores")
                        referenceObject(visit[field][item].room, ids, label .. ".visit.parentRestores.room")
                    else
                        referenceObject(visit[field][item], ids, label .. ".visit." .. field)
                    end
                end
            end
        end
    else
        validateRoom(instruction, routeKey, label)
    end
end

local function validateRoute(route)
    keys(route,
        { routeKey = true, fingerprint = true, entryInstructionId = true, instructions = true, biomes = true }, nil,
        "execution.route")
    if not ROUTES[route.routeKey] then fail("execution route has unknown routeKey " .. tostring(route.routeKey)) end
    fingerprint(route.fingerprint, "execution.route.fingerprint")
    stringValue(route.entryInstructionId, "execution.route.entryInstructionId")
    local instructionCount = isArray(route.instructions, protocol.MAX_INSTRUCTIONS, "execution.route.instructions")
    if instructionCount == 0 then fail("execution route must contain instructions") end
    local ids = {}
    for index = 1, instructionCount do
        local instruction = route.instructions[index]
        object(instruction, "execution.route.instructions[" .. index .. "]")
        stringValue(instruction.id, "execution.route.instructions[].id")
        if ids[instruction.id] then fail("duplicate instruction id " .. instruction.id) end
        ids[instruction.id] = true
    end
    if not ids[route.entryInstructionId] then
        fail("execution.route.entryInstructionId references missing instruction")
    end
    for index = 1, instructionCount do
        validateInstruction(route.instructions[index], route.routeKey, ids,
            "execution.route.instructions[" .. index .. "]")
    end
    local biomeCount = isArray(route.biomes, protocol.MAX_BIOMES, "execution.route.biomes")
    for index = 1, biomeCount do
        local biome = route.biomes[index]
        keys(biome, {
            biomeKey = true, entryInstructionId = true,
            decisionInstructionIds = true, completionInstructionIds = true,
        }, nil, "execution.route.biomes[" .. index .. "]")
        stringValue(biome.biomeKey, "execution.route.biomes[].biomeKey")
        reference(biome.entryInstructionId, ids, "execution.route.biomes[].entryInstructionId")
        for _, field in ipairs({ "decisionInstructionIds", "completionInstructionIds" }) do
            local count = isArray(biome[field], protocol.MAX_COLLECTION, "execution.route.biomes[]." .. field)
            for item = 1, count do reference(biome[field][item], ids, "execution.route.biomes[]." .. field .. "[]") end
        end
    end
    return route
end

function protocol.decode(bundle)
    if not isJsonObject(bundle) then return nil, "malformed-bundle" end
    local ok, result, reason = pcall(function()
        keys(bundle, { fileFormat = true, fileVersion = true, project = true }, { execution = true }, "bundle")
        if bundle.fileFormat ~= protocol.FILE_FORMAT then fail("malformed-bundle") end
        if bundle.fileVersion ~= protocol.FILE_VERSION then return nil, "unsupported-bundle-version" end
        -- The project is deliberately not retained. It is a producer-owned
        -- status signal only; consumers publish execution products.
        object(bundle.project, "bundle.project")
        if bundle.execution == nil then
            return {
                kind = "project-only",
                fileFormat = bundle.fileFormat,
                fileVersion = bundle.fileVersion,
                routeKeys = {},
            }
        end
        local execution = bundle.execution
        keys(execution, {
            protocolVersion = true, projectId = true, catalogVersion = true, routes = true, fingerprint = true,
        }, nil, "bundle.execution")
        if execution.protocolVersion ~= protocol.EXECUTION_PROTOCOL_VERSION then
            return nil, "unsupported-execution-protocol-version"
        end
        stringValue(execution.projectId, "execution.projectId")
        stringValue(execution.catalogVersion, "execution.catalogVersion")
        fingerprint(execution.fingerprint, "execution.fingerprint")
        local routeCount = isArray(execution.routes, protocol.MAX_ROUTES, "execution.routes")
        if routeCount == 0 then fail("execution.routes cannot be empty") end
        local routes = {}
        local routeKeys = {}
        for index = 1, routeCount do
            local route = validateRoute(execution.routes[index])
            if routes[route.routeKey] then fail("duplicate execution route") end
            routes[route.routeKey] = route
            routeKeys[#routeKeys + 1] = route.routeKey
        end
        table.sort(routeKeys)
        return {
            kind = "ready",
            fileFormat = bundle.fileFormat,
            fileVersion = bundle.fileVersion,
            execution = execution,
            routes = routes,
            routeKeys = routeKeys,
            protocolVersion = execution.protocolVersion,
            catalogVersion = execution.catalogVersion,
            fingerprint = execution.fingerprint,
            projectId = execution.projectId,
        }
    end)
    if not ok then return nil, result end
    if result == nil then return nil, reason or "malformed-bundle" end
    return result
end

protocol.null = {}

return protocol
