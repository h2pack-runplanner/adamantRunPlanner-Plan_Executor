-- Slice 5 current-run execution session. This is deliberately an observation
-- boundary: it freezes an already-resolved route and never changes game data.

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

local function instructionOwner(instruction)
    return instruction and instruction.origin or nil
end

local function mismatch(state, checkpoint, expected, observed, instruction, currentRun)
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
        beforeApply = true,
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
    local instructionById, biomeByKey = {}, {}
    for _, instruction in ipairs(route.instructions) do instructionById[instruction.id] = instruction end
    for _, biome in ipairs(route.biomes) do biomeByKey[biome.biomeKey] = biome end
    return instructionById, biomeByKey
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
    state.instructionById, state.biomeByKey = indexes(route)
    state.cursor = selectedEntry(route, biomeKey)
    if not scanContact(game, route, state, currentRun) then return end
    state.state, state.reason = "active", nil
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

function session.observeStartingRoom(state, currentRun, room)
    if state == nil or state.state ~= "active" or state.startingRoomObserved then return end
    state.startingRoomObserved = true
    local instruction = state.instructionById[state.cursor]
    if not instruction or instruction.gameName == nil then return end
    local observed = room and (room.GenusName or room.Name) or nil
    if observed ~= instruction.gameName then
        mismatch(state, "starting-room", instruction.gameName, observed, instruction, currentRun)
    end
end

function session.registerHooks(moduleRef, deps)
    moduleRef.hooks.wrap("StartNewRun", "execution-session-start", function(host, runtime, base, prevRun, args)
        local currentRun = base(prevRun, args)
        local state = session.get(runtime)
        if not state.initialized then initialize(state, host, deps.inbox, deps.game, currentRun, args) end
        session.observeStartingRoom(state, currentRun, currentRun and currentRun.CurrentRoom)
        session.publishStatus(runtime, state, host)
        return currentRun
    end)
    moduleRef.hooks.wrap("StartRoom", "execution-session-observe",
        function(host, runtime, base, currentRun, currentRoom)
        local state = session.get(runtime)
        session.observeStartingRoom(state, currentRun, currentRoom)
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
