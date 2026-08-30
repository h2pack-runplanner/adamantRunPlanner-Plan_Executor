-- Current-run compiled-route session. It freezes one resolved program, executes
-- exact room contacts, and observes the resulting trace. It never replans,
-- evaluates eligibility, or mutates global game declarations.

local session = {}

session.CACHE_NAME = "ExecutionSession"

local BIOME_ROUTE = {
    F = "Underworld", G = "Underworld", H = "Underworld", I = "Underworld",
    N = "Surface", O = "Surface", P = "Surface", Q = "Surface",
}

local function emptySession()
    return {
        initialized = false,
        state = "inactive",
        reason = "not-started",
        context = {},
    }
end

local function boundedScalar(value, maximum)
    local kind = type(value)
    local text
    if value == nil then
        text = "none"
    elseif kind == "string" or kind == "number" or kind == "boolean" then
        text = tostring(value)
    else
        text = "unsupported"
    end
    maximum = maximum or 72
    if #text > maximum then return text:sub(1, maximum - 3) .. "..." end
    return text
end

local function contactText(prefix, value)
    if type(value) ~= "table" then return prefix .. ".value=" .. boundedScalar(value) end
    return table.concat({
        prefix .. ".kind=" .. boundedScalar(value.kind),
        prefix .. ".key=" .. boundedScalar(value.key),
        prefix .. ".value=" .. boundedScalar(value.value),
    }, " ")
end

local function originText(origin)
    if type(origin) ~= "table" then return "origin.kind=none" end
    local source = type(origin.source) == "table" and origin.source or {}
    return table.concat({
        "origin.kind=" .. boundedScalar(origin.kind),
        "origin.route=" .. boundedScalar(origin.routeKey),
        "origin.biome=" .. boundedScalar(origin.biomeKey),
        "origin.occurrence=" .. boundedScalar(origin.occurrenceId),
        "origin.group=" .. boundedScalar(origin.groupKey),
        "origin.slot=" .. boundedScalar(origin.slotKey),
        "origin.hub=" .. boundedScalar(origin.hubKey),
        "origin.role=" .. boundedScalar(origin.role),
        "origin.source.kind=" .. boundedScalar(source.kind),
        "origin.source.occurrence=" .. boundedScalar(source.occurrenceId),
        "origin.source.decision=" .. boundedScalar(source.decisionKey),
    }, " ")
end

local function sessionStatus(state)
    local mismatch = state.firstMismatch or {}
    local context = state.context or {}
    local parts = {
        "state=" .. boundedScalar(state.state),
        "reason=" .. boundedScalar(state.reason),
        "route=" .. boundedScalar(state.routeKey),
        "cursor=" .. boundedScalar(state.cursor),
        "instruction=" .. boundedScalar(mismatch.instructionId),
        "checkpoint=" .. boundedScalar(mismatch.checkpoint),
        "beforeApply=" .. boundedScalar(mismatch.beforeApply),
        contactText("expected", mismatch.expected),
        contactText("observed", mismatch.observed),
        "plan=" .. boundedScalar(state.planFingerprint),
        "routeFingerprint=" .. boundedScalar(state.routeFingerprint),
        "catalog=" .. boundedScalar(state.catalogVersion),
        "gameRevision=" .. boundedScalar(mismatch.gameVersion or context.gameVersion),
        "startingBiome=" .. boundedScalar(context.startingBiome),
        "startingRoomSet=" .. boundedScalar(context.roomSetName),
        "startingRoom=" .. boundedScalar(context.roomName),
        originText(mismatch.instructionOwner),
    }
    local diagnostic = table.concat(parts, " ")
    return #diagnostic > 1000 and diagnostic:sub(1, 997) .. "..." or diagnostic
end

local function copyScalarContext(args, currentRun, room)
    return {
        startingBiome = args and args.StartingBiome or nil,
        roomSetName = room and room.RoomSetName or nil,
        roomName = room and room.Name or nil,
        gameVersion = currentRun and currentRun.Revision or "unknown",
    }
end

local function refreshStartingContext(state, args, currentRun, room)
    if state == nil then return end
    local context = state.context or {}
    state.context = context
    local startingBiome = args and args.StartingBiome
    context.startingBiome = type(startingBiome) == "string" and startingBiome ~= "" and startingBiome
        or context.startingBiome
        or (room and room.RoomSetName)
    context.roomSetName = room and room.RoomSetName or context.roomSetName
    context.roomName = room and (room.GenusName or room.Name) or context.roomName
    context.gameVersion = currentRun and currentRun.Revision or context.gameVersion
end

local function instructionOwner(instruction)
    return instruction and instruction.origin or nil
end

local function mismatch(state, checkpoint, expected, observed, instruction, currentRun, beforeApply)
    if state.firstMismatch ~= nil then return end
    state.firstMismatch = {
        catalogVersion = state.catalogVersion,
        planFingerprint = state.planFingerprint,
        routeFingerprint = state.routeFingerprint,
        routeKey = state.routeKey,
        gameVersion = currentRun and currentRun.Revision or "unknown",
        checkpoint = checkpoint,
        expected = expected,
        observed = observed,
        beforeApply = beforeApply ~= false,
        instructionId = instruction and instruction.id or nil,
        instructionOwner = instructionOwner(instruction),
        context = state.context,
    }
    state.state = "desynchronized"
    state.reason = "live-contact-failure"
end

local function addStoreMembership(memberships, store, name)
    if type(store) ~= "table" then return end
    for _, item in pairs(store) do
        if type(item) == "table" and item.Name == name then
            memberships[name] = true
            return
        end
    end
    for _, group in ipairs(store.GroupsOf or {}) do
        for _, item in ipairs(group.OptionsData or {}) do
            if item.Name == name then memberships[name] = true; return end
        end
    end
    for _, item in ipairs(store.HealingOffers and store.HealingOffers.WeightedList or {}) do
        if item.Name == name then memberships[name] = true; return end
    end
    for _, key in ipairs(store.Traits or {}) do
        if key == name then memberships[name] = true; return end
    end
    for _, key in ipairs(store.Consumables or {}) do
        if key == name then memberships[name] = true; return end
    end
end

local function directRewardExists(game, rewardType)
    return (type(game.RewardData) == "table" and game.RewardData[rewardType] ~= nil)
        or (type(game.LootData) == "table" and game.LootData[rewardType] ~= nil)
        or (type(game.ConsumableData) == "table" and game.ConsumableData[rewardType] ~= nil)
        or (type(game.TraitData) == "table" and game.TraitData[rewardType] ~= nil)
end

local function optionalKey(value)
    return type(value) == "string" and value or nil
end

local function rewardExists(game, rewardType, storeKey, shopKey, room)
    local membership = {}
    -- Explicit compiled references are exact: a room's incidental declaration
    -- cannot substitute a different reward-store or Shop profile.
    if storeKey then
        addStoreMembership(membership, game.RewardStoreData and game.RewardStoreData[storeKey], rewardType)
        return membership[rewardType] == true
    end
    if shopKey then
        addStoreMembership(membership, game.StoreData and game.StoreData[shopKey], rewardType)
        return membership[rewardType] == true
    end
    if room and room.RewardStoreName then
        addStoreMembership(membership, game.RewardStoreData and game.RewardStoreData[room.RewardStoreName], rewardType)
    end
    if room and room.IndividualRewardStore then
        addStoreMembership(membership,
            game.RewardStoreData and game.RewardStoreData[room.IndividualRewardStore], rewardType)
    end
    if room and room.StoreDataName then
        addStoreMembership(membership, game.StoreData and game.StoreData[room.StoreDataName], rewardType)
    end
    -- Storeless offers may use a direct game identity or the selected room
    -- declaration's concrete membership.
    return directRewardExists(game, rewardType) or membership[rewardType] == true
end

local function checkValue(game, kind, key, owner, state, currentRun)
    local tableName = ({
        room = "RoomData", rewardStore = "RewardStoreData", shop = "StoreData", encounter = "EncounterData",
    })[kind]
    if type(game[tableName]) ~= "table" or game[tableName][key] == nil then
        mismatch(state, "live-contact", { kind = kind, key = key }, { kind = kind, key = nil }, owner, currentRun)
        return false
    end
    return true
end

local PRODUCER_KINDS = {
    countedChoice = true,
    fixed = true,
    freeReward = true,
    shop = true,
}

local function roomForcesReward(room, rewardType)
    return type(room) == "table"
        and (room.ForcedReward == rewardType or room.ForcedFirstReward == rewardType)
end

local function rewardContact(game, offer, producerKind, storeKey, shopKey, room)
    if producerKind == nil then
        return rewardExists(game, offer.rewardType, storeKey, shopKey, room)
    end
    if not PRODUCER_KINDS[producerKind] then return false, "unknown-producer-kind" end
    -- resolvedStoreKey records different provenance for each producer. Only
    -- counted/free draws require that exact store membership at runtime.
    if producerKind == "countedChoice" or producerKind == "freeReward" then
        return storeKey ~= nil and rewardExists(game, offer.rewardType, storeKey, nil, room)
    end
    if producerKind == "shop" then
        if offer.rewardType ~= "Shop" then return false, "shop-producer-requires-shop-reward" end
        return roomForcesReward(room, offer.rewardType)
    end
    if roomForcesReward(room, offer.rewardType) then return true end
    if storeKey and rewardExists(game, offer.rewardType, storeKey, nil, room) then return true end
    return directRewardExists(game, offer.rewardType)
end

local function checkOffer(game, offer, producerKind, storeKey, shopKey, room, owner, state, currentRun)
    local contacted, reason = rewardContact(game, offer, producerKind, storeKey, shopKey, room)
    if not contacted then
        mismatch(state, "live-contact", { kind = "reward", key = offer.rewardType },
            { kind = "reward", key = nil, reason = reason }, owner, currentRun)
        return false
    end
    local payload = offer.payload
    if payload then
        if payload.kind == "BoonSource" then
            if type(game.LootData) ~= "table" or game.LootData[payload.source] == nil then
                mismatch(state, "live-contact", { kind = "loot-source", key = payload.source },
                    { kind = "loot-source", key = nil }, owner, currentRun)
                return false
            end
        elseif payload.kind == "DevotionPair" then
            for _, source in ipairs({ payload.chosenSource, payload.spurnedSource }) do
                if type(game.LootData) ~= "table" or game.LootData[source] == nil then
                    mismatch(state, "live-contact", { kind = "loot-source", key = source },
                        { kind = "loot-source", key = nil }, owner, currentRun)
                    return false
                end
            end
        end
    end
    return true
end

local function checkInstruction(game, instruction, state, currentRun)
    if instruction.gameName
        and not checkValue(game, "room", instruction.gameName, instruction, state, currentRun) then return false end
    if instruction.anomalyReplacement
        and not checkValue(game, "room", instruction.anomalyReplacement.replacedRoomGameName,
            instruction, state, currentRun) then return false end
    local room = instruction.gameName and game.RoomData[instruction.gameName] or nil
    if instruction.incomingReward then
        local storeKey = optionalKey(instruction.incomingReward.resolvedStoreKey)
        if storeKey and not checkValue(game, "rewardStore", storeKey, instruction, state, currentRun) then
            return false
        end
        if not checkOffer(game, instruction.incomingReward.offer, instruction.incomingReward.producerKind, storeKey,
            nil, room, instruction, state, currentRun) then return false end
    end
    if instruction.enteredRewardStoreKey
        and not checkValue(game, "rewardStore", instruction.enteredRewardStoreKey,
            instruction, state, currentRun) then return false end
    local sharedStoreKey = optionalKey(instruction.resolvedSharedRewardStoreKey)
    if instruction.kind == "batch" and sharedStoreKey
        and not checkValue(game, "rewardStore", sharedStoreKey,
            instruction, state, currentRun) then return false end
    if instruction.shop then
        if not checkValue(game, "shop", instruction.shop.profileKey, instruction, state, currentRun) then
            return false
        end
        for _, item in ipairs(instruction.shop.offers) do
            if not checkOffer(game, item.offer, nil, nil, instruction.shop.profileKey,
                room, instruction, state, currentRun) then return false end
        end
    end
    for _, reward in ipairs(instruction.localRewards or {}) do
        if not checkValue(game, "rewardStore", reward.resolvedStoreKey, instruction, state, currentRun)
            or not checkOffer(game, reward.offer, nil, reward.resolvedStoreKey,
                nil, room, instruction, state, currentRun) then return false end
    end
    for _, wheel in ipairs(instruction.rewardWheels or {}) do
        if not checkValue(game, "rewardStore", wheel.storeKey, instruction, state, currentRun) then
            return false
        end
        for _, item in ipairs(wheel.offers) do
            if not checkOffer(game, item.offer, nil, wheel.storeKey, nil,
                room, instruction, state, currentRun) then return false end
        end
    end
    for _, phase in ipairs(instruction.encounterPhases or {}) do
        if not checkValue(game, "encounter", phase.encounterKey, instruction, state, currentRun) then
            return false
        end
    end
    return true
end

local function scanContact(game, route, state, currentRun)
    for _, instruction in ipairs(route.instructions) do
        if not checkInstruction(game, instruction, state, currentRun) then return false end
    end
    return true
end

local function indexes(route)
    local instructionById, biomeByKey, batchByParent, biomeIndexByKey = {}, {}, {}, {}
    for _, instruction in ipairs(route.instructions) do
        instructionById[instruction.id] = instruction
        if instruction.kind == "batch" then batchByParent[instruction.parent.instructionId] = instruction end
    end
    for index, biome in ipairs(route.biomes) do
        biomeByKey[biome.biomeKey] = biome
        biomeIndexByKey[biome.biomeKey] = index
    end
    return instructionById, biomeByKey, batchByParent, biomeIndexByKey
end

local function selectedEntry(route, biomeKey)
    for _, biome in ipairs(route.biomes) do
        if biome.biomeKey == biomeKey then return biome.entryInstructionId end
    end
    return route.entryInstructionId
end

local function initialize(state, host, inbox, game, currentRun, args)
    if state.initialized then return end
    state.initialized = true
    state.context = copyScalarContext(args, currentRun, currentRun and currentRun.CurrentRoom)
    if host and type(host.isEnabled) == "function" and not host.isEnabled() then
        state.state, state.reason = "inactive", "module-disabled"; return
    end
    if currentRun and currentRun.IsDreamRun then
        state.state, state.reason = "inactive", "dream-run"; return
    end
    local suppliedBiome = args and args.StartingBiome
    local biomeKey = type(suppliedBiome) == "string" and suppliedBiome ~= "" and suppliedBiome
        or (currentRun and currentRun.CurrentRoom and currentRun.CurrentRoom.RoomSetName)
    local routeKey = BIOME_ROUTE[biomeKey]
    if not routeKey then state.state, state.reason = "inactive", "unknown-route"; return end
    state.routeKey = routeKey
    local ok, decoded = inbox.load()
    if not ok then state.state, state.reason = "inactive", "bundle-unavailable"; return end
    if decoded.kind ~= "ready" then state.state, state.reason = "inactive", "project-only"; return end
    local route = decoded.routes[routeKey]
    if not route then state.state, state.reason = "inactive", "unconfigured-route"; return end
    state.catalogVersion = decoded.catalogVersion
    state.planFingerprint = decoded.fingerprint
    state.routeFingerprint = route.fingerprint
    state.program = route
    state.instructionById, state.biomeByKey, state.batchByParent, state.biomeIndexByKey = indexes(route)
    state.cursor = selectedEntry(route, biomeKey)
    if not scanContact(game, route, state, currentRun) then return end
    state.state, state.reason = "active", nil
end

-- Slice 6 only translates already-resolved room instructions. It neither asks
-- vanilla whether a target is eligible nor feeds a generated object back into
-- planning. The marker lives on the per-door room copy, never RoomData.
local function roomName(room)
    return room and (room.GenusName or room.Name) or nil
end

local function roomInstruction(state, id)
    local instruction = state and state.instructionById and state.instructionById[id] or nil
    return instruction and instruction.gameName and instruction or nil
end

local currentInstructionMatches

local function markRoomData(game, state, target, batch)
    local instruction = roomInstruction(state, target.room.instructionId)
    if not instruction or type(game.RoomData) ~= "table" or game.RoomData[instruction.gameName] == nil then
        return nil
    end
    local copy = {}
    for key, value in pairs(game.RoomData[instruction.gameName]) do copy[key] = value end
    copy.__runPlannerInstructionId = instruction.id
    copy.__runPlannerBatchId = batch.id
    copy.__runPlannerExitKey = target.exit.exitKey
    copy.__runPlannerExitIndex = target.exit.index
    copy.__runPlannerExitType = target.exit.type
    copy.__runPlannerExitBehavior = target.exit.behavior
    return copy
end

local function markStartingRoomData(game, instruction)
    if type(game.RoomData) ~= "table" or game.RoomData[instruction.gameName] == nil then return nil end
    local copy = {}
    for key, value in pairs(game.RoomData[instruction.gameName]) do copy[key] = value end
    copy.__runPlannerInstructionId = instruction.id
    copy.__runPlannerStartingRoom = true
    return copy
end

local function physicalTarget(state, currentRun, room, instruction)
    local batch = state.batchByParent and state.batchByParent[state.cursor] or nil
    if not batch or not instruction then
        mismatch(state, "reward-marker", { kind = "instruction", key = state.cursor },
            { kind = "instruction", key = room and room.__runPlannerInstructionId }, instruction, currentRun)
        return nil
    end
    local target
    for _, candidate in ipairs(batch.targets) do
        if candidate.room.instructionId == instruction.id then target = candidate; break end
    end
    if not target then
        mismatch(state, "reward-marker", { kind = "instruction", key = instruction.id },
            { kind = "instruction", key = room.__runPlannerInstructionId }, instruction, currentRun)
        return nil
    end
    local checks = {
        { "batch", batch.id, room.__runPlannerBatchId },
        { "exitKey", target.exit.exitKey, room.__runPlannerExitKey },
        { "exitIndex", target.exit.index, room.__runPlannerExitIndex },
        { "exitType", target.exit.type, room.__runPlannerExitType },
        { "exitBehavior", target.exit.behavior, room.__runPlannerExitBehavior },
        { "room", instruction.gameName, roomName(room) },
    }
    for _, check in ipairs(checks) do
        if check[2] ~= check[3] then
            mismatch(state, "reward-marker", { kind = check[1], key = check[2] },
                { kind = check[1], key = check[3] }, instruction, currentRun)
            return nil
        end
    end
    return target
end

-- A generated room copy is the sole reward-routing authority.  Do not infer a
-- reward from the room name: a physical batch can contain repeated game names
-- (notably the two preboss targets) with distinct compiled rewards.
local function markedRewardInstruction(state, currentRun, room, args)
    if state == nil or state.state ~= "active" then return { kind = "passThrough" } end
    if type(room) ~= "table" or room.__runPlannerInstructionId == nil then
        return { kind = "passThrough" }
    end
    local instruction = roomInstruction(state, room.__runPlannerInstructionId)
    if room.__runPlannerStartingRoom then
        if instruction and instruction.id == state.cursor and roomName(room) == instruction.gameName then
            if instruction.incomingReward then
                return { kind = "handled", instruction = instruction, reward = instruction.incomingReward,
                    role = "starting" }
            end
            return { kind = "nilExpected", instruction = instruction, role = "starting" }
        end
        mismatch(state, "reward-marker", { kind = "instruction", key = state.cursor },
            { kind = "instruction", key = room.__runPlannerInstructionId }, instruction, currentRun)
        return { kind = "failed" }
    end
    if room.__runPlannerRewardRole == "local" and instruction and instruction.localRewards then
        if not physicalTarget(state, currentRun, room, instruction) then return { kind = "failed" } end
        local index = room.__runPlannerLocalRewardIndex
        local reward = instruction.localRewards[index]
        if reward then return { kind = "handled", instruction = instruction, reward = reward, role = "local" } end
        mismatch(state, "local-reward", { kind = "local-reward", key = index },
            { kind = "local-reward", key = nil }, instruction, currentRun)
        return { kind = "failed" }
    end
    local isDoorTarget = type(args) == "table" and type(args.Door) == "table" and args.Door.Room == room
    if not isDoorTarget and room.__runPlannerTargetRewardInitialized and instruction
        and instruction.localRewards and #instruction.localRewards > 0 and args == nil then
        if not physicalTarget(state, currentRun, room, instruction) then return { kind = "failed" } end
        local counts = state.localRewardCounts or {}
        state.localRewardCounts = counts
        local index = (counts[instruction.id] or 0) + 1
        local reward = instruction.localRewards[index]
        if reward == nil then
            mismatch(state, "local-reward", { kind = "local-reward", key = index },
                { kind = "local-reward", key = nil }, instruction, currentRun)
            return { kind = "failed" }
        end
        counts[instruction.id] = index
        room.__runPlannerLocalRewardIndex = index
        room.__runPlannerRewardRole = "local"
        return { kind = "handled", instruction = instruction, reward = reward, role = "local" }
    end
    if not isDoorTarget then return { kind = "passThrough" } end
    if not physicalTarget(state, currentRun, room, instruction) then return { kind = "failed" } end
    if not instruction.incomingReward then
        return { kind = "nilExpected", instruction = instruction, role = "target", localReady = true }
    end
    return { kind = "handled", instruction = instruction, reward = instruction.incomingReward, role = "target" }
end

local function copyTable(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

local function restoreTable(target, source)
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(source) do target[key] = value end
end

local function requiredPayload(state, currentRun, instruction, reward)
    local payload = reward.offer.payload
    local kind = reward.offer.rewardType
    if kind == "Boon" and (not payload or payload.kind ~= "BoonSource") then
        mismatch(state, "reward-source", { kind = "BoonSource", key = nil },
            { kind = "payload", key = payload and payload.kind or nil }, instruction, currentRun)
        return nil
    end
    if kind == "Devotion" and (not payload or payload.kind ~= "DevotionPair") then
        mismatch(state, "reward-source", { kind = "DevotionPair", key = nil },
            { kind = "payload", key = payload and payload.kind or nil }, instruction, currentRun)
        return nil
    end
    return payload
end

local function observedRewardType(value)
    return type(value) == "table" and value.Name or value
end

function session.prepareBatchRewardStore(state, currentRun)
    if state == nil or state.state ~= "active" then return { kind = "passThrough" } end
    local batch = state.batchByParent and state.batchByParent[state.cursor] or nil
    if not batch then return { kind = "passThrough" } end
    if not currentInstructionMatches(state, currentRun) then
        mismatch(state, "reward-store", { kind = "room", key = state.cursor },
            { kind = "room", key = roomName(currentRun and currentRun.CurrentRoom) },
            roomInstruction(state, state.cursor), currentRun)
        return { kind = "failed" }
    end
    if type(batch.resolvedSharedRewardStoreKey) ~= "string" then return { kind = "passThrough" } end
    currentRun.NextRewardStoreName = batch.resolvedSharedRewardStoreKey
    return { kind = "handled" }
end

function session.chooseRoomReward(state, currentRun, room, rewardStoreName, previouslyChosenRewards, args, base)
    local contact = markedRewardInstruction(state, currentRun, room, args)
    if contact.kind == "nilExpected" then
        if contact.localReady then room.__runPlannerTargetRewardInitialized = true end
        local actual = base(currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        if actual ~= nil then
            mismatch(state, "reward-type", { kind = "reward", key = nil },
                { kind = "reward", key = observedRewardType(actual) }, contact.instruction, currentRun, false)
            return { kind = "failed", value = actual }
        end
        return { kind = "handled", value = actual }
    end
    if contact.kind ~= "handled" then
        if contact.localReady then room.__runPlannerTargetRewardInitialized = true end
        return contact
    end
    local expected = contact.reward
    local payload = requiredPayload(state, currentRun, contact.instruction, expected)
    if (expected.offer.rewardType == "Boon" or expected.offer.rewardType == "Devotion") and not payload then
        return { kind = "failed" }
    end
    if expected.resolvedStoreKey ~= nil and rewardStoreName ~= expected.resolvedStoreKey then
        mismatch(state, "reward-store", { kind = "rewardStore", key = expected.resolvedStoreKey },
            { kind = "rewardStore", key = rewardStoreName }, contact.instruction, currentRun)
        return { kind = "failed" }
    end
    local priorities = currentRun and currentRun.RewardPriorities
    local needsPriority = contact.role == "local" or expected.producerKind == "countedChoice"
        or expected.producerKind == "freeReward"
    local originalPriorities = needsPriority and type(priorities) == "table" and copyTable(priorities) or nil
    if originalPriorities then table.insert(priorities, 1, expected.offer.rewardType) end
    local ok, actual = pcall(base, currentRun, room, rewardStoreName, previouslyChosenRewards, args)
    if originalPriorities then restoreTable(priorities, originalPriorities) end
    if not ok then error(actual, 0) end
    local actualType = observedRewardType(actual)
    if actualType ~= expected.offer.rewardType then
        mismatch(state, "reward-type", { kind = "reward", key = expected.offer.rewardType },
            { kind = "reward", key = actualType }, contact.instruction, currentRun, false)
        return { kind = "failed", value = actual }
    end
    if payload and payload.kind == "BoonSource" then room.ForceLootName = payload.source end
    if contact.role == "target" then room.__runPlannerTargetRewardInitialized = true end
    return { kind = "handled", value = actual, instruction = contact.instruction }
end

function session.setupRoomReward(state, currentRun, room, previouslyChosenRewards, args, base)
    local contact = markedRewardInstruction(state, currentRun, room, args)
    if contact.kind ~= "handled" then return contact end
    local expected = contact.reward
    local payload = requiredPayload(state, currentRun, contact.instruction, expected)
    if (expected.offer.rewardType == "Boon" or expected.offer.rewardType == "Devotion") and not payload then
        return { kind = "failed" }
    end
    if room.ChosenRewardType ~= expected.offer.rewardType then
        mismatch(state, "reward-type", { kind = "reward", key = expected.offer.rewardType },
            { kind = "reward", key = room.ChosenRewardType }, contact.instruction, currentRun)
        return { kind = "failed" }
    end
    local result = base(currentRun, room, previouslyChosenRewards, args)
    if payload and payload.kind == "BoonSource" then
        if room.ForceLootName ~= payload.source then
            mismatch(state, "reward-source", { kind = "BoonSource", key = payload.source },
                { kind = "BoonSource", key = room.ForceLootName }, contact.instruction, currentRun, false)
            return { kind = "failed" }
        end
    elseif payload and payload.kind == "DevotionPair" then
        if type(room.Encounter) ~= "table" then
            mismatch(state, "reward-source", { kind = "DevotionPair", key = payload.chosenSource },
                { kind = "DevotionPair", key = nil }, contact.instruction, currentRun, false)
            return { kind = "failed" }
        end
        room.Encounter.LootAName = payload.chosenSource
        room.Encounter.LootBName = payload.spurnedSource
    end
    return { kind = "handled", result = result }
end

function session.observeAnomalyReward(state, currentRun, encounter)
    if state == nil or state.state ~= "active" then return { kind = "passThrough" } end
    local instruction = roomInstruction(state, state.cursor)
    local room = currentRun and currentRun.CurrentRoom
    if not instruction or not instruction.anomalyReplacement or roomName(room) ~= instruction.gameName
        or room.__runPlannerInstructionId ~= instruction.id
    then
        return { kind = "passThrough" }
    end
    local expected = instruction.incomingReward and instruction.incomingReward.acquisitionEnabled
    if type(expected) ~= "boolean" then return { kind = "passThrough" } end
    local succeeded = type(encounter) == "table" and encounter.CapturePointProgress >= 100
    if succeeded ~= expected then
        mismatch(state, "anomaly-reward", { kind = "acquisition", key = expected },
            { kind = "acquisition", key = succeeded }, instruction, currentRun, false)
        return { kind = "failed" }
    end
    return { kind = "handled" }
end

function session.observeDevotionSelection(state, currentRun, encounter)
    if state == nil or state.state ~= "active" then return { kind = "passThrough" } end
    local instruction = roomInstruction(state, state.cursor)
    local room = currentRun and currentRun.CurrentRoom
    local reward = instruction and instruction.incomingReward or nil
    local payload = reward and reward.offer and reward.offer.payload or nil
    if not instruction or room == nil or room.__runPlannerInstructionId ~= instruction.id
        or roomName(room) ~= instruction.gameName or not payload or payload.kind ~= "DevotionPair" then
        return { kind = "passThrough" }
    end
    if type(encounter) ~= "table" or encounter.ChosenGodName ~= payload.chosenSource
        or encounter.SpurnedGodName ~= payload.spurnedSource
    then
        mismatch(state, "devotion-choice", { kind = "DevotionPair", key = payload.chosenSource },
            { kind = "DevotionPair", key = type(encounter) == "table" and encounter.ChosenGodName or nil },
            instruction, currentRun, false)
        return { kind = "failed" }
    end
    return { kind = "handled" }
end

currentInstructionMatches = function(state, currentRun, currentRunRoom)
    local instruction = roomInstruction(state, state and state.cursor)
    local observedRoom = currentRunRoom or (currentRun and currentRun.CurrentRoom)
    return instruction ~= nil and roomName(observedRoom) == instruction.gameName
end

local function targetForSelected(batch)
    if batch.selectedContinuation.kind ~= "normal" then return nil end
    for _, target in ipairs(batch.targets) do
        if target.exit.exitKey == batch.selectedContinuation.exitKey
            and target.room.instructionId == batch.selectedContinuation.instructionId then return target end
    end
    return nil
end

local function expectedAutomaticSuccessor(state)
    if state.pendingAutomaticTargetId ~= nil then return state.pendingAutomaticTargetId end
    local current = roomInstruction(state, state.cursor)
    if not current then return nil end
    if state.completionPendingFrom == current.id then
        local biome = state.biomeByKey[current.origin.biomeKey]
        return biome and biome.completionInstructionIds[1] or nil
    end
    if current.kind ~= "completion" then return nil end
    local biome = state.biomeByKey[current.origin.biomeKey]
    if not biome then return nil end
    for index, id in ipairs(biome.completionInstructionIds) do
        if id == current.id then
            if biome.completionInstructionIds[index + 1] then return biome.completionInstructionIds[index + 1] end
            local nextBiome = state.program.biomes[(state.biomeIndexByKey[current.origin.biomeKey] or 0) + 1]
            return nextBiome and nextBiome.entryInstructionId or nil
        end
    end
    return nil
end

local function isFinalCompiledCompletion(state, instruction)
    if not instruction or instruction.kind ~= "completion" then return false end
    local biomeKey = instruction.origin and instruction.origin.biomeKey
    local biomeIndex = biomeKey and state.biomeIndexByKey[biomeKey] or nil
    if biomeIndex ~= #state.program.biomes then return false end
    local biome = biomeKey and state.biomeByKey[biomeKey] or nil
    return biome ~= nil and biome.completionInstructionIds[#biome.completionInstructionIds] == instruction.id
end

function session.chooseStartingRoom(state, currentRun, args, game)
    if state == nil or state.state ~= "active" then return nil end
    local instruction = roomInstruction(state, state.cursor)
    local createRoom = game.CreateRoom or _G.CreateRoom
    if not instruction or type(createRoom) ~= "function" or type(game.RoomData) ~= "table" then
        mismatch(state, "starting-room", instruction and instruction.gameName or nil, nil, instruction, currentRun)
        return nil
    end
    local roomData = markStartingRoomData(game, instruction)
    if roomData == nil then
        mismatch(state, "starting-room", instruction.gameName, nil, instruction, currentRun)
        return nil
    end
    local room = createRoom(roomData, args)
    refreshStartingContext(state, args, currentRun, room)
    return room
end

function session.isOrdinaryDoorGenerationContact(state, args, otherDoors)
    if state == nil or state.state ~= "active" then return false end
    if type(otherDoors) ~= "table" or #otherDoors == 0 then return false end
    if args and (args.ForceNextRoom ~= nil or args.ForceNextRoomSet ~= nil) then return false end
    if _G.ForceNextRoom ~= nil then return false end
    return state.batchByParent and state.batchByParent[state.cursor] ~= nil
end

function session.chooseNextRoom(state, currentRun, otherDoors, game)
    if state == nil or state.state ~= "active" then return nil end
    if not currentInstructionMatches(state, currentRun) then
        mismatch(state, "outgoing-room",
            roomInstruction(state, state.cursor) and roomInstruction(state, state.cursor).gameName,
            roomName(currentRun and currentRun.CurrentRoom), roomInstruction(state, state.cursor), currentRun)
        return nil
    end
    local batch = state.batchByParent[state.cursor]
    if not batch then return nil end
    local generation = state.generation
    if generation == nil then
        generation = { batchId = batch.id, count = 0, targets = batch.targets, generatedByIndex = {} }
        state.generation = generation
    elseif generation.batchId ~= batch.id then
        mismatch(state, "outgoing-batch", batch.id, generation.batchId, batch, currentRun)
        return nil
    end
    if #otherDoors ~= #batch.targets then
        mismatch(state, "door-generation", { kind = "door-count", key = #batch.targets },
            { kind = "door-count", key = #otherDoors }, batch, currentRun)
        return nil
    end
    local target
    for _, candidate in ipairs(generation.targets) do
        local physicalIndex = candidate.exit.index
        local door = otherDoors[physicalIndex]
        if door == nil then
            mismatch(state, "door-generation", { kind = "door", key = physicalIndex },
                { kind = "door", key = nil }, batch, currentRun)
            return nil
        end
        if door.Room ~= nil and not generation.generatedByIndex[physicalIndex]
            and (door.Room.__runPlannerInstructionId ~= candidate.room.instructionId
                or door.Room.__runPlannerBatchId ~= batch.id) then
            mismatch(state, "door-generation", { kind = "room", key = candidate.room.instructionId },
                { kind = "room", key = roomName(door.Room) }, batch, currentRun)
            return nil
        end
        if not generation.generatedByIndex[physicalIndex]
            and (target == nil or physicalIndex < target.exit.index) then target = candidate end
    end
    if target == nil then
        mismatch(state, "door-generation", { kind = "exit", key = batch.id },
            { kind = "exit", key = nil }, batch, currentRun)
        return nil
    end
    local physicalIndex = target.exit.index
    local door = otherDoors[physicalIndex]
    if door.Name ~= target.exit.type then
        mismatch(state, "door-generation", { kind = "door", key = target.exit.type },
            { kind = "door", key = door.Name }, batch, currentRun)
        return nil
    end
    local marked = markRoomData(game, state, target, batch)
    if not marked then
        mismatch(state, "door-generation", { kind = "room", key = target.room.instructionId },
            { kind = "room", key = nil }, batch, currentRun)
        return nil
    end
    generation.generatedByIndex[physicalIndex] = true
    generation.count = generation.count + 1
    return marked
end

function session.routeNextRoom(state, currentRun, args, otherDoors, game)
    if not session.isOrdinaryDoorGenerationContact(state, args, otherDoors) then
        return { kind = "passThrough" }
    end
    local roomData = session.chooseNextRoom(state, currentRun, otherDoors, game)
    if roomData ~= nil then return { kind = "handled", roomData = roomData } end
    return { kind = "failed" }
end

function session.observeExit(state, currentRun, door)
    if state == nil or state.state ~= "active" then return end
    local current = roomInstruction(state, state.cursor)
    if not currentInstructionMatches(state, currentRun) then
        mismatch(state, "selected-exit", current and current.gameName or nil,
            roomName(currentRun and currentRun.CurrentRoom), current, currentRun)
        return
    end
    local batch = state.batchByParent[state.cursor]
    if not batch then
        local automatic = roomInstruction(state, expectedAutomaticSuccessor(state))
        local observed = roomName(door and door.Room)
        if automatic and observed == automatic.gameName then return end
        if isFinalCompiledCompletion(state, current) then
            state.state, state.reason = "inactive", "route-complete"
            return
        end
        mismatch(state, "selected-exit", automatic and automatic.gameName or nil, observed, current, currentRun)
        return
    end
    local generated = state.generation
    if not generated or generated.batchId ~= batch.id or generated.count ~= #batch.targets then
        mismatch(state, "door-generation", { kind = "batch", key = batch.id },
            { kind = "generated", key = generated and generated.count or nil }, batch, currentRun)
        return
    end
    local selected = targetForSelected(batch)
    local room = door and door.Room or nil
    local observedId = room and room.__runPlannerInstructionId or nil
    if not selected or observedId ~= selected.room.instructionId
        or (room and room.__runPlannerBatchId ~= batch.id)
        or (room and room.__runPlannerExitKey ~= selected.exit.exitKey)
        or (room and room.__runPlannerExitIndex ~= selected.exit.index)
        or (room and room.__runPlannerExitBehavior ~= selected.exit.behavior)
        or (door and door.Name ~= selected.exit.type) then
        mismatch(state, "selected-exit", { kind = "exit", key = selected and selected.exit.exitKey or nil },
            { kind = "exit", key = room and room.__runPlannerExitKey or nil }, batch, currentRun)
        return
    end
    state.cursor = selected.room.instructionId
    state.generation = nil
    if selected.exit.behavior == "automaticHostContinuation" then
        -- The host, not a player door decision, owns this continuation. Keep
        -- the cursor on its source until StartRoom observes the marked target.
        state.cursor = current.id
        state.pendingAutomaticTargetId = selected.room.instructionId
        state.pendingAutomaticContinuation = selected.continuation
        return
    end
    if selected.continuation == "startsCompletion" then state.completionPendingFrom = selected.room.instructionId end
end

function session.observeRoom(state, currentRun, room)
    if state == nil or state.state ~= "active" then return end
    -- Rehydration only re-projects the frozen cache. A diagnostic-only cache
    -- has no executable index and therefore cannot make a room observation.
    if type(state.instructionById) ~= "table" or state.cursor == nil then return end
    local expected = roomInstruction(state, state.cursor)
    if expected and roomName(room) == expected.gameName then return end
    local automatic = expectedAutomaticSuccessor(state)
    local nextInstruction = roomInstruction(state, automatic)
    local markedTargetId = room and room.__runPlannerInstructionId or nil
    local wasPendingAutomatic = state.pendingAutomaticTargetId ~= nil
    local pendingAutomaticMatches = not wasPendingAutomatic
        or markedTargetId == state.pendingAutomaticTargetId
    if nextInstruction and pendingAutomaticMatches and roomName(room) == nextInstruction.gameName then
        state.cursor = nextInstruction.id
        state.pendingAutomaticTargetId = nil
        if wasPendingAutomatic and state.pendingAutomaticContinuation == "startsCompletion" then
            state.completionPendingFrom = nextInstruction.id
        elseif not wasPendingAutomatic and state.completionPendingFrom ~= nil then
            state.completionPendingFrom = nil
        end
        state.pendingAutomaticContinuation = nil
        return
    end
    mismatch(state, "room-entry", expected and expected.gameName or nil, roomName(room), expected, currentRun)
end

function session.defineCache(moduleRef)
    moduleRef.cache.define({
        [session.CACHE_NAME] = {
            domain = "currentRun", key = "execution-session", factory = emptySession,
        },
    })
end

function session.get(runtime)
    return runtime.data.cache.currentRun.get(session.CACHE_NAME)
end

function session.publishStatus(runtime, state, host)
    if state == nil then return end
    local diagnostic = sessionStatus(state)
    if runtime and runtime.status and type(runtime.status.write) == "function" then
        runtime.status.write("ExecutionSessionStatus", diagnostic)
    end
    if host and type(host.log) == "function" and state.lastLoggedDiagnostic ~= diagnostic then
        host.log("%s", diagnostic)
        state.lastLoggedDiagnostic = diagnostic
    end
end

-- A source reload builds a new runtime status surface, while the active
-- CurrentRun keeps its cache bucket. Re-project the frozen session only; the
-- replaceable inbox is never consulted during lifecycle rehydration.
function session.rehydrateStatus(host, runtime)
    local state = session.get(runtime)
    if state and state.initialized then
        session.publishStatus(runtime, state, host)
    end
end

function session.registerLifecycle(moduleRef)
    moduleRef.onActivate(function(host, runtime)
        session.rehydrateStatus(host, runtime)
    end)
    moduleRef.onReload(function(host, runtime)
        session.rehydrateStatus(host, runtime)
    end)
end

function session.registerHooks(moduleRef, deps)
    moduleRef.hooks.wrap("ChooseStartingRoom", "execution-session-starting-room",
        function(host, runtime, base, currentRun, args)
        local state = session.get(runtime)
        if not state.initialized then initialize(state, host, deps.inbox, deps.game, currentRun, args) end
        local room = session.chooseStartingRoom(state, currentRun, args, deps.game)
        if room ~= nil then return room end
        return base(currentRun, args)
    end)
    moduleRef.hooks.wrap("StartNewRun", "execution-session-start", function(host, runtime, base, prevRun, args)
        local currentRun = base(prevRun, args)
        local state = session.get(runtime)
        if not state.initialized then initialize(state, host, deps.inbox, deps.game, currentRun, args) end
        if state.program ~= nil then
            refreshStartingContext(state, args, currentRun, currentRun and currentRun.CurrentRoom)
        end
        session.observeRoom(state, currentRun, currentRun and currentRun.CurrentRoom)
        session.publishStatus(runtime, state, host)
        return currentRun
    end)
    moduleRef.hooks.wrap("ChooseNextRoomData", "execution-session-exact-batch",
        function(host, runtime, base, currentRun, args, otherDoors)
        local state = session.get(runtime)
        local result = session.routeNextRoom(state, currentRun, args, otherDoors, deps.game)
        if result.kind == "handled" then return result.roomData end
        if result.kind == "failed" then
            session.publishStatus(runtime, state, host)
            return nil
        end
        return base(currentRun, args, otherDoors)
    end)
    moduleRef.hooks.wrap("DoUnlockRoomExits", "execution-session-batch-store",
        function(host, runtime, base, currentRun, room)
        local state = session.get(runtime)
        local result = session.prepareBatchRewardStore(state, currentRun)
        if result.kind == "failed" then
            session.publishStatus(runtime, state, host)
            return nil
        end
        return base(currentRun, room)
    end)
    moduleRef.hooks.wrap("ChooseRoomReward", "execution-session-target-reward",
        function(host, runtime, base, currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        local state = session.get(runtime)
        local result = session.chooseRoomReward(state, currentRun, room, rewardStoreName,
            previouslyChosenRewards, args, base)
        if result.kind == "passThrough" then
            return base(currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        end
        if result.kind == "failed" then
            session.publishStatus(runtime, state, host)
            return result.value
        end
        return result.value
    end)
    moduleRef.hooks.wrap("SetupRoomReward", "execution-session-target-reward-setup",
        function(host, runtime, base, currentRun, room, previouslyChosenRewards, args)
        local state = session.get(runtime)
        local result = session.setupRoomReward(state, currentRun, room, previouslyChosenRewards,
            args, base)
        if result.kind == "passThrough" then return base(currentRun, room, previouslyChosenRewards, args) end
        if result.kind == "failed" then
            session.publishStatus(runtime, state, host)
            return nil
        end
        return result.result
    end)
    moduleRef.hooks.wrap("EndCapturePointChallengeEncounter", "execution-session-anomaly-reward",
        function(host, runtime, base, encounter)
        local state = session.get(runtime)
        local currentRun = deps.game.CurrentRun or _G.CurrentRun
        local result = session.observeAnomalyReward(state, currentRun, encounter)
        if result.kind == "failed" then
            session.publishStatus(runtime, state, host)
        end
        return base(encounter)
    end)
    moduleRef.hooks.wrap("StartDevotionTest", "execution-session-devotion-choice",
        function(host, runtime, base, encounter, args)
        local result = base(encounter, args)
        local state = session.get(runtime)
        local currentRun = deps.game.CurrentRun or _G.CurrentRun
        local observed = session.observeDevotionSelection(state, currentRun, encounter)
        if observed.kind == "failed" then session.publishStatus(runtime, state, host) end
        return result
    end)
    moduleRef.hooks.wrap("LeaveRoom", "execution-session-selected-exit",
        function(host, runtime, base, currentRun, door)
        local state = session.get(runtime)
        session.observeExit(state, currentRun, door)
        session.publishStatus(runtime, state, host)
        return base(currentRun, door)
    end)
    moduleRef.hooks.wrap("StartRoom", "execution-session-observe",
        function(host, runtime, base, currentRun, currentRoom)
        local state = session.get(runtime)
        session.observeRoom(state, currentRun, currentRoom)
        session.publishStatus(runtime, state, host)
        return base(currentRun, currentRoom)
    end)
end

session.initialize = initialize
session.rewardExists = rewardExists
session.rewardContact = rewardContact
session.BIOME_ROUTE = BIOME_ROUTE
session.statusText = sessionStatus

return session
