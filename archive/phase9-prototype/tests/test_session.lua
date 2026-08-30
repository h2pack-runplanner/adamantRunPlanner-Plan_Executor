-- luacheck: globals TestSession

local lu = require("luaunit")
local fixtures = require("tests/harness/fixture_loader")
local protocol = require("mods/protocol")
local session = require("mods/session")

TestSession = {}

local function routeFixture(name, routeKey)
    local value = fixtures.decode(name)
    local plan = assert(protocol.decode(value))
    return plan, assert(plan.routes[routeKey or "Underworld"])
end

local function contactGame(route)
    local game = {
        RoomData = {}, RewardStoreData = {}, StoreData = {}, RewardData = {}, LootData = {},
        ConsumableData = {}, TraitData = {}, EncounterData = {},
    }
    local function addPayload(offer)
        local payload = offer.payload
        if payload then
            if payload.source then game.LootData[payload.source] = {} end
            if payload.chosenSource then game.LootData[payload.chosenSource] = {} end
            if payload.spurnedSource then game.LootData[payload.spurnedSource] = {} end
        end
    end
    local function addDirectOffer(offer)
        game.LootData[offer.rewardType] = {}
        addPayload(offer)
    end
    local function addStoreOffer(storeKey, offer)
        game.RewardStoreData[storeKey] = game.RewardStoreData[storeKey] or {}
        table.insert(game.RewardStoreData[storeKey], { Name = offer.rewardType })
        addPayload(offer)
    end
    local function addShopOffer(profileKey, offer)
        game.StoreData[profileKey] = game.StoreData[profileKey] or { GroupsOf = { { OptionsData = {} } } }
        table.insert(game.StoreData[profileKey].GroupsOf[1].OptionsData, { Name = offer.rewardType })
        addPayload(offer)
    end
    for _, instruction in ipairs(route.instructions) do
        if instruction.gameName then
            game.RoomData[instruction.gameName] = game.RoomData[instruction.gameName] or { Name = instruction.gameName }
        end
        if instruction.anomalyReplacement then game.RoomData[instruction.anomalyReplacement.replacedRoomGameName] = {} end
        if instruction.enteredRewardStoreKey then
            game.RewardStoreData[instruction.enteredRewardStoreKey] = game.RewardStoreData[instruction.enteredRewardStoreKey] or {}
        end
        if instruction.resolvedSharedRewardStoreKey then
            game.RewardStoreData[instruction.resolvedSharedRewardStoreKey] =
                game.RewardStoreData[instruction.resolvedSharedRewardStoreKey] or {}
        end
        if instruction.incomingReward then
            local room = game.RoomData[instruction.gameName]
            if instruction.incomingReward.producerKind == "shop" then
                room.ForcedFirstReward = "Shop"
            elseif instruction.incomingReward.producerKind == "fixed"
                and instruction.incomingReward.offer.rewardType == "Story" then
                room.ForcedReward = "Story"
            end
            if instruction.incomingReward.resolvedStoreKey then
                addStoreOffer(instruction.incomingReward.resolvedStoreKey, instruction.incomingReward.offer)
            else
                addDirectOffer(instruction.incomingReward.offer)
            end
        end
        if instruction.shop then
            for _, item in ipairs(instruction.shop.offers) do
                addShopOffer(instruction.shop.profileKey, item.offer)
            end
        end
        for _, reward in ipairs(instruction.localRewards or {}) do
            addStoreOffer(reward.resolvedStoreKey, reward.offer)
        end
        for _, wheel in ipairs(instruction.rewardWheels or {}) do
            for _, item in ipairs(wheel.offers) do addStoreOffer(wheel.storeKey, item.offer) end
        end
        for _, phase in ipairs(instruction.encounterPhases or {}) do game.EncounterData[phase.encounterKey] = {} end
    end
    return game
end

local function newState()
    return { initialized = false, state = "inactive", reason = "not-started", context = {} }
end

local function start(state, plan, game, opts)
    opts = opts or {}
    local routeKey = opts.routeKey or "Underworld"
    local biome = opts.biome or (routeKey == "Surface" and "N" or "F")
    local route = plan.routes[routeKey]
    local entry = route.instructions[1]
    local currentRun = opts.currentRun or {
        Revision = "test-revision",
        CurrentRoom = { RoomSetName = biome, Name = entry.gameName },
    }
    local inbox = { load = function() return true, opts.decoded or plan end }
    session.initialize(state, opts.host, inbox, game, currentRun, opts.args or { StartingBiome = biome })
    return currentRun
end

function TestSession.testClosedBiomeMappingAndInactivePrecedence()
    lu.assertEquals(session.BIOME_ROUTE.F, "Underworld")
    lu.assertEquals(session.BIOME_ROUTE.I, "Underworld")
    lu.assertEquals(session.BIOME_ROUTE.N, "Surface")
    lu.assertEquals(session.BIOME_ROUTE.Q, "Surface")
    local plan, route = routeFixture("representative-f")
    local cases = {
        { name = "disabled", host = { isEnabled = function() return false end }, reason = "module-disabled" },
        { name = "dream", currentRun = { IsDreamRun = true, CurrentRoom = { RoomSetName = "F" } }, reason = "dream-run" },
        { name = "unknown", biome = "X", reason = "unknown-route" },
        { name = "project", decoded = { kind = "project-only" }, reason = "project-only" },
        { name = "unavailable", decoded = nil, reason = "bundle-unavailable" },
        { name = "unconfigured", routeKey = "Surface", biome = "N", reason = "unconfigured-route" },
    }
    for _, case in ipairs(cases) do
        local state = newState()
        local game = contactGame(route)
        local decoded = case.decoded
        if case.name == "unavailable" then
            session.initialize(state, case.host, { load = function() return false end }, game,
                case.currentRun or { CurrentRoom = { RoomSetName = case.biome or "F" } }, { StartingBiome = case.biome or "F" })
        elseif case.name == "unconfigured" then
            session.initialize(state, case.host, { load = function() return true, plan end }, game,
                { CurrentRoom = { RoomSetName = "N" } }, { StartingBiome = "N" })
        else
            start(state, plan, game, case)
        end
        lu.assertEquals(state.state, "inactive", case.name)
        lu.assertEquals(state.reason, case.reason, case.name)
        lu.assertNil(state.firstMismatch, case.name)
    end
end

function TestSession.testFreezesProgramAndUsesMatchingBiomeEntry()
    local plan, route = routeFixture("complete-underworld")
    local state = newState()
    local game = contactGame(route)
    local currentRun = start(state, plan, game, { biome = "G", args = { StartingBiome = "" } })
    lu.assertEquals(state.state, "active", state.firstMismatch and state.firstMismatch.expected.key or "")
    lu.assertEquals(state.cursor, state.biomeByKey.G.entryInstructionId)
    local frozen = state.program
    local replacement = { load = function() error("must not reload after cache initialization") end }
    session.initialize(state, nil, replacement, game, currentRun, { StartingBiome = "F" })
    lu.assertEquals(state.program, frozen)
    lu.assertEquals(state.cursor, state.biomeByKey.G.entryInstructionId)
end

function TestSession.testPositiveVectorsAndEveryContactFamily()
    for _, spec in ipairs({ { "representative-f", "Underworld" }, { "complete-underworld", "Underworld" }, { "two-route-stress", "Underworld" }, { "two-route-stress", "Surface" } }) do
        local plan, route = routeFixture(spec[1], spec[2])
        local state = newState()
        start(state, plan, contactGame(route), { routeKey = spec[2] })
        lu.assertEquals(state.state, "active", spec[1] .. ":" .. spec[2] .. ":" .. tostring(state.firstMismatch and state.firstMismatch.expected.key))
    end
    local game = { RewardData = {}, LootData = {}, ConsumableData = {}, TraitData = {}, RewardStoreData = {
        Store = { { Name = "Story" }, { Name = "InfernalContractBoon" }, { Name = "TrialUpgrade" }, { Name = "Devotion" } },
    }, StoreData = { ShopProfile = { GroupsOf = { { OptionsData = { { Name = "Shop" } } } } } } }
    for _, key in ipairs({ "Boon", "MaxHealthDrop", "GiftDrop" }) do game.LootData[key] = {} end
    lu.assertTrue(session.rewardExists(game, "Boon"))
    lu.assertTrue(session.rewardExists(game, "MaxHealthDrop"))
    lu.assertTrue(session.rewardExists(game, "GiftDrop"))
    lu.assertTrue(session.rewardExists(game, "Story", "Store"))
    lu.assertTrue(session.rewardExists(game, "InfernalContractBoon", "Store"))
    lu.assertTrue(session.rewardExists(game, "TrialUpgrade", "Store"))
    lu.assertTrue(session.rewardExists(game, "Devotion", "Store"))
    lu.assertTrue(session.rewardExists(game, "Shop", nil, "ShopProfile"))
end

function TestSession.testMissingContactDesynchronizesOnceAndRecordsTruthfulFields()
    local plan, route = routeFixture("representative-f")
    local game = contactGame(route)
    game.EncounterData.BossHecate01 = nil
    local state = newState()
    local currentRun = start(state, plan, game)
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.reason, "live-contact-failure")
    lu.assertEquals(state.firstMismatch.catalogVersion, plan.catalogVersion)
    lu.assertEquals(state.firstMismatch.gameVersion, "test-revision")
    lu.assertEquals(state.firstMismatch.beforeApply, true)
    local first = state.firstMismatch
    session.observeRoom(state, currentRun, { Name = "wrong" })
    lu.assertEquals(state.firstMismatch, first)
end

function TestSession.testEveryReferencedContactFamilyFailsClosed()
    local plan, route = routeFixture("two-route-stress")
    local surfaceRoute = plan.routes.Surface
    local function instruction(predicate)
        for _, item in ipairs(route.instructions) do if predicate(item) then return item end end
        error("fixture did not carry expected contact family")
    end
    local room = instruction(function(item) return item.gameName end)
    local anomaly = instruction(function(item) return item.anomalyReplacement end)
    local incoming = instruction(function(item) return item.incomingReward and item.incomingReward.resolvedStoreKey end)
    local batch = instruction(function(item) return item.kind == "batch" and item.resolvedSharedRewardStoreKey end)
    local localReward = instruction(function(item) return item.localRewards and #item.localRewards > 0 end)
    local completion = instruction(function(item) return item.enteredRewardStoreKey end)
    local shop = instruction(function(item) return item.shop end)
    local reward = instruction(function(item)
        return item.incomingReward and type(item.incomingReward.resolvedStoreKey) ~= "string"
    end)
    local source = instruction(function(item)
        return item.incomingReward and item.incomingReward.offer.payload and item.incomingReward.offer.payload.source
    end)
    local encounter = instruction(function(item) return #item.encounterPhases > 0 end)
    local cases = {
        { "room", function(game) game.RoomData[room.gameName] = nil end },
        { "anomaly", function(game) game.RoomData[anomaly.anomalyReplacement.replacedRoomGameName] = nil end },
        { "incoming-store", function(game) game.RewardStoreData[incoming.incomingReward.resolvedStoreKey] = nil end },
        { "batch-store", function(game) game.RewardStoreData[batch.resolvedSharedRewardStoreKey] = nil end },
        { "local-store", function(game) game.RewardStoreData[localReward.localRewards[1].resolvedStoreKey] = nil end },
        { "completion-store", function(game) game.RewardStoreData[completion.enteredRewardStoreKey] = nil end },
        { "shop", function(game) game.StoreData[shop.shop.profileKey] = nil end },
        { "reward", function(game) game.LootData[reward.incomingReward.offer.rewardType] = nil end },
        { "loot-source", function(game) game.LootData[source.incomingReward.offer.payload.source] = nil end },
        { "encounter", function(game) game.EncounterData[encounter.encounterPhases[1].encounterKey] = nil end },
    }
    for _, case in ipairs(cases) do
        local game, state = contactGame(route), newState()
        case[2](game)
        start(state, plan, game)
        lu.assertEquals(state.state, "desynchronized", case[1])
        lu.assertNotNil(state.firstMismatch, case[1])
    end
    -- Wheels are a Surface product in the producer stress vector; the same
    -- existence-only store contact rule applies to their resolved store key.
    local wheel = nil
    for _, item in ipairs(surfaceRoute.instructions) do
        if item.rewardWheels and #item.rewardWheels > 0 then wheel = item break end
    end
    local game, state = contactGame(surfaceRoute), newState()
    game.RewardStoreData[wheel.rewardWheels[1].storeKey] = nil
    start(state, plan, game, { routeKey = "Surface", biome = "N" })
    lu.assertEquals(state.state, "desynchronized", "wheel-store")
end

function TestSession.testGlobalRewardIdentityCannotBypassResolvedStoreOrShopMembership()
    local plan, underworld = routeFixture("two-route-stress")
    local surface = plan.routes.Surface
    local function find(route, predicate)
        for _, item in ipairs(route.instructions) do if predicate(item) then return item end end
        error("fixture did not carry requested offer")
    end
    local incoming = find(underworld, function(item)
        return item.incomingReward and item.incomingReward.resolvedStoreKey
    end)
    local localRoom = find(underworld, function(item) return item.localRewards and #item.localRewards > 0 end)
    local shopRoom = find(underworld, function(item) return item.shop end)
    local wheelRoom = find(surface, function(item) return item.rewardWheels and #item.rewardWheels > 0 end)
    local function removeStoreOffer(game, key, rewardType)
        local store = game.RewardStoreData[key]
        for index = #store, 1, -1 do
            if store[index].Name == rewardType then table.remove(store, index) end
        end
    end
    local function removeShopOffer(game, key, rewardType)
        local offers = game.StoreData[key].GroupsOf[1].OptionsData
        for index = #offers, 1, -1 do
            if offers[index].Name == rewardType then table.remove(offers, index) end
        end
    end
    local cases = {
        {
            route = underworld, routeKey = "Underworld", offer = incoming.incomingReward.offer,
            remove = function(game, offer) removeStoreOffer(game, incoming.incomingReward.resolvedStoreKey, offer.rewardType) end,
        },
        {
            route = underworld, routeKey = "Underworld", offer = localRoom.localRewards[1].offer,
            remove = function(game, offer) removeStoreOffer(game, localRoom.localRewards[1].resolvedStoreKey, offer.rewardType) end,
        },
        {
            route = underworld, routeKey = "Underworld", offer = shopRoom.shop.offers[1].offer,
            remove = function(game, offer) removeShopOffer(game, shopRoom.shop.profileKey, offer.rewardType) end,
        },
        {
            route = surface, routeKey = "Surface", biome = "N", offer = wheelRoom.rewardWheels[1].offers[1].offer,
            remove = function(game, offer) removeStoreOffer(game, wheelRoom.rewardWheels[1].storeKey, offer.rewardType) end,
        },
    }
    for _, case in ipairs(cases) do
        local game, state = contactGame(case.route), newState()
        game.LootData[case.offer.rewardType] = {}
        case.remove(game, case.offer)
        start(state, plan, game, { routeKey = case.routeKey, biome = case.biome })
        lu.assertEquals(state.state, "desynchronized", case.routeKey)
        lu.assertEquals(state.firstMismatch.expected.kind, "reward")
    end
end

function TestSession.testExplicitStoreAndShopCannotFallBackToConflictingRoomDeclarations()
    local game = {
        RewardData = {}, LootData = {}, ConsumableData = {}, TraitData = {},
        RewardStoreData = { Explicit = {}, RoomStore = { { Name = "Story" } } },
        StoreData = {
            ExplicitShop = { GroupsOf = { { OptionsData = {} } } },
            RoomShop = { GroupsOf = { { OptionsData = { { Name = "Story" } } } } },
        },
    }
    local room = { RewardStoreName = "RoomStore", StoreDataName = "RoomShop" }
    lu.assertFalse(session.rewardExists(game, "Story", "Explicit", nil, room))
    lu.assertFalse(session.rewardExists(game, "Story", nil, "ExplicitShop", room))
    lu.assertTrue(session.rewardExists(game, "Story", nil, nil, room))
end

function TestSession.testIncomingProducerKindsUseTheirOwnLiveContact()
    local representativePlan, representative = routeFixture("representative-f")
    local completePlan, complete = routeFixture("complete-underworld")
    local stressPlan, underworld = routeFixture("two-route-stress")
    local surface = stressPlan.routes.Surface
    local function find(route, predicate)
        for _, item in ipairs(route.instructions) do
            if item.incomingReward and predicate(item.incomingReward, item) then return item end
        end
        error("fixture did not carry requested incoming producer")
    end
    local function removeStoreOffer(game, key, rewardType)
        local store = game.RewardStoreData[key]
        for index = #store, 1, -1 do
            if store[index].Name == rewardType then table.remove(store, index) end
        end
    end

    local fShop = find(representative, function(reward, item)
        return item.gameName == "F_PreBoss01" and reward.producerKind == "shop"
    end)
    local shopGame = contactGame(representative)
    removeStoreOffer(shopGame, fShop.incomingReward.resolvedStoreKey, "Shop")
    local shopState = newState()
    start(shopState, representativePlan, shopGame)
    lu.assertEquals(shopState.state, "active")
    shopGame.RoomData.F_PreBoss01.ForcedFirstReward = nil
    local removedShopState = newState()
    start(removedShopState, representativePlan, shopGame)
    lu.assertEquals(removedShopState.state, "desynchronized")
    shopGame.RoomData.F_PreBoss01.ForcedFirstReward = "NotShop"
    local missingShopState = newState()
    start(missingShopState, representativePlan, shopGame)
    lu.assertEquals(missingShopState.state, "desynchronized")

    local story = find(complete, function(reward) return reward.producerKind == "fixed" and reward.offer.rewardType == "Story" end)
    local storyGame = contactGame(complete)
    removeStoreOffer(storyGame, story.incomingReward.resolvedStoreKey, "Story")
    local storyState = newState()
    start(storyState, completePlan, storyGame)
    lu.assertEquals(storyState.state, "active")
    storyGame.RoomData[story.gameName].ForcedReward = nil
    local removedStoryState = newState()
    start(removedStoryState, completePlan, storyGame)
    lu.assertEquals(removedStoryState.state, "desynchronized")
    storyGame.RoomData[story.gameName].ForcedReward = "NotStory"
    local missingStoryState = newState()
    start(missingStoryState, completePlan, storyGame)
    lu.assertEquals(missingStoryState.state, "desynchronized")

    local counted = find(representative, function(reward) return reward.producerKind == "countedChoice" end)
    local free = find(representative, function(reward) return reward.producerKind == "freeReward" end)
    for _, item in ipairs({ counted, free }) do
        local game = contactGame(representative)
        local reward = item.incomingReward
        removeStoreOffer(game, reward.resolvedStoreKey, reward.offer.rewardType)
        game.LootData[reward.offer.rewardType] = {}
        game.RoomData[item.gameName].ForcedReward = reward.offer.rewardType
        local state = newState()
        start(state, representativePlan, game)
        lu.assertEquals(state.state, "desynchronized", reward.producerKind)
    end

    local devotion = find(surface, function(reward) return reward.producerKind == "fixed" and reward.offer.rewardType == "Devotion" end)
    local devotionGame, devotionState = contactGame(surface), newState()
    start(devotionState, stressPlan, devotionGame, { routeKey = "Surface", biome = "N" })
    lu.assertEquals(devotionState.state, "active")
    lu.assertTrue(session.rewardContact(devotionGame, devotion.incomingReward.offer, "fixed",
        devotion.incomingReward.resolvedStoreKey, nil, devotionGame.RoomData[devotion.gameName]))
    local chaos = find(underworld, function(reward) return reward.producerKind == "fixed" and reward.offer.rewardType == "TrialUpgrade" end)
    local contract = find(underworld, function(reward) return reward.producerKind == "fixed" and reward.offer.rewardType == "InfernalContractBoon" end)
    local fixedGame = contactGame(underworld)
    lu.assertTrue(session.rewardContact(fixedGame, chaos.incomingReward.offer, "fixed", nil, nil,
        fixedGame.RoomData[chaos.gameName]))
    lu.assertTrue(session.rewardContact(fixedGame, contract.incomingReward.offer, "fixed", nil, nil,
        fixedGame.RoomData[contract.gameName]))
    lu.assertFalse(session.rewardContact({ RewardData = { Boon = {} } }, { rewardType = "Boon" }, "shop", nil, nil,
        { ForcedFirstReward = "Shop" }))
end

function TestSession.testStatusIsACacheDerivedDiagnosticOnly()
    local written = {}
    session.publishStatus({ status = { write = function(alias, value) written.alias, written.value = alias, value end } }, {
        state = "active", reason = nil, routeKey = "Underworld",
    })
    lu.assertEquals(written.alias, "ExecutionSessionStatus")
    lu.assertStrContains(written.value, "active")
    lu.assertStrContains(written.value, "Underworld")
end

function TestSession.testDiagnosticRendersActiveInactiveAndBothMismatchShapes()
    local active = session.statusText({
        state = "active", reason = nil, routeKey = "Underworld", cursor = "i0",
        planFingerprint = "plan000000000001", routeFingerprint = "route00000000001",
        catalogVersion = "catalog-test", context = { gameVersion = "r1", startingBiome = "F", roomSetName = "F", roomName = "F_Opening01" },
    })
    lu.assertStrContains(active, "state=active")
    lu.assertStrContains(active, "cursor=i0")
    lu.assertStrContains(active, "startingRoom=F_Opening01")
    local inactive = session.statusText({ state = "inactive", reason = "dream-run", context = {} })
    lu.assertStrContains(inactive, "reason=dream-run")
    local live = session.statusText({
        state = "desynchronized", reason = "live-contact-failure", routeKey = "Surface", cursor = "i7",
        firstMismatch = {
            checkpoint = "live-contact", instructionId = "i7", gameVersion = "r2",
            beforeApply = false,
            expected = { kind = "encounter", key = "MissingEncounter" },
            observed = { kind = "encounter", key = nil },
            instructionOwner = { kind = "occurrence", routeKey = "Surface", biomeKey = "N", occurrenceId = "o1" },
        }, context = {},
    })
    lu.assertStrContains(live, "checkpoint=live-contact")
    lu.assertStrContains(live, "beforeApply=false")
    lu.assertStrContains(live, "expected.kind=encounter")
    lu.assertStrContains(live, "expected.key=MissingEncounter")
    lu.assertStrContains(live, "observed.key=none")
    lu.assertStrContains(live, "origin.occurrence=o1")
    local starting = session.statusText({
        state = "desynchronized", reason = "live-contact-failure", firstMismatch = {
            checkpoint = "starting-room", beforeApply = true,
            expected = "F_Opening01", observed = "WrongRoom",
        }, context = {},
    })
    lu.assertStrContains(starting, "expected.value=F_Opening01")
    lu.assertStrContains(starting, "observed.value=WrongRoom")
    lu.assertStrContains(starting, "beforeApply=true")
end

function TestSession.testDiagnosticProjectsDecodedExitDecisionOriginSource()
    local _, route = routeFixture("representative-f")
    local batch
    for _, instruction in ipairs(route.instructions) do
        if instruction.kind == "batch" then batch = instruction break end
    end
    lu.assertEquals(batch.origin.kind, "exitDecision")
    local source = batch.origin.source
    local diagnostic = session.statusText({
        state = "desynchronized", reason = "live-contact-failure",
        firstMismatch = { instructionOwner = batch.origin }, context = {},
    })
    lu.assertStrContains(diagnostic, "origin.source.kind=" .. source.kind)
    lu.assertStrContains(diagnostic, "origin.source.occurrence=" .. tostring(source.occurrenceId or "none"))
    lu.assertStrContains(diagnostic, "origin.source.decision=" .. tostring(source.decisionKey or "none"))
end

function TestSession.testDiagnosticWritesUiStatusAndLogsOnlyOnTransition()
    local writes, logs = {}, {}
    local runtime = { status = { write = function(alias, value) writes[#writes + 1] = { alias, value } end } }
    local host = { log = function(format, value) logs[#logs + 1] = string.format(format, value) end }
    local state = { state = "active", reason = nil, routeKey = "Underworld", cursor = "i0", context = {} }
    session.publishStatus(runtime, state, host)
    session.publishStatus(runtime, state, host)
    lu.assertEquals(#writes, 2)
    lu.assertEquals(#logs, 1)
    lu.assertEquals(writes[1][2], logs[1])
    state.state, state.reason = "inactive", "module-disabled"
    session.publishStatus(runtime, state, host)
    lu.assertEquals(#logs, 2)
    lu.assertStrContains(logs[2], "reason=module-disabled")
end

function TestSession.testCacheAndKeyedHooksPassThroughWithoutGameWrites()
    local defined, hooks = nil, {}
    local module = {
        cache = { define = function(value) defined = value end },
        hooks = { wrap = function(path, key, callback) hooks[path] = { key = key, callback = callback } end },
    }
    session.defineCache(module)
    session.registerHooks(module, { inbox = { load = function() return true, routeFixture("representative-f") end }, game = {} })
    lu.assertEquals(defined.ExecutionSession.domain, "currentRun")
    lu.assertEquals(hooks.StartNewRun.key, "execution-session-start")
    lu.assertEquals(hooks.StartRoom.key, "execution-session-observe")
    lu.assertEquals(hooks.ChooseStartingRoom.key, "execution-session-starting-room")
    lu.assertEquals(hooks.ChooseNextRoomData.key, "execution-session-exact-batch")
    lu.assertEquals(hooks.LeaveRoom.key, "execution-session-selected-exit")
    local bucket = newState()
    local runtime = { data = { cache = { currentRun = { get = function(name) lu.assertEquals(name, session.CACHE_NAME); return bucket end } } } }
    local currentRun = { CurrentRoom = { RoomSetName = "F", Name = "unchanged" } }
    local result = hooks.StartNewRun.callback({ isEnabled = function() return false end }, runtime,
        function(prev, args) lu.assertNil(prev); lu.assertEquals(args.StartingBiome, "F"); return currentRun end, nil, { StartingBiome = "F" })
    lu.assertEquals(result, currentRun)
    lu.assertEquals(currentRun.CurrentRoom.Name, "unchanged")
    local first, second = hooks.StartRoom.callback(nil, runtime, function(run, room)
        lu.assertEquals(run, currentRun); lu.assertEquals(room.Name, "unchanged"); return "a", "b"
    end, currentRun, currentRun.CurrentRoom)
    lu.assertEquals(first, "a"); lu.assertEquals(second, "b")
end

function TestSession.testOnlyExactOrdinaryDoorGenerationIsOwnedAndMismatchNeverFallsBack()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local hooks = {}
    session.registerHooks({ hooks = { wrap = function(path, _key, callback) hooks[path] = callback end } },
        { inbox = { load = function() return true, plan end }, game = game })
    local writes, logs = {}, {}
    local runtime = {
        data = { cache = { currentRun = { get = function() return state end } } },
        status = { write = function(_, value) writes[#writes + 1] = value end },
    }
    local host = { log = function(format, value) logs[#logs + 1] = string.format(format, value) end }
    local baseCalls = 0
    local function base(_, args, otherDoors)
        baseCalls = baseCalls + 1
        return { args = args, otherDoors = otherDoors, vanilla = true }
    end
    for _, args in ipairs({ {}, { ForceNextRoom = "Chaos_01" }, { ForceNextRoomSet = "Anomaly" } }) do
        local otherDoors = args.ForceNextRoomSet and { { Name = "WrongDoor" } } or nil
        local result = hooks.ChooseNextRoomData(host, runtime, base, currentRun, args, otherDoors)
        lu.assertTrue(result.vanilla)
        lu.assertEquals(result.args, args)
        lu.assertEquals(result.otherDoors, otherDoors)
        lu.assertNil(state.generation)
    end
    local result = hooks.ChooseNextRoomData(host, runtime, base, currentRun, {}, { { Name = "WrongDoor" } })
    lu.assertNil(result)
    lu.assertEquals(baseCalls, 3)
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(#writes, 1)
    lu.assertEquals(#logs, 1)
    lu.assertStrContains(writes[1], "state=desynchronized")
    session.publishStatus(runtime, state, host)
    lu.assertEquals(#writes, 2)
    lu.assertEquals(#logs, 1)
end

function TestSession.testExactStartingRoomBypassesEligibilityAndUsesCompiledEntryOnly()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    game.RoomData[route.instructions[1].gameName].RoomSetName = "F"
    local created = {}
    game.CreateRoom = function(roomData, args)
        created.roomData, created.args = roomData, args
        return { Name = roomData.Name, RoomSetName = roomData.RoomSetName }
    end
    local currentRun = { Revision = "test-revision" }
    local inbox = { load = function() return true, plan end }
    session.initialize(state, nil, inbox, game, currentRun, { StartingBiome = "F" })
    lu.assertNil(state.context.roomName)
    local result = session.chooseStartingRoom(state, currentRun, { StartingBiome = "F" }, game)
    lu.assertEquals(result.Name, route.instructions[1].gameName)
    lu.assertEquals(created.roomData.Name, game.RoomData[route.instructions[1].gameName].Name)
    lu.assertEquals(created.roomData.__runPlannerInstructionId, route.instructions[1].id)
    lu.assertTrue(created.roomData.__runPlannerStartingRoom)
    lu.assertEquals(created.args.StartingBiome, "F")
    lu.assertEquals(state.context.roomSetName, "F")
    lu.assertEquals(state.context.roomName, route.instructions[1].gameName)
end

function TestSession.testStartingAndPhysicalRewardContactsUseCompiledTypesAndSources()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    game.CreateRoom = function(roomData) return roomData end
    local currentRun = start(state, plan, game)
    currentRun.RewardPriorities = {}
    local starting = assert(session.chooseStartingRoom(state, currentRun, { StartingBiome = "F" }, game))
    local chosen = session.chooseRoomReward(state, currentRun, starting, "RunProgress", nil, nil,
        function(_, room) return { Name = "Boon", room = room } end)
    lu.assertEquals(chosen.value.Name, "Boon")
    starting.ChosenRewardType = "Boon"
    lu.assertEquals(starting.ForceLootName, "ApolloUpgrade")
    local setup = session.setupRoomReward(state, currentRun, starting, nil, nil, function(_, room)
        lu.assertEquals(room.ForceLootName, "ApolloUpgrade")
        return "vanilla-setup"
    end)
    lu.assertEquals(setup.result, "vanilla-setup")

    local batch = state.batchByParent[state.cursor]
    local door = { Name = batch.targets[1].exit.type }
    local target = session.chooseNextRoom(state, currentRun, { door }, game)
    door.Room = target
    currentRun.RewardPriorities = { "GiftDrop", "ExistingPriority" }
    local targetChoice = session.chooseRoomReward(state, currentRun, target,
        target.__runPlannerBatchId == batch.id and "MetaProgress" or "wrong", {}, { Door = door },
        function(run, room)
            lu.assertEquals(run.RewardPriorities[1], "GiftDrop")
            table.remove(run.RewardPriorities, 1)
            return room.__runPlannerInstructionId == batch.targets[1].room.instructionId and "GiftDrop"
        end)
    lu.assertEquals(targetChoice.value, "GiftDrop")
    lu.assertEquals(currentRun.RewardPriorities, { "GiftDrop", "ExistingPriority" })
    local ok = pcall(session.chooseRoomReward, state, currentRun, target, "MetaProgress", {}, { Door = door },
        function(run)
            lu.assertEquals(run.RewardPriorities[1], "GiftDrop")
            table.remove(run.RewardPriorities, 1)
            error("base failure")
        end)
    lu.assertFalse(ok)
    lu.assertEquals(currentRun.RewardPriorities, { "GiftDrop", "ExistingPriority" })
    lu.assertEquals(state.state, "active")
    local wrongSource = session.setupRoomReward(state, currentRun, starting, nil, nil, function(_, room)
        room.ForceLootName = "WrongUpgrade"
    end)
    lu.assertEquals(wrongSource.kind, "failed")
    lu.assertEquals(state.firstMismatch.checkpoint, "reward-source")
    lu.assertFalse(state.firstMismatch.beforeApply)
end

function TestSession.testCompiledStoreIsSetForEveryAlternatingBatch()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local first = state.batchByParent[state.cursor]
    lu.assertEquals(first.resolvedSharedRewardStoreKey, "MetaProgress")
    lu.assertEquals(session.prepareBatchRewardStore(state, currentRun).kind, "handled")
    lu.assertEquals(currentRun.NextRewardStoreName, "MetaProgress")
    local firstTarget = first.targets[1]
    state.cursor = firstTarget.room.instructionId
    currentRun.CurrentRoom = { Name = state.instructionById[state.cursor].gameName }
    local second = state.batchByParent[state.cursor]
    lu.assertEquals(second.resolvedSharedRewardStoreKey, "RunProgress")
    lu.assertEquals(session.prepareBatchRewardStore(state, currentRun).kind, "handled")
    lu.assertEquals(currentRun.NextRewardStoreName, "RunProgress")
end

function TestSession.testDevotionAndLocalCageRewardsCarryExactCompiledContacts()
    local plan, route = routeFixture("two-route-stress", "Surface")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game, { routeKey = "Surface", biome = "N" })
    local devotion
    for _, instruction in ipairs(route.instructions) do
        if instruction.incomingReward and instruction.incomingReward.offer.rewardType == "Devotion" then
            devotion = instruction
            break
        end
    end
    local parent = nil
    for parentId, batch in pairs(state.batchByParent) do
        for _, target in ipairs(batch.targets) do
            if target.room.instructionId == devotion.id then parent = parentId; break end
        end
        if parent then break end
    end
    state.cursor = parent
    currentRun.CurrentRoom = { Name = state.instructionById[parent].gameName }
    local batch = state.batchByParent[parent]
    local doors, generated = {}, {}
    for index, target in ipairs(batch.targets) do doors[index] = { Name = target.exit.type } end
    for _ = 1, #batch.targets do
        local room = session.chooseNextRoom(state, currentRun, doors, game)
        generated[room.__runPlannerInstructionId] = room
    end
    local room, door = generated[devotion.id], doors[1]
    for _, candidate in ipairs(batch.targets) do
        if candidate.room.instructionId == devotion.id then door = doors[candidate.exit.index] end
    end
    door.Room = room
    local choice = session.chooseRoomReward(state, currentRun, room, "RunProgress", {}, { Door = door },
        function() return "Devotion" end)
    lu.assertEquals(choice.value, "Devotion")
    room.ChosenRewardType = "Devotion"
    session.setupRoomReward(state, currentRun, room, nil, { Door = door }, function(_, setupRoom)
        setupRoom.Encounter = { LootAName = "wrong-a", LootBName = "wrong-b" }
    end)
    lu.assertEquals(room.Encounter.LootAName, "AresUpgrade")
    lu.assertEquals(room.Encounter.LootBName, "HephaestusUpgrade")
    state.cursor = devotion.id
    currentRun.CurrentRoom = room
    room.Encounter.ChosenGodName = "AresUpgrade"
    room.Encounter.SpurnedGodName = "HephaestusUpgrade"
    lu.assertEquals(session.observeDevotionSelection(state, currentRun, room.Encounter).kind, "handled")
    room.Encounter.ChosenGodName = "HephaestusUpgrade"
    room.Encounter.SpurnedGodName = "AresUpgrade"
    lu.assertEquals(session.observeDevotionSelection(state, currentRun, room.Encounter).kind, "failed")
    lu.assertEquals(state.firstMismatch.checkpoint, "devotion-choice")
    lu.assertFalse(state.firstMismatch.beforeApply)

    local underworldPlan, underworld = routeFixture("complete-underworld")
    local hGame, hState = contactGame(underworld), newState()
    local hRun = start(hState, underworldPlan, hGame)
    local localInstruction
    for _, instruction in ipairs(underworld.instructions) do
        if instruction.localRewards and #instruction.localRewards > 0 then localInstruction = instruction; break end
    end
    local hParent
    for parentId, hBatch in pairs(hState.batchByParent) do
        for _, target in ipairs(hBatch.targets) do
            if target.room.instructionId == localInstruction.id then hParent = parentId; break end
        end
        if hParent then break end
    end
    hState.cursor = hParent
    hRun.CurrentRoom = { Name = hState.instructionById[hParent].gameName }
    local hBatch, hDoor = hState.batchByParent[hParent], nil
    local hDoors = {}
    for index, target in ipairs(hBatch.targets) do hDoors[index] = { Name = target.exit.type } end
    local hRoom
    for _ = 1, #hBatch.targets do
        local generatedRoom = session.chooseNextRoom(hState, hRun, hDoors, hGame)
        if generatedRoom.__runPlannerInstructionId == localInstruction.id then hRoom = generatedRoom end
    end
    for _, target in ipairs(hBatch.targets) do
        if target.room.instructionId == localInstruction.id then hDoor = hDoors[target.exit.index] end
    end
    hDoor.Room = hRoom
    lu.assertEquals(session.chooseRoomReward(hState, hRun, hRoom, "RunProgress", {}, { Door = hDoor },
        function() return nil end).kind, "handled")
    local cage = {}
    for key, value in pairs(hRoom) do cage[key] = value end
    hRun.RewardPriorities = {}
    local localChoice = session.chooseRoomReward(hState, hRun, cage, "RunProgress", {}, nil,
        function(run)
            lu.assertEquals(run.RewardPriorities[1], "MaxHealthDrop")
            table.remove(run.RewardPriorities, 1)
            return "MaxHealthDrop"
        end)
    lu.assertEquals(localChoice.value, "MaxHealthDrop")
    cage.ChosenRewardType = "MaxHealthDrop"
    lu.assertEquals(session.setupRoomReward(hState, hRun, cage, nil, { Door = hDoor }, function()
        return "local-setup"
    end).result, "local-setup")
    local staleCage = {}
    for key, value in pairs(cage) do staleCage[key] = value end
    staleCage.__runPlannerExitType = "WrongDoor"
    local consumed = hState.localRewardCounts[localInstruction.id]
    local baseCalled = false
    local stale = session.chooseRoomReward(hState, hRun, staleCage, "RunProgress", {}, nil,
        function() baseCalled = true; return "MaxManaDrop" end)
    lu.assertEquals(stale.kind, "failed")
    lu.assertFalse(baseCalled)
    lu.assertEquals(hState.localRewardCounts[localInstruction.id], consumed)
    lu.assertEquals(hState.state, "desynchronized")
    lu.assertEquals(hState.firstMismatch.checkpoint, "reward-marker")
    lu.assertTrue(hState.firstMismatch.beforeApply)
    lu.assertEquals(hState.firstMismatch.expected, { kind = "exitType", key = hDoor.Name })
    lu.assertEquals(hState.firstMismatch.observed, { kind = "exitType", key = "WrongDoor" })
end

function TestSession.testAnomalyAcquisitionContactObservesBothOutcomesWithoutPolicyRepair()
    local plan, route = routeFixture("two-route-stress")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local anomaly
    for _, instruction in ipairs(route.instructions) do
        if instruction.anomalyReplacement then anomaly = instruction; break end
    end
    state.cursor = anomaly.id
    currentRun.CurrentRoom = { Name = anomaly.gameName, __runPlannerInstructionId = anomaly.id }
    lu.assertEquals(session.observeAnomalyReward(state, currentRun, { CapturePointProgress = 100 }).kind, "handled")
    anomaly.incomingReward.acquisitionEnabled = false
    lu.assertEquals(session.observeAnomalyReward(state, currentRun, { CapturePointProgress = 100 }).kind, "failed")
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "anomaly-reward")
    lu.assertFalse(state.firstMismatch.beforeApply)
end

function TestSession.testFixedFreeAndUnpickedPhysicalOffersKeepVanillaBagContacts()
    local plan, route = routeFixture("complete-underworld")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local prebossBatch
    for _, batch in pairs(state.batchByParent) do
        if #batch.targets == 2 then
            local kinds = {}
            for _, target in ipairs(batch.targets) do
                local reward = state.instructionById[target.room.instructionId].incomingReward
                if reward then kinds[reward.producerKind] = true end
            end
            if kinds.shop and kinds.freeReward then prebossBatch = batch; break end
        end
    end
    state.cursor = prebossBatch.parent.instructionId
    currentRun.CurrentRoom = { Name = state.instructionById[state.cursor].gameName }
    local doors, rooms = {}, {}
    for index, target in ipairs(prebossBatch.targets) do doors[index] = { Name = target.exit.type } end
    for _ = 1, #prebossBatch.targets do
        local room = session.chooseNextRoom(state, currentRun, doors, game)
        rooms[room.__runPlannerInstructionId] = room
    end
    local calls = 0
    local sharedBag = { "StackUpgrade" }
    currentRun.RewardPriorities = { "ExistingPriority" }
    for _, target in ipairs(prebossBatch.targets) do
        local room = rooms[target.room.instructionId]
        local reward = state.instructionById[target.room.instructionId].incomingReward
        local door = doors[target.exit.index]
        door.Room = room
        local beforeBagCount = #sharedBag
        local choice = session.chooseRoomReward(state, currentRun, room, "RunProgress", {}, { Door = door },
            function(run, targetRoom)
                calls = calls + 1
                if reward.producerKind == "freeReward" then
                    lu.assertEquals(run.RewardPriorities[1], reward.offer.rewardType)
                    table.remove(run.RewardPriorities, 1)
                    lu.assertEquals(sharedBag[1], "StackUpgrade")
                    table.remove(sharedBag, 1)
                else
                    lu.assertEquals(run.RewardPriorities[1], "ExistingPriority")
                end
                targetRoom.Reward = { Name = reward.offer.rewardType }
                return reward.offer.rewardType
            end)
        lu.assertEquals(choice.value, reward.offer.rewardType)
        lu.assertEquals(room.Reward.Name, reward.offer.rewardType)
        if reward.producerKind == "shop" then lu.assertEquals(#sharedBag, beforeBagCount) end
    end
    lu.assertEquals(calls, 2)
    lu.assertEquals(sharedBag, {})
    lu.assertEquals(currentRun.RewardPriorities, { "ExistingPriority" })

    local fixedInstruction
    for _, instruction in ipairs(route.instructions) do
        if instruction.incomingReward and instruction.incomingReward.producerKind == "fixed" then
            fixedInstruction = instruction
            break
        end
    end
    local fixedParent
    for parentId, batch in pairs(state.batchByParent) do
        for _, target in ipairs(batch.targets) do
            if target.room.instructionId == fixedInstruction.id then fixedParent = parentId; break end
        end
        if fixedParent then break end
    end
    state.cursor = fixedParent
    state.generation = nil
    currentRun.CurrentRoom = { Name = state.instructionById[fixedParent].gameName }
    local fixedBatch, fixedDoors = state.batchByParent[fixedParent], {}
    for index, target in ipairs(fixedBatch.targets) do fixedDoors[index] = { Name = target.exit.type } end
    local fixedRoom
    for _ = 1, #fixedBatch.targets do
        local room = session.chooseNextRoom(state, currentRun, fixedDoors, game)
        if room.__runPlannerInstructionId == fixedInstruction.id then fixedRoom = room end
    end
    local fixedDoor
    for _, target in ipairs(fixedBatch.targets) do
        if target.room.instructionId == fixedInstruction.id then fixedDoor = fixedDoors[target.exit.index] end
    end
    fixedDoor.Room = fixedRoom
    currentRun.RewardPriorities = { "ExistingPriority" }
    local fixedBag = { "Story" }
    local fixed = session.chooseRoomReward(state, currentRun, fixedRoom, "RunProgress", {}, { Door = fixedDoor },
        function(run)
            lu.assertEquals(run.RewardPriorities, { "ExistingPriority" })
            lu.assertEquals(fixedBag, { "Story" })
            return { Name = "Story" }
        end)
    lu.assertEquals(fixed.value.Name, "Story")
    lu.assertEquals(fixedBag, { "Story" })
    lu.assertEquals(currentRun.RewardPriorities, { "ExistingPriority" })
end

function TestSession.testRuntimeSourceFailureAndUnmarkedRewardCallsFailClosedOrPassThrough()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    lu.assertEquals(session.chooseRoomReward(state, currentRun, { Name = "VanillaRoom" }, "RunProgress", {}, nil,
        function() return "VanillaReward" end).kind, "passThrough")
    local sourceInstruction, sourceParent
    for parentId, candidateBatch in pairs(state.batchByParent) do
        for _, candidate in ipairs(candidateBatch.targets) do
            local instruction = state.instructionById[candidate.room.instructionId]
            if instruction.incomingReward and instruction.incomingReward.offer.rewardType == "Boon" then
                sourceInstruction, sourceParent = instruction, parentId
                break
            end
        end
        if sourceParent then break end
    end
    state.cursor, state.generation = sourceParent, nil
    currentRun.CurrentRoom = { Name = state.instructionById[sourceParent].gameName }
    local batch = state.batchByParent[sourceParent]
    local doors = {}
    for index, target in ipairs(batch.targets) do doors[index] = { Name = target.exit.type } end
    local target
    for _ = 1, #batch.targets do
        local room = session.chooseNextRoom(state, currentRun, doors, game)
        if room.__runPlannerInstructionId == sourceInstruction.id then target = room end
    end
    local door = doors[target.__runPlannerExitIndex]
    door.Room = target
    state.instructionById[target.__runPlannerInstructionId].incomingReward.offer.payload = nil
    local called = false
    local result = session.chooseRoomReward(state, currentRun, target, "MetaProgress", {}, { Door = door },
        function() called = true; return "Boon" end)
    lu.assertEquals(result.kind, "failed")
    lu.assertFalse(called)
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "reward-source")
    lu.assertTrue(state.firstMismatch.beforeApply)
end

function TestSession.testVanillaRewardReturnMismatchIsPostApply()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    game.CreateRoom = function(roomData) return roomData end
    local currentRun = start(state, plan, game)
    local starting = assert(session.chooseStartingRoom(state, currentRun, { StartingBiome = "F" }, game))
    local result = session.chooseRoomReward(state, currentRun, starting, "RunProgress", {}, nil,
        function() return "WrongReward" end)
    lu.assertEquals(result.kind, "failed")
    lu.assertEquals(state.firstMismatch.checkpoint, "reward-type")
    lu.assertFalse(state.firstMismatch.beforeApply)
end

function TestSession.testExactOrderedBatchKeepsUnpickedRoomsAndAdvancesOnlyFromObservedSelectedDoor()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local firstBatch = state.batchByParent[state.cursor]
    local firstTarget = firstBatch.targets[1]
    local first = session.chooseNextRoom(state, currentRun, { { Name = firstTarget.exit.type } }, game)
    lu.assertEquals(first.__runPlannerInstructionId, firstTarget.room.instructionId)
    lu.assertEquals(first.__runPlannerExitKey, firstTarget.exit.exitKey)
    session.observeExit(state, currentRun, { Name = firstTarget.exit.type, Room = first })
    lu.assertEquals(state.cursor, firstTarget.room.instructionId)

    currentRun.CurrentRoom = {
        Name = state.instructionById[firstTarget.room.instructionId].gameName,
        GenusName = state.instructionById[firstTarget.room.instructionId].gameName,
    }
    state.cursor = firstTarget.room.instructionId
    local batch = state.batchByParent[state.cursor]
    local doors = {}
    for index, target in ipairs(batch.targets) do doors[index] = { Name = target.exit.type } end
    local picked = session.chooseNextRoom(state, currentRun, doors, game)
    local unpicked = session.chooseNextRoom(state, currentRun, doors, game)
    lu.assertEquals(picked.__runPlannerInstructionId, batch.targets[1].room.instructionId)
    lu.assertEquals(unpicked.__runPlannerInstructionId, batch.targets[2].room.instructionId)
    lu.assertNotEquals(picked, unpicked)
    session.observeExit(state, currentRun, { Name = batch.targets[2].exit.type, Room = unpicked })
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.cursor, firstTarget.room.instructionId)
end

function TestSession.testPrebossCompletionAndBiomeHandoffAdvanceOnlyOnObservedHostRooms()
    local plan, route = routeFixture("complete-underworld")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local prebossBatch
    for _, instruction in ipairs(route.instructions) do
        if instruction.kind == "batch" and instruction.targets[1].continuation == "startsCompletion" then
            prebossBatch = instruction
            break
        end
    end
    state.cursor = prebossBatch.parent.instructionId
    currentRun.CurrentRoom = { Name = route.instructions[1].gameName }
    local parent = state.instructionById[state.cursor]
    currentRun.CurrentRoom.Name = parent.gameName
    local doors = {}
    for index, target in ipairs(prebossBatch.targets) do doors[index] = { Name = target.exit.type } end
    local preboss = session.chooseNextRoom(state, currentRun, doors, game)
    for _ = 2, #prebossBatch.targets do session.chooseNextRoom(state, currentRun, doors, game) end
    session.observeExit(state, currentRun, { Name = prebossBatch.targets[1].exit.type, Room = preboss })
    lu.assertEquals(state.cursor, prebossBatch.targets[1].room.instructionId)
    local biome = state.biomeByKey[parent.origin.biomeKey]
    local boss = state.instructionById[biome.completionInstructionIds[1]]
    local postboss = state.instructionById[biome.completionInstructionIds[2]]
    currentRun.CurrentRoom = { Name = preboss.Name }
    session.observeRoom(state, currentRun, currentRun.CurrentRoom)
    session.observeExit(state, currentRun, { Name = "AutomaticDoor", Room = { Name = boss.gameName } })
    lu.assertEquals(state.cursor, prebossBatch.targets[1].room.instructionId)
    session.observeRoom(state, currentRun, { Name = boss.gameName })
    lu.assertEquals(state.cursor, boss.id)
    session.observeRoom(state, currentRun, { Name = postboss.gameName })
    lu.assertEquals(state.cursor, postboss.id)
    local nextBiome = route.biomes[(state.biomeIndexByKey[parent.origin.biomeKey]) + 1]
    local entry = state.instructionById[nextBiome.entryInstructionId]
    currentRun.CurrentRoom = { Name = postboss.gameName }
    session.observeExit(state, currentRun, { Name = "AutomaticDoor", Room = { Name = entry.gameName } })
    lu.assertEquals(state.state, "active")
    session.observeRoom(state, currentRun, { Name = entry.gameName })
    lu.assertEquals(state.cursor, entry.id)
end

function TestSession.testFinalCompiledCompletionRelinquishesToVanillaWithoutDesynchronizing()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local biome = state.biomeByKey.F
    local postboss = state.instructionById[biome.completionInstructionIds[#biome.completionInstructionIds]]
    state.cursor = postboss.id
    currentRun.CurrentRoom = { Name = postboss.gameName }
    session.observeExit(state, currentRun, { Name = "VanillaExit", Room = { Name = "G_Opening01" } })
    lu.assertEquals(state.state, "inactive")
    lu.assertEquals(state.reason, "route-complete")
    lu.assertNil(state.firstMismatch)
end

function TestSession.testUnexpectedDoorAndRoomContactsLatchDesynchronization()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local batch = state.batchByParent[state.cursor]
    session.chooseNextRoom(state, currentRun, { { Name = "UnexpectedDoor" } }, game)
    lu.assertEquals(state.state, "desynchronized")
    local first = state.firstMismatch
    session.observeRoom(state, currentRun, { Name = "UnexpectedRoom" })
    lu.assertEquals(state.firstMismatch, first)
    lu.assertEquals(batch.id, state.firstMismatch.instructionId)
end

function TestSession.testAutomaticHostContinuationWaitsForItsMarkedRoomObservation()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local batch = state.batchByParent[state.cursor]
    local selected = batch.targets[1]
    selected.exit.behavior = "automaticHostContinuation"
    local generated = session.chooseNextRoom(state, currentRun, { { Name = selected.exit.type } }, game)
    session.observeExit(state, currentRun, { Name = selected.exit.type, Room = generated })
    lu.assertEquals(state.cursor, batch.parent.instructionId)
    lu.assertEquals(state.pendingAutomaticTargetId, selected.room.instructionId)
    session.observeRoom(state, currentRun, generated)
    lu.assertEquals(state.cursor, selected.room.instructionId)
    lu.assertNil(state.pendingAutomaticTargetId)
end

function TestSession.testPreassignedPhysicalDoorCannotShiftTheCompiledBatchIndex()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local first = state.batchByParent[state.cursor].targets[1]
    state.cursor = first.room.instructionId
    currentRun.CurrentRoom = { Name = state.instructionById[state.cursor].gameName }
    local batch = state.batchByParent[state.cursor]
    local doors = {
        { Name = batch.targets[1].exit.type },
        { Name = batch.targets[2].exit.type, Room = { Name = "PredeterminedRoom" } },
    }
    local result = session.routeNextRoom(state, currentRun, {}, doors, game)
    lu.assertEquals(result.kind, "failed")
    lu.assertEquals(state.state, "desynchronized")
end

function TestSession.testSelectedDoorRequiresTheExactCompiledPhysicalExitMarker()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local batch = state.batchByParent[state.cursor]
    local selected = batch.targets[1]
    local generated = session.chooseNextRoom(state, currentRun, { { Name = selected.exit.type } }, game)
    generated.__runPlannerExitKey = "wrong-exit"
    session.observeExit(state, currentRun, { Name = selected.exit.type, Room = generated })
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.cursor, batch.parent.instructionId)
end

function TestSession.testAdditionalContinuationDoesNotGuessANormalTargetCursorAdvance()
    local plan, route = routeFixture("representative-f")
    local game, state = contactGame(route), newState()
    local currentRun = start(state, plan, game)
    local batch = state.batchByParent[state.cursor]
    local normal = batch.targets[1]
    batch.selectedContinuation = {
        kind = "additional", additionalExitKey = "naturalChaos", instructionId = normal.room.instructionId,
    }
    local hooks = {}
    session.registerHooks({ hooks = { wrap = function(path, _key, callback) hooks[path] = callback end } },
        { inbox = { load = function() return true, plan end }, game = game })
    local runtime = { data = { cache = { currentRun = { get = function() return state end } } } }
    local fallbackCalls = 0
    local generated = hooks.ChooseNextRoomData(nil, runtime, function()
        fallbackCalls = fallbackCalls + 1
        return { Name = "VanillaNext" }
    end, currentRun, {}, { { Name = normal.exit.type } })
    hooks.LeaveRoom(nil, runtime, function(_, door) return door end,
        currentRun, { Name = normal.exit.type, Room = generated })
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.cursor, batch.parent.instructionId)
    lu.assertEquals(fallbackCalls, 0)
end

function TestSession.testCurrentRunCacheSurvivesReloadWithoutRereadAndResetsForNewRun()
    local plan, route = routeFixture("representative-f")
    local game, reads, buckets = contactGame(route), 0, {}
    local activeRun
    local runtime = { data = { cache = { currentRun = { get = function()
        buckets[activeRun] = buckets[activeRun] or newState()
        return buckets[activeRun]
    end } } } }
    local logs = {}
    local host = { log = function(format, value) logs[#logs + 1] = string.format(format, value) end }
    local inbox = { load = function() reads = reads + 1; return true, plan end }
    local function install()
        local hooks = {}
        session.registerHooks({ hooks = { wrap = function(path, _key, callback) hooks[path] = callback end } },
            { inbox = inbox, game = game })
        return hooks.StartNewRun
    end
    local run1 = { Revision = "r1", CurrentRoom = { RoomSetName = "F", Name = route.instructions[1].gameName } }
    activeRun = run1
    local start1 = install()
    host.isEnabled = function() return true end
    lu.assertEquals(start1(host, runtime, function() return run1 end, nil, { StartingBiome = "F" }), run1)
    lu.assertEquals(reads, 1)
    lu.assertEquals(#logs, 1)
    local state1 = buckets[run1]
    local reloadedStart = install()
    lu.assertEquals(reloadedStart(host, runtime, function() return run1 end, nil, { StartingBiome = "F" }), run1)
    lu.assertEquals(reads, 1)
    lu.assertEquals(buckets[run1], state1)
    lu.assertEquals(#logs, 1)
    state1.state, state1.reason = "desynchronized", "live-contact-failure"
    state1.firstMismatch = { checkpoint = "starting-room", expected = "Expected", observed = "Observed" }
    lu.assertEquals(reloadedStart(host, runtime, function() return run1 end, nil, { StartingBiome = "F" }), run1)
    lu.assertEquals(#logs, 2)
    lu.assertEquals(reloadedStart(host, runtime, function() return run1 end, nil, { StartingBiome = "F" }), run1)
    lu.assertEquals(#logs, 2)
    local run2 = { Revision = "r2", CurrentRoom = { RoomSetName = "F", Name = route.instructions[1].gameName } }
    activeRun = run2
    lu.assertEquals(reloadedStart(host, runtime, function() return run2 end, nil, { StartingBiome = "F" }), run2)
    lu.assertEquals(reads, 2)
    lu.assertNotEquals(buckets[run2], state1)
    lu.assertEquals(#logs, 3)
end

return TestSession
