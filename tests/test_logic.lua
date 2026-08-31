local lu = require("luaunit")
local protocol = require("mods/protocol")
local session = require("mods/session")
local logic = require("mods/logic")
local fixtures = require("tests/harness/fixture_loader")

TestLogic = {}

local function fixturePlan()
    return assert(protocol.decode(fixtures.decode()))
end

local function withoutOpeningAcquisition(plan)
    table.remove(plan.rooms[1].trace, 2)
    return plan
end

local function openingCheckpointsOnly(plan)
    local trace = plan.rooms[1].trace
    plan.rooms[1].trace = { trace[1], trace[#trace] }
    return plan
end

local function gameFor(plan)
    local roomData = {}
    for _, room in ipairs(plan.rooms) do
        roomData[room.gameName] = roomData[room.gameName] or { Name = room.gameName, RoomSetName = room.biomeKey }
    end
    return {
        RoomData = roomData,
        LootData = { ApolloUpgrade = {} },
        CreateRoom = function(data)
            local copy = {}
            for key, value in pairs(data) do copy[key] = value end
            return copy
        end,
    }
end

local function applyRunState(run, snapshot)
    _G.CurrentRun = run
    run.BiomeDepthCache = snapshot.counters.biomeDepthCache
    run.BiomeEncounterDepth = snapshot.counters.biomeEncounterDepth
    run.EncounterDepth = snapshot.counters.routeEncounterDepth
    run.RoomHistory = {}
    for index = 1, snapshot.counters.roomHistoryOrdinal do run.RoomHistory[index] = {} end
    run.RewardPriorities = snapshot.rewardPriorities
    run.NumTalentPoints = snapshot.hexProgress.bankedPathPoints
    run.InvestedTalentPoints = snapshot.hexProgress.investedPathPoints
    run.AllSpellInvestedCache = snapshot.hexProgress.closed
    run.KeepsakeCache = snapshot.keepsakes.usedKeys
    run.BlockedKeepsakes = snapshot.keepsakes.blockedKeys
    run.RewardStores = {}
    for _, bag in ipairs(snapshot.bags) do
        run.RewardStores[bag.storeKey] = {}
        for index = 1, bag.remaining.count do run.RewardStores[bag.storeKey][index] = {} end
    end
    run.Hero = { Traits = {}, SlottedTraits = {} }
    if snapshot.hexProgress.spellTraitKey then
        run.Hero.SlottedSpell = { Name = snapshot.hexProgress.spellTraitKey, Talents = { Name = snapshot.hexProgress.layoutKey } }
        for index, key in ipairs(snapshot.hexProgress.talentKeys) do
            run.Hero.SlottedSpell.Talents[index] = { Name = key }
        end
    end
    for _, trait in ipairs(snapshot.traits.equipped) do
        run.Hero.Traits[#run.Hero.Traits + 1] = {
            Name = trait.traitKey, Rarity = trait.rarity, StackNum = trait.level,
            HammerRank = trait.hammerRank,
        }
    end
    for _, slot in ipairs(snapshot.traits.slots) do
        run.Hero.SlottedTraits[slot.slot] = slot.traitKey and { Name = slot.traitKey } or nil
    end
    run.Hero.Elements, run.Hero.GodBoonRarities = snapshot.traits.elements, snapshot.traits.godRarityCounts
    run.Hero.UpgradableTraitCount = snapshot.traits.upgradableCount
    run.BannedTraits = {}; for _, key in ipairs(snapshot.traits.bannedTraitKeys) do run.BannedTraits[key] = true end
    run.ShrineUpgradesDisabled = {}; for _, key in ipairs(snapshot.vows.disabledKeys) do run.ShrineUpgradesDisabled[key] = true end
    run.TemporaryMetaUpgrades = {}
    run.BiomeBoonSkipCount = snapshot.forfeit == "consumed" and (snapshot.vows.effectiveRanks.BoonSkipShrineUpgrade or 0) or 0
    _G.GameState = {
        ShrineUpgrades = snapshot.vows.configuredRanks,
        MetaUpgradeState = {},
        LastAwardTrait = snapshot.keepsakes.currentKey,
        FatedStatus = snapshot.keepsakes.fatedStatus,
    }
    _G.MetaUpgradeCardData, _G.TraitRarityData = {}, { RarityUpgradeOrder = { "Common", "Rare", "Epic", "Heroic" } }
    for _, card in ipairs(snapshot.arcana.active) do
        _G.GameState.MetaUpgradeState[card.key] = { Equipped = true, Level = 1 }
        _G.MetaUpgradeCardData[card.key] = {}
        if card.origin == "temporary" then run.TemporaryMetaUpgrades[card.key] = true end
    end
    _G.GetInteractedGodsThisRun = function() return snapshot.godPool.acquiredSourceKeys end
    _G.GetEligibleLootNames = function() return snapshot.godPool.effectiveSourceKeys end
    _G.ReachedMaxGods = function() return snapshot.godPool.capNarrowed end
    _G.GetNumShrineUpgrades = function(key) return snapshot.vows.effectiveRanks[key] or 0 end
    _G.GetHeroTrait = function(key)
        if key == "MetaToRunMetaUpgrade" and snapshot.artificer then
            return { MetaConversionUses = snapshot.artificer.remainingCount }
        end
        return nil
    end
    run.MetaConversionUses = snapshot.artificer and snapshot.artificer.usedCount or nil
end

function TestLogic.testGateBHooksRealizeBatchAndObserveSelectedRoom()
    local plan = openingCheckpointsOnly(fixturePlan())
    local state = session.newState()
    local wrapped, statusWrites = {}, {}
    local data = {
        inbox = { load = function() return true, plan end },
        session = {
            defineCache = function() end, get = function() return state end,
            startNewRun = session.startNewRun, chooseStartingRoom = session.chooseStartingRoom,
            status = session.status, observeRoom = session.observeRoom,
            chooseRoomReward = session.chooseRoomReward,
            chooseNextRoomData = session.chooseNextRoomData,
            prepareBatchRewardStore = session.prepareBatchRewardStore,
            observeExit = session.observeExit,
            commitExit = session.commitExit,
            observeBeforeRoomExit = session.observeBeforeRoomExit,
            prepareRewardSource = session.prepareRewardSource,
        },
    }
    local moduleRef = { hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }
    logic.attach(moduleRef, data)
    _G.game = gameFor(plan)
    local runtime = { status = { write = function(key, value) statusWrites[key] = value end } }
    local args = { StartingBiome = "F" }
    local currentRun
    local result = wrapped.StartNewRun(
        { isEnabled = function() return true end }, runtime,
        function(previousRun)
            currentRun = { CurrentRoom = { RoomSetName = "F" }, RewardPriorities = { "Other" }, previous = previousRun }
            applyRunState(currentRun, plan.rooms[1].trace[1].runState)
            currentRun.StartingRoom = wrapped.ChooseStartingRoom(nil, runtime, function() return { Name = "vanilla" } end, currentRun, args)
            return currentRun
        end, nil, args)
    lu.assertEquals(result, currentRun)
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(currentRun.StartingRoom.__runPlannerExecutionRoomId, "golden-f-start")

    local lifecycle = {}
    currentRun.CurrentRoom = currentRun.StartingRoom
    currentRun.CurrentRoom.RunOverrides = { BiomeDepthCache = 0 }
    -- Model the vanilla portion of StartRoom that runs before its nested
    -- preload seam.  The observer must see initialized cache values here,
    -- while the later encounter-start transition remains after observation.
    currentRun.BiomeDepthCache = currentRun.CurrentRoom.RunOverrides.BiomeDepthCache
    currentRun.BiomeEncounterDepth = nil
    currentRun.EncounterDepth = 1
    lifecycle[#lifecycle + 1] = "cache-initialized"
    wrapped.StartRoomPreLoadBinks(nil, runtime, function(argsValue)
        lifecycle[#lifecycle + 1] = "encounter-start"
        currentRun.BiomeEncounterDepth = 2
        return argsValue
    end, { Run = currentRun, Room = currentRun.StartingRoom, Encounter = {} })
    lu.assertTrue(state.diagnostics.roomEntered)
    lu.assertEquals(lifecycle, { "cache-initialized", "encounter-start" })
    lu.assertEquals(currentRun.BiomeEncounterDepth, 2)
    currentRun.CurrentRoom = currentRun.StartingRoom
    wrapped.ChooseRoomReward(nil, runtime, function() return { Name = "Boon" } end, result, currentRun.StartingRoom, "RunProgress", {}, {})
    local opening = plan.rooms[1]
    local doors = { { Name = opening.outgoing.targets[1].type } }
    local targetData = wrapped.ChooseNextRoomData(nil, runtime, function() error("base should not realize planner peer") end, result, {}, doors)
    lu.assertEquals(targetData.__runPlannerExecutionExitIndex, 1)
    doors[1].Room = targetData
    wrapped.DoUnlockRoomExits(nil, runtime, function(run, room) return room end, result, currentRun.StartingRoom)
    applyRunState(currentRun, plan.rooms[1].trace[#plan.rooms[1].trace].runState)
    local observedSourceAtCommit = false
    local destinationCommittedBeforeLeaveReturns = false
    local updated = wrapped.LeaveRoom(nil, runtime, function(run, door)
        local updateResult = wrapped.UpdateRunHistoryCache(nil, runtime, function(liveRun, roomAdded)
            observedSourceAtCommit = state.currentRoomId == plan.rooms[1].id
            return "updated"
        end, run, plan.rooms[1].gameName)
        destinationCommittedBeforeLeaveReturns = state.currentRoomId == targetData.__runPlannerExecutionRoomId
        return updateResult
    end, result, doors[1])
    lu.assertEquals(updated, "updated")
    lu.assertTrue(observedSourceAtCommit)
    lu.assertTrue(destinationCommittedBeforeLeaveReturns)
    lu.assertTrue(state.diagnostics.beforeRoomExit)
    for _, room in ipairs(plan.rooms) do
        if room.id == targetData.__runPlannerExecutionRoomId then
            applyRunState(currentRun, room.trace[1].runState)
            break
        end
    end
    currentRun.CurrentRoom = targetData
    wrapped.StartRoomPreLoadBinks(nil, runtime, function(argsValue) return argsValue end, {
        Run = result,
        Room = targetData,
        Encounter = {},
    })
    lu.assertEquals(state.currentRoomId, "golden-f-b1-e1")
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(statusWrites.ExecutionSessionStatus, "synchronized: room-entry-observed")
end

function TestLogic.testStartOutsideLifecycleCannotFreezePlan()
    local plan = fixturePlan()
    local state = session.newState()
    local wrapped = {}
    local data = {
        inbox = { load = function() return true, plan end },
        session = {
            defineCache = function() end, get = function() return state end,
            startNewRun = session.startNewRun, chooseStartingRoom = session.chooseStartingRoom,
            status = session.status, observeRoom = session.observeRoom,
            chooseRoomReward = session.chooseRoomReward,
            chooseNextRoomData = session.chooseNextRoomData,
            prepareBatchRewardStore = session.prepareBatchRewardStore,
            observeExit = session.observeExit,
            commitExit = session.commitExit,
            observeBeforeRoomExit = session.observeBeforeRoomExit,
            prepareRewardSource = session.prepareRewardSource,
        },
    }
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, data)
    local fallback = 0
    wrapped.ChooseStartingRoom(nil, { status = {} }, function() fallback = fallback + 1; return {} end, { CurrentRoom = { RoomSetName = "F" } }, { StartingBiome = "F" })
    lu.assertEquals(fallback, 1)
    lu.assertFalse(state.initialized)
end

function TestLogic.testPreContactMismatchDelegatesToVanillaAndFreezesPlannerSuffix()
    local plan = fixturePlan()
    local state = session.newState()
    local wrapped = {}
    local data = {
        inbox = { load = function() return true, plan end },
        session = {
            defineCache = function() end, get = function() return state end,
            startNewRun = session.startNewRun, chooseStartingRoom = session.chooseStartingRoom,
            status = session.status, observeRoom = session.observeRoom,
            chooseRoomReward = session.chooseRoomReward,
            chooseNextRoomData = session.chooseNextRoomData,
            prepareBatchRewardStore = session.prepareBatchRewardStore,
            observeExit = session.observeExit, commitExit = session.commitExit,
            observeBeforeRoomExit = session.observeBeforeRoomExit,
            prepareRewardSource = session.prepareRewardSource,
        },
    }
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, data)
    local runtime = { status = { write = function() end } }
    local run = { CurrentRoom = { RoomSetName = "F" } }
    wrapped.StartNewRun({ isEnabled = function() return true end }, runtime, function() return run end, nil, { StartingBiome = "F" })
    local baseCalls = 0
    local result = wrapped.ChooseNextRoomData(nil, runtime, function()
        baseCalls = baseCalls + 1
        return "vanilla-room"
    end, run, {}, {})
    lu.assertEquals(result, "vanilla-room")
    lu.assertEquals(baseCalls, 1)
    lu.assertEquals(state.state, "desynchronized")
    local second = wrapped.ChooseNextRoomData(nil, runtime, function()
        baseCalls = baseCalls + 1
        return "vanilla-suffix"
    end, run, {}, {})
    lu.assertEquals(second, "vanilla-suffix")
    lu.assertEquals(baseCalls, 2)
end

function TestLogic.testAcquisitionHooksWireOrdinaryOfferAndPostBaseVerification()
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
    state.roomsById = { room = { trace = { { kind = "acquireReward", roles = { {
        gameName = "ApolloUpgrade", role = "source", settlement = { site = "s", entry = "e" },
        traitOffer = { kind = "traits", giver = "Apollo", selected = "option1", options = { { key = "ApolloWeaponBoon", rarity = "Rare", effectiveLevel = 2 } } },
    } } } } } }
    local wrapped = {}
    local api = setmetatable({ defineCache = function() end, get = function() return state end }, { __index = session })
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, { inbox = {}, session = api })
    local runtime = { status = { write = function() end } }
    _G.CurrentRun = { Hero = { Traits = {} } }
    local loot = { Name = "ApolloUpgrade" }
    wrapped.UseLoot(nil, runtime, function(usee, args, user)
        lu.assertEquals(args.marker, "loot-args")
        lu.assertEquals(user.Name, "hero")
        return true
    end, loot, { marker = "loot-args" }, { Name = "hero" })
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "ApolloWeaponBoon")
    local item = loot.UpgradeOptions[1]
    wrapped.CreateUpgradeChoiceButton(nil, runtime, function(_, _, index, itemData)
        lu.assertEquals(index, 1); return itemData
    end, {}, loot, 1, item, {})
    wrapped.HandleUpgradeChoiceSelection(nil, runtime, function(_, button)
        _G.CurrentRun.Hero.Traits = { { Name = button.Data.Name, Rarity = button.Data.Rarity, StackNum = button.Data.StackNum } }
        return "selected"
    end, {}, { Data = { Name = "ApolloWeaponBoon", Rarity = "Rare", StackNum = 2 } }, {})
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.traceCursor, 2)
end

function TestLogic.testSimpleLootHookRequiresNestedPickupContact()
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
    state.roomsById = { room = { trace = { { kind = "acquireReward", roles = { { gameName = "MetaCurrencyDrop", role = "self", settlement = { site = "s", entry = "e" } } } } } } }
    local wrapped = {}
    local api = setmetatable({ defineCache = function() end, get = function() return state end }, { __index = session })
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, { inbox = {}, session = api })
    local runtime = { status = { write = function() end } }
    wrapped.UseLoot(nil, runtime, function() return false end, { Name = "MetaCurrencyDrop" }, {}, {})
    lu.assertEquals(state.traceCursor, 1)
    wrapped.UseLoot(nil, runtime, function(usee, args, user)
        return wrapped.HandleLootPickup(nil, runtime, function() return true end, {}, usee, args)
    end, { Name = "MetaCurrencyDrop" }, {}, {})
    lu.assertEquals(state.traceCursor, 2)
end

local function hookedTrace(step)
    local state, wrapped = session.newState(), {}
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
    state.roomsById = { room = { trace = { step } } }
    local api = setmetatable({ defineCache = function() end, get = function() return state end }, { __index = session })
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, { inbox = {}, session = api })
    return state, wrapped, { status = { write = function() end } }
end

function TestLogic.testSharedTraitHooksCoverDevotionHammerAndSpell()
    for _, surface in ipairs({ { "Devotion", "AphroditeUpgrade" }, { "WeaponUpgrade", "WeaponUpgrade" }, { "Spell", "SpellUpgrade" } }) do
        local step = { kind = "acquireReward", roles = { { gameName = surface[2], role = "source", settlement = { site = "s", entry = "e" }, traitOffer = { kind = "traits", giver = surface[1], selected = "option1", options = { { key = surface[1] .. "Trait", rarity = "Common", effectiveLevel = 1 } } } } } }
        local state, wrapped, runtime = hookedTrace(step)
        _G.CurrentRun = { Hero = { Traits = {} } }
        local loot = { Name = surface[2] }
        wrapped.UseLoot(nil, runtime, function() return true end, loot, {}, {})
        local item = loot.UpgradeOptions[1]
        wrapped.CreateUpgradeChoiceButton(nil, runtime, function(_, _, _, itemData) return itemData end, {}, loot, 1, item, {})
        wrapped.HandleUpgradeChoiceSelection(nil, runtime, function(_, button)
            _G.CurrentRun.Hero.Traits = { { Name = button.Data.Name, Rarity = button.Data.Rarity, StackNum = button.Data.StackNum } }
        end, {}, { Data = { Name = surface[1] .. "Trait", Rarity = "Common", StackNum = 1 } }, {})
        lu.assertEquals(state.traceCursor, 2)
    end
end

function TestLogic.testTalentConsumableHookUsesNestedPresentation()
    local step = { kind = "acquireReward", roles = { { gameName = "TalentPoint", role = "self", settlement = { site = "s", entry = "e" } } } }
    local state, wrapped, runtime = hookedTrace(step)
    local item = { Name = "TalentPoint", IgnorePurchase = true, ResourceCosts = { Money = 10 } }
    wrapped.UseConsumableItem(nil, runtime, function(consumable, args)
        return wrapped.ConsumableUsedPresentation(nil, runtime, function() return true end, {}, consumable, args)
    end, item, {}, {})
    lu.assertEquals(state.traceCursor, 2)
end

function TestLogic.testPomHookCapturesPreBaseStackAndVerifiesDelta()
    local step = { kind = "acquireReward", roles = { { gameName = "StackUpgrade", role = "self", settlement = { site = "s", entry = "e" }, levelResolution = { offeredTargets = { "PomTrait" }, selectedTarget = "PomTrait", levelCount = 2 } } } }
    local state, wrapped, runtime = hookedTrace(step)
    _G.CurrentRun = { Hero = { Traits = { { Name = "PomTrait", StackNum = 1 } } } }
    local loot = { Name = "StackUpgrade" }
    wrapped.UseLoot(nil, runtime, function() return true end, loot, {}, {})
    wrapped.HandleUpgradeChoiceSelection(nil, runtime, function()
        _G.CurrentRun.Hero.Traits[1].StackNum = 3
    end, {}, { Data = { Name = "PomTrait" } }, {})
    lu.assertEquals(state.traceCursor, 2)
    lu.assertNil(state.pendingPom)
end

function TestLogic.testSteadyEmbryoAndCleanupHooksUseTheirScopedContacts()
    local steady = { kind = "steadyGrowth", source = "SteadyGrowth", target = "GrowthTrait" }
    local state, wrapped, runtime = hookedTrace(steady)
    _G.GetUpgradedRarity = function() return "Epic" end
    _G.CurrentRun = { Hero = { Traits = { { Name = "GrowthTrait", Rarity = "Rare" } } } }
    wrapped.AddRarityToTraits(nil, runtime, function(source, args)
        lu.assertEquals(source, "SteadyGrowth"); lu.assertEquals(args.ForceUpgrade[1].Name, "GrowthTrait")
        _G.CurrentRun.Hero.Traits[1].Rarity = "Epic"; return _G.CurrentRun.Hero.Traits[1]
    end, "SteadyGrowth", {})
    lu.assertEquals(state.traceCursor, 2)
    local embryo = { kind = "transcendentEmbryo", source = "Embryo", target = "ChaosTrait", rarity = "Heroic" }
    state, wrapped, runtime = hookedTrace(embryo)
    _G.CurrentRun = { Hero = { TraitDictionary = { ChaosTrait = { {} } } } }
    wrapped.AddRandomChaosBlessing(nil, runtime, function(rarity)
        lu.assertEquals(rarity, "Heroic")
        lu.assertEquals(wrapped.GetRandomArrayValue(nil, runtime, function() return "wrong" end, { "wrong", "ChaosTrait" }), "ChaosTrait")
        return { Name = "ChaosTrait", Rarity = "Heroic", FromChaosKeepsake = true }
    end, "Common")
    lu.assertEquals(state.traceCursor, 2)
    state, wrapped, runtime = hookedTrace({ kind = "cleanup" })
    state.roomsById.room.outgoing = { kind = "terminal" }
    _G.CurrentRun = {}
    wrapped.LeaveRoom(nil, runtime, function()
        wrapped.CleanupEnemies(nil, runtime, function() return true end, {})
    end, {}, {})
    lu.assertEquals(state.traceCursor, 2)
end

local function producedRole(kind, sourceOwner, sourceRole, gameName)
    return { role = "self", gameName = gameName, producer = { kind = kind, sourceOwner = sourceOwner, sourceRole = sourceRole } }
end

local function producedState(kind, childName)
    local source = { role = "source", gameName = "SourceLoot", disposition = kind == "artificerReplacement" and "artificer" or "normal" }
    local sourceAction = { kind = "acquireReward", sourceOwner = "source-owner", reward = { rewardType = "RoomMoneyDrop" }, roles = { source } }
    local childAction = {
        kind = "acquireReward", sourceOwner = "child-owner",
        reward = { rewardType = "Boon", source = "ApolloUpgrade", resolvedStoreKey = "RunProgress" },
        roles = { producedRole(kind, "source-owner", "source", childName) },
    }
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
    state.roomsById = { room = { id = "room", gameName = "F_Test", outgoing = { kind = "terminal" }, trace = { sourceAction, childAction } } }
    state.producedChildren = { ["source-owner\0source"] = { { action = childAction, role = childAction.roles[1] } } }
    return state
end

function TestLogic.testArtificerUsesNativeRewardAndVerifiesTheProducedChild()
    local state, wrapped = producedState("artificerReplacement", "RoomRewardConsolationPrize"), {}
    local api = setmetatable({ defineCache = function() end, get = function() return state end }, { __index = session })
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, { inbox = {}, session = api })
    local runtime = { status = { write = function() end } }
    local run = { CurrentRoom = { Name = "F_Test", __runPlannerExecutionRoomId = "room" }, RewardPriorities = {} }
    _G.game, _G.CurrentRun = { LootData = { ApolloUpgrade = {} } }, run
    local source = { Name = "SourceLoot", ObjectId = 17, MetaConversionEligible = true }
    -- Eligibility polling is not the player conversion seam.
    lu.assertNil(wrapped.CanReceiveGift)
    wrapped.ConvertMetaRewardPresentation(nil, runtime, function() return true end, source)
    local reward = wrapped.ChooseRoomReward(nil, runtime, function() return { Name = "Boon" } end, run, run.CurrentRoom, "RunProgress", {}, {})
    lu.assertEquals(reward.Name, "Boon")
    local child = wrapped.SpawnRoomReward(nil, runtime, function(_, args)
        lu.assertEquals(args.SpawnRewardOnId, 17)
        return { Name = "RoomRewardConsolationPrize" }
    end, {}, { SpawnRewardOnId = 17 })
    lu.assertEquals(child.Name, "RoomRewardConsolationPrize")
    lu.assertEquals(state.state, "synchronized")
end

function TestLogic.testProducedChildWrongResultIsTheFirstMismatch()
    local state, wrapped = producedState("artificerReplacement", "RoomRewardConsolationPrize"), {}
    local api = setmetatable({ defineCache = function() end, get = function() return state end }, { __index = session })
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, { inbox = {}, session = api })
    local runtime = { status = { write = function() end } }
    local run = { CurrentRoom = { Name = "F_Test", __runPlannerExecutionRoomId = "room" }, RewardPriorities = {} }
    _G.game, _G.CurrentRun = { LootData = { ApolloUpgrade = {} } }, run
    wrapped.ConvertMetaRewardPresentation(nil, runtime, function() return true end, { Name = "SourceLoot", ObjectId = 17, MetaConversionEligible = false })
    wrapped.SpawnRoomReward(nil, runtime, function() return { Name = "WrongReward" } end, {}, { SpawnRewardOnId = 17 })
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "produced-pickup")
end

function TestLogic.testSeaStarForcesOnlyItsNativeDuplicateAndRequiresNonrecursiveResult()
    local state, wrapped = producedState("seaStarDuplicate", "SourceLoot"), {}
    local api = setmetatable({ defineCache = function() end, get = function() return state end }, { __index = session })
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, { inbox = {}, session = api })
    local runtime = { status = { write = function() end } }
    local source = { Name = "SourceLoot", ObjectId = 23, CanDuplicate = false }
    local prepared = session.beginSeaStarDuplicate(state, source)
    lu.assertNotNil(prepared)
    -- Unrelated randomness cannot consume Sea Star's pending duplicate.
    lu.assertNil(session.consumeSeaStarDuplicateRng(state))
    session.armSeaStarDuplicateRng(state)
    lu.assertTrue(session.consumeSeaStarDuplicateRng(state))
    local child = wrapped.CreateLoot(nil, runtime, function() return { Name = "SourceLoot", CanDuplicate = false } end, {})
    session.finishSeaStarDuplicate(state, source)
    lu.assertEquals(child.Name, "SourceLoot")
    lu.assertEquals(state.state, "synchronized")

    state = producedState("seaStarDuplicate", "SourceLoot")
    source = { Name = "SourceLoot", ObjectId = 24, CanDuplicate = true }
    session.beginSeaStarDuplicate(state, source)
    session.captureSeaStarDuplicate(state, { Name = "WrongLoot", CanDuplicate = false })
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "produced-pickup")
    lu.assertNil(session.armSeaStarDuplicateRng(state))
    lu.assertNil(session.consumeSeaStarDuplicateRng(state))
end

function TestLogic.testEchoLastRewardCapturesOnlyItsImmediateProducedChild()
    local sourceRole = {
        role = "source", gameName = "EchoSource",
        traitOffer = { kind = "traits", selected = "option1", options = { { key = "EchoSource" } } },
    }
    local sourceAction = { kind = "acquireReward", sourceOwner = "source-owner", reward = {}, roles = { sourceRole } }
    local childRole = producedRole("echoLastReward", "source-owner", "source", "ApolloUpgrade")
    local childAction = { kind = "acquireReward", sourceOwner = "child-owner", reward = {}, roles = { childRole } }
    local state, wrapped = session.newState(), {}
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
    state.roomsById = { room = { id = "room", trace = { sourceAction, childAction } } }
    state.producedChildren = { ["source-owner\0source"] = { { action = childAction, role = childRole } } }
    state.pendingAcquisition = { action = sourceAction, role = sourceRole, selected = "EchoSource" }
    local api = setmetatable({ defineCache = function() end, get = function() return state end }, { __index = session })
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, { inbox = {}, session = api })
    local runtime = { status = { write = function() end } }
    wrapped.EchoLastReward(nil, runtime, function()
        wrapped.CreateLoot(nil, runtime, function() return { Name = "ApolloUpgrade", CanDuplicate = false } end, {})
    end, {})
    lu.assertEquals(state.state, "synchronized")
    -- Echo made the child while the source remains current; ordinary source
    -- acquisition then advances the cursor to that still-pending child.
    lu.assertEquals(state.traceCursor, 1)
    session.verifyTraitAcquisition(state, { { Name = "EchoSource" } })
    lu.assertEquals(state.traceCursor, 2)
end

function TestLogic.testSeaStarLeavesEarlierRandomnessVanillaUntilItsNativeGate()
    local state, wrapped = producedState("seaStarDuplicate", "SourceLoot"), {}
    local api = setmetatable({ defineCache = function() end, get = function() return state end }, { __index = session })
    logic.attach({ hooks = { wrap = function(name, _, callback) wrapped[name] = callback end } }, { inbox = {}, session = api })
    local runtime = { status = { write = function() end } }
    local source = { Name = "SourceLoot", ObjectId = 24, CanDuplicate = false }
    session.beginSeaStarDuplicate(state, source)
    -- The session gate is armed exclusively by the DoubleReward lookup.
    lu.assertNil(session.consumeSeaStarDuplicateRng(state))
    lu.assertNil(session.consumeSeaStarDuplicateRng(state)) -- Double Boon is unrelated.
    session.armSeaStarDuplicateRng(state)
    lu.assertTrue(session.consumeSeaStarDuplicateRng(state))
end

return TestLogic
