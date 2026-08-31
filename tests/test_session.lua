local lu = require("luaunit")
local json = require("mods/json")
local protocol = require("mods/protocol")
local session = require("mods/session")
local fixtures = require("tests/harness/fixture_loader")

TestSession = {}

local function planInbox(plan)
    return { load = function() return true, plan end }
end

local function fixturePlan(name)
    local file = assert(io.open(name or fixtures.fixturePath, "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    return assert(protocol.decode(value))
end

local function checkpointSnapshot(plan, target)
    local snapshot = {}
    for _, room in ipairs(plan.rooms) do
        for _, step in ipairs(room.trace) do
            if step.frame ~= nil then
                for section, value in pairs(step.replace) do
                    if section == "artificer" then snapshot.artificer = value.value else snapshot[section] = value end
                end
                if step == target then return snapshot end
            end
        end
    end
    error("target checkpoint frame not found")
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

local function roomGame(plan)
    local roomData = {}
    for _, room in ipairs(plan.rooms) do
        roomData[room.gameName] = roomData[room.gameName] or { Name = room.gameName, RoomSetName = room.biomeKey }
    end
    return {
        RoomData = roomData,
        LootData = { ApolloUpgrade = {}, ZeusUpgrade = {} },
        CreateRoom = function(data)
            local copy = {}
            for key, value in pairs(data) do copy[key] = value end
            return copy
        end,
    }
end

local function start(plan, currentRun)
    local state = session.newState()
    currentRun = currentRun or { CurrentRoom = { RoomSetName = "F" } }
    session.startNewRun(state, {
        inbox = planInbox(plan), currentRun = currentRun, args = { StartingBiome = "F" },
    })
    return state, currentRun, roomGame(plan)
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
        local count = bag.remaining.count + (bag.storeKey == "MetaProgress" and 6 or 0)
        for index = 1, count do run.RewardStores[bag.storeKey][index] = {} end
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

function TestSession.testStartNewRunFreezesOnlyAtStartAndRealizesOpening()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan, { CurrentRoom = { RoomSetName = "F" }, RewardPriorities = { "Other" } })
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.reason, "plan-frozen")
    lu.assertEquals(state.plan, plan)
    local room = session.chooseStartingRoom(state, currentRun, { StartingBiome = "F" }, game)
    lu.assertEquals(room.__runPlannerExecutionRoomId, "golden-f-start")
    lu.assertEquals(room.__runPlannerExecutionEncounterPhases[1].encounterKey, "OpeningGeneratedF")
    lu.assertEquals(room.LegalEncounters[1], "OpeningGeneratedF")
end

function TestSession.testOpeningRewardUsesScopedOccurrenceDuringNativeRoomConstruction()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan, {
        CurrentRoom = { RoomSetName = "F" },
        RewardPriorities = {},
    })
    local opening = plan.rooms[1]
    local rewardResult
    game.CreateRoom = function(data)
        -- Model a native construction boundary that does not retain extension
        -- metadata until the executor receives the completed room.
        local room = { Name = data.Name, RoomSetName = data.RoomSetName }
        rewardResult = session.chooseRoomReward(
            state,
            currentRun,
            room,
            game,
            function() return { Name = opening.contents.incomingReward.rewardType } end,
            opening.contents.incomingReward.resolvedStoreKey,
            {},
            {}
        )
        return room
    end

    local room = session.chooseStartingRoom(state, currentRun, { StartingBiome = "F" }, game)
    lu.assertEquals(rewardResult.kind, "handled")
    lu.assertEquals(room.__runPlannerExecutionRoomId, opening.id)
    lu.assertEquals(state.state, "synchronized")
    lu.assertNil(state.roomCreationId)
end

function TestSession.testMetaProgressProjectionAdvancesWithNativeStoreRefill()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan, { RewardPriorities = {} })
    local opening = plan.rooms[1]
    local room = {
        Name = opening.gameName,
        RoomSetName = opening.biomeKey,
        __runPlannerExecutionRoomId = opening.id,
    }
    -- Only the six non-projected raw entries remain when native eligibility
    -- triggers a refill. Native appends 19 and then removes the selected one;
    -- the planner's fresh projected set contains the expected 12.
    currentRun.RewardStores = { MetaProgress = {} }
    for index = 1, 6 do currentRun.RewardStores.MetaProgress[index] = {} end
    local result = session.chooseRoomRewardFor(
        state,
        { rewardType = "MetaCurrencyDrop", resolvedStoreKey = "MetaProgress" },
        currentRun,
        room,
        game,
        function(run)
            for _ = 1, 19 do run.RewardStores.MetaProgress[#run.RewardStores.MetaProgress + 1] = {} end
            table.remove(run.RewardStores.MetaProgress)
            return "MetaCurrencyDrop"
        end,
        "MetaProgress",
        {},
        {}
    )
    lu.assertEquals(result.kind, "handled")
    lu.assertEquals(#currentRun.RewardStores.MetaProgress, 24)
    lu.assertEquals(state.bagProjectionOffsets.MetaProgress, 12)
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testSuccessfulResourceUsesNativePointAndVerifiesItsSettledElement()
    local plan = fixturePlan()
    plan.rooms[1].contents.resources = {
        { acquisitionRole = "resource:FireEssence", grantedTraitKey = "FireEssence", contributions = { Fire = 1 } },
    }
    local state, currentRun, game = start(plan)
    local room = session.chooseStartingRoom(state, currentRun, { StartingBiome = "F" }, game)
    -- Native CreateRoom recomputes this flag; the post-construction seam
    -- restores only the planner's successful outcome.
    room.PickaxePointSuccess = false
    session.applyResourceSuccesses(state, room)
    lu.assertTrue(room.PickaxePointSuccess)
    local resource = session.beginResourceElementGrant(state, "ToolPickaxe2")
    lu.assertEquals(resource.grantedTraitKey, "FireEssence")
    session.verifyResourceElementGrant(state, resource, "FireEssence")
    lu.assertEquals(state.state, "synchronized")
    session.verifyResourceElementGrant(state, resource, nil)
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "resource-element")
end

function TestSession.testResourceSuccessUsesCreatedTargetOccurrenceNotCurrentSource()
    local plan = fixturePlan()
    local state, currentRun = start(plan)
    local source, target = plan.rooms[1], plan.rooms[2]
    source.contents.resources = {
        { acquisitionRole = "resource:WaterEssence", grantedTraitKey = "WaterEssence", contributions = { Water = 1 } },
    }
    target.contents.resources = {
        { acquisitionRole = "resource:FireEssence", grantedTraitKey = "FireEssence", contributions = { Fire = 1 } },
    }
    state.currentRoomId = source.id
    local createdTarget = {
        __runPlannerExecutionRoomId = target.id,
        PickaxePointSuccess = false, ExorcismPointSuccess = true,
        ShovelPointSuccess = true, FishingPointSuccess = true,
    }
    session.applyResourceSuccesses(state, createdTarget)
    lu.assertTrue(createdTarget.PickaxePointSuccess)
    lu.assertFalse(createdTarget.ExorcismPointSuccess)
    lu.assertFalse(createdTarget.ShovelPointSuccess)
    lu.assertFalse(createdTarget.FishingPointSuccess)
end

function TestSession.testMissingLiveIdentifierBecomesFirstDesynchronization()
    local plan = fixturePlan()
    local state, _, game = start(plan)
    game.RoomData.F_Opening01 = nil
    lu.assertNil(session.chooseStartingRoom(state, {}, {}, game))
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "starting-room")
end

function TestSession.testTwoDoorGenerationPreservesPhysicalOrderAndSelectedBranch()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    applyRunState(currentRun, checkpointSnapshot(plan, plan.rooms[1].trace[1]))
    local opening = session.chooseStartingRoom(state, currentRun, {}, game)
    currentRun.CurrentRoom = opening
    session.observeRoom(state, currentRun, opening)
    local store = session.prepareBatchRewardStore(state, currentRun)
    lu.assertEquals(store.kind, "handled")
    lu.assertEquals(currentRun.NextRewardStoreName, "MetaProgress")
    local base = function(run) return { Name = "Boon", run = run } end
    local reward = session.chooseRoomReward(state, currentRun, opening, game, base, "RunProgress", {}, {})
    lu.assertEquals(reward.kind, "handled")
    local outgoing = plan.rooms[2].outgoing
    lu.assertEquals(outgoing.kind, "batch")
    local twoDoorRoom
    for _, candidate in ipairs(plan.rooms) do
        if candidate.outgoing.kind == "batch" and #candidate.outgoing.targets == 2 then twoDoorRoom = candidate; break end
    end
    lu.assertNotNil(twoDoorRoom)
    state.currentRoomId = twoDoorRoom.id
    currentRun.CurrentRoom = { Name = twoDoorRoom.gameName, RoomSetName = twoDoorRoom.biomeKey, __runPlannerExecutionRoomId = twoDoorRoom.id }
    local doors = {}
    for index, candidate in ipairs(twoDoorRoom.outgoing.targets) do doors[index] = { Name = candidate.type } end
    local first = session.chooseNextRoomData(state, currentRun, {}, doors, game)
    local second = session.chooseNextRoomData(state, currentRun, {}, doors, game)
    lu.assertEquals(first.kind, "handled")
    lu.assertEquals(second.kind, "handled")
    lu.assertEquals(first.roomData.__runPlannerExecutionExitIndex, 1)
    lu.assertEquals(second.roomData.__runPlannerExecutionExitIndex, 2)
    lu.assertEquals(first.roomData.__runPlannerExecutionRoomId, twoDoorRoom.outgoing.targets[1].room.id)
    lu.assertEquals(second.roomData.__runPlannerExecutionRoomId, twoDoorRoom.outgoing.targets[2].room.id)
end

function TestSession.testGeneratedPeersResolveRewardsWithoutAdvancingSource()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    local source = plan.rooms[2]
    lu.assertEquals(source.outgoing.kind, "batch")
    lu.assertEquals(#source.outgoing.targets, 2)
    state.currentRoomId = source.id
    currentRun.CurrentRoom = {
        Name = source.gameName, RoomSetName = source.biomeKey,
        __runPlannerExecutionRoomId = source.id,
    }
    local doors = {}
    for index, target in ipairs(source.outgoing.targets) do doors[index] = { Name = target.type } end
    local generated = {}
    for index = 1, 2 do
        generated[index] = session.chooseNextRoomData(state, currentRun, {}, doors, game)
        lu.assertEquals(generated[index].kind, "handled")
    end
    local selected = source.outgoing.targets[1]
    local boon = session.chooseRoomReward(
        state, currentRun, generated[1].roomData, game,
        function() return { Name = "Boon" } end, "RunProgress", {}, {}
    )
    lu.assertEquals(boon.kind, "handled")
    lu.assertEquals(generated[1].roomData.ForceLootName, "ZeusUpgrade")
    local sourceResult = session.prepareRewardSource(state, currentRun, generated[1].roomData)
    lu.assertEquals(sourceResult.kind, "handled")
    lu.assertEquals(generated[1].roomData.ForceLootName, "ZeusUpgrade")
    local minor = session.chooseRoomReward(
        state, currentRun, generated[2].roomData, game,
        function() return { Name = "MaxHealthDrop" } end, "RunProgress", {}, {}
    )
    lu.assertEquals(minor.kind, "handled")
    lu.assertEquals(state.currentRoomId, source.id)
    lu.assertEquals(selected.room.id, generated[1].roomData.__runPlannerExecutionRoomId)
end

function TestSession.testUnrelatedRewardConstructionPassesThroughWithoutBecomingACheckpoint()
    local plan = fixturePlan("test/fixtures/execution-plan/fg-ixion-chaos.execution.json")
    local state = session.newState()
    local chaos
    for _, room in ipairs(plan.rooms) do
        if room.gameName == "Chaos_01" then chaos = room; break end
    end
    lu.assertNotNil(chaos)
    state.state, state.currentRoomId = "synchronized", chaos.id
    state.roomsById = {}
    for _, room in ipairs(plan.rooms) do state.roomsById[room.id] = room end

    local unrelated = {
        Name = "F_Combat10",
        __runPlannerExecutionRoomId = "unrelated-future-occurrence",
    }
    local run = {
        CurrentRoom = { Name = chaos.gameName, __runPlannerExecutionRoomId = chaos.id },
    }
    local reward = session.chooseRoomReward(
        state,
        run,
        unrelated,
        {},
        function() error("session must not realize an unrelated reward") end,
        "RunProgress",
        {},
        {}
    )
    local source = session.prepareRewardSource(state, run, unrelated)

    lu.assertEquals(reward.kind, "passThrough")
    lu.assertEquals(source.kind, "passThrough")
    lu.assertEquals(state.state, "synchronized")
    lu.assertNil(state.firstMismatch)
end

function TestSession.testMissingCompiledStygianWellIsAFeatureRealizationMismatch()
    local state = session.newState()
    local expected = {
        id = "well-room",
        gameName = "F_Combat08",
        contents = { stygianWell = { interacted = true, offers = {} } },
        outgoing = { kind = "terminal" },
    }
    state.state, state.currentRoomId = "synchronized", expected.id
    state.roomsById = { [expected.id] = expected }
    local observed = { Name = expected.gameName, __runPlannerExecutionRoomId = expected.id }

    session.verifyStygianWellPresence(state, { CurrentRoom = observed }, observed)

    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "room-features")
    lu.assertEquals(state.firstMismatch.expected.kind, "stygianWell")
end

function TestSession.testThreeDoorGenerationPreservesPhysicalOrder()
    local plan = fixturePlan("test/fixtures/execution-plan/fg.execution.json")
    local state, currentRun, game = start(plan)
    local source
    for _, candidate in ipairs(plan.rooms) do
        if candidate.outgoing.kind == "batch" and #candidate.outgoing.targets == 3 then source = candidate; break end
    end
    lu.assertNotNil(source)
    state.currentRoomId = source.id
    currentRun.CurrentRoom = { Name = source.gameName, RoomSetName = source.biomeKey, __runPlannerExecutionRoomId = source.id }
    local doors = {}
    for index, target in ipairs(source.outgoing.targets) do doors[index] = { Name = target.type } end
    for index = 1, 3 do
        local result = session.chooseNextRoomData(state, currentRun, {}, doors, game)
        lu.assertEquals(result.kind, "handled")
        lu.assertEquals(result.roomData.__runPlannerExecutionExitIndex, index)
    end
end

function TestSession.testSelectedAndUnpickedDoorIdentityControlsTraversal()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    local source = plan.rooms[2]
    state.currentRoomId = source.id
    currentRun.CurrentRoom = { Name = source.gameName, RoomSetName = source.biomeKey, __runPlannerExecutionRoomId = source.id }
    local outgoing = source.outgoing
    lu.assertEquals(outgoing.kind, "batch")
    local generatedRooms = {}
    local doors = {}
    for index, candidate in ipairs(outgoing.targets) do doors[index] = { Name = candidate.type } end
    for index, candidate in ipairs(outgoing.targets) do
        local generated = session.chooseNextRoomData(state, currentRun, {}, doors, game)
        generatedRooms[index] = generated.roomData
    end
    -- Use marked copies directly for the observation-only branch witness.
    local selected = outgoing.targets[1]
    -- The occurrence marker is the semantic authority; the physical obstacle
    -- name is an implementation detail and may differ from the plan's type.
    local selectedDoor = { Name = "NativePresentationDoor", Room = generatedRooms[1] }
    session.observeExit(state, currentRun, selectedDoor)
    session.commitExit(state)
    lu.assertEquals(state.currentRoomId, selected.room.id)

    local diverged, run2 = start(plan)
    diverged.currentRoomId = source.id
    run2.CurrentRoom = { Name = source.gameName, RoomSetName = source.biomeKey, __runPlannerExecutionRoomId = source.id }
    local unpicked = outgoing.targets[2]
    session.observeExit(diverged, run2, { Name = unpicked.type, Room = generatedRooms[2] })
    lu.assertEquals(diverged.state, "desynchronized")
    lu.assertEquals(diverged.firstMismatch.disposition, "playerDivergence")
end

function TestSession.testChaosGenerationBeforeRoomObservationSurvivesUntilExitSelection()
    local source = {
        id = "source", owner = "source-owner", gameName = "F_Test", biomeKey = "F",
        trace = { { kind = "roomEntered" } },
        outgoing = { kind = "batch", owner = "batch-owner", resolvedSharedRewardStoreKey = "RunProgress",
            targets = { {
                exitKey = "exit1", index = 1, type = "ErebusExitDoor", picked = false,
                room = { id = "normal", biomeKey = "F", gameName = "F_Combat01" },
            } },
            additional = { {
                kind = "chaos", key = "chaos", owner = "chaos-owner", picked = true,
                room = { id = "chaos", biomeKey = "F", gameName = "Chaos_01" },
            } },
        },
    }
    local normal = { id = "normal", owner = "normal-owner", gameName = "F_Combat01", biomeKey = "F", outgoing = { kind = "terminal" } }
    local chaos = { id = "chaos", owner = "chaos-owner", gameName = "Chaos_01", biomeKey = "F", outgoing = { kind = "terminal" } }
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", source.id
    state.plan = { planFingerprint = "test-plan" }
    state.roomsById = { source = source, normal = normal, chaos = chaos }
    local run = { CurrentRoom = { Name = "F_Test", RoomSetName = "F", __runPlannerExecutionRoomId = "source" } }
    local game = { RoomData = {
        F_Combat01 = { Name = "F_Combat01", RoomSetName = "F" },
        Chaos_01 = { Name = "Chaos_01", RoomSetName = "F" },
    } }

    -- Native HandleSecretSpawns runs before StartRoomPreLoadBinks.
    local gate = session.chooseNextRoomData(state, run, { ForceNextRoomSet = "Chaos" }, nil, game)
    lu.assertTrue(state.generation.additional.chaos)
    session.observeRoom(state, run, run.CurrentRoom)
    lu.assertTrue(state.generation.additional.chaos)

    -- Ordinary exits are generated later, when the encounter unlocks them.
    local ordinary = session.chooseNextRoomData(state, run, {}, { { Name = "ErebusExitDoor" } }, game)
    lu.assertEquals(ordinary.kind, "handled")
    session.observeExit(state, run, { Name = "SecretDoor", Room = gate.roomData })
    lu.assertEquals(state.state, "synchronized")
    session.commitExit(state)
    lu.assertEquals(state.currentRoomId, "chaos")
end

function TestSession.testFixedPrebossBossPostbossLinksAndTerminalCompletion()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    local preboss = plan.rooms[20]
    local boss = plan.rooms[22]
    local postboss = plan.rooms[23]
    state.currentRoomId = preboss.id
    currentRun.CurrentRoom = { Name = preboss.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = preboss.id }
    local bossData = session.chooseNextRoomData(state, currentRun, {}, nil, game)
    lu.assertEquals(bossData.kind, "handled")
    session.observeExit(state, currentRun, { Room = bossData.roomData })
    session.commitExit(state)
    lu.assertEquals(state.currentRoomId, boss.id)
    currentRun.CurrentRoom = { Name = boss.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = boss.id }
    local postData = session.chooseNextRoomData(state, currentRun, {}, nil, game)
    session.observeExit(state, currentRun, { Room = postData.roomData })
    session.commitExit(state)
    lu.assertEquals(state.currentRoomId, postboss.id)
    currentRun.CurrentRoom = { Name = postboss.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = postboss.id }
    session.observeExit(state, currentRun, { Room = nil })
    session.commitExit(state)
    lu.assertEquals(state.state, "completed")
end

function TestSession.testRunStateDiagnosticsCompareExactCountersAndBags()
    local plan = openingCheckpointsOnly(fixturePlan())
    local first = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    local exit = checkpointSnapshot(plan, plan.rooms[1].trace[#plan.rooms[1].trace])
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, first)
    local state = start(plan, run)
    session.observeRoom(state, run, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(state.state, "synchronized")
    lu.assertTrue(state.diagnostics.roomEntered)
    local opening = plan.rooms[1]
    local doors = { { Name = opening.outgoing.targets[1].type } }
    run.CurrentRoom = { Name = opening.gameName, RoomSetName = opening.biomeKey, __runPlannerExecutionRoomId = opening.id }
    local target = session.chooseNextRoomData(state, run, {}, doors, roomGame(plan))
    session.observeExit(state, run, { Name = doors[1].Name, Room = target.roomData })
    applyRunState(run, exit)
    session.observeBeforeRoomExit(state, run)
    lu.assertEquals(state.state, "synchronized")
    lu.assertTrue(state.diagnostics.beforeRoomExit)
    run.EncounterDepth = exit.counters.routeEncounterDepth + 1
    session.observeBeforeRoomExit(state, run)
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "trace-cursor")
end

function TestSession.testCheckpointFramesApplyOnlyWhenTheirTraceStepIsConsumed()
    local plan = openingCheckpointsOnly(fixturePlan())
    local first = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    local exit = checkpointSnapshot(plan, plan.rooms[1].trace[2])
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, first)
    local state = start(plan, run)
    local room = { Name = plan.rooms[1].gameName, RoomSetName = "F", __runPlannerExecutionRoomId = plan.rooms[1].id }
    run.CurrentRoom = room
    session.observeRoom(state, run, room)
    lu.assertEquals(state.expectedRunStateFrame, 0)
    lu.assertFalse(session.observeRunState(state, run, "beforeRoomExit"))
    lu.assertEquals(state.expectedRunStateFrame, 0)
    state.pendingExit = { sourceId = plan.rooms[1].id, destinationId = plan.rooms[1].outgoing.targets[1].room.id }
    applyRunState(run, exit)
    lu.assertTrue(session.observeBeforeRoomExit(state, run))
    lu.assertEquals(state.expectedRunStateFrame, 1)
    session.observeBeforeRoomExit(state, run)
    lu.assertEquals(state.expectedRunStateFrame, 1)
    lu.assertEquals(state.firstMismatch.checkpoint, "trace-cursor")
end

function TestSession.testRepeatedRoomEntryContactDoesNotReapplyTheOpeningFrame()
    local plan = openingCheckpointsOnly(fixturePlan())
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    local state = start(plan, run)
    local room = { Name = plan.rooms[1].gameName, RoomSetName = "F", __runPlannerExecutionRoomId = plan.rooms[1].id }
    run.CurrentRoom = room
    session.observeRoom(state, run, room)
    local cursor = state.traceCursor
    session.observeRoom(state, run, room)
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.expectedRunStateFrame, 0)
    lu.assertEquals(state.traceCursor, cursor)
    lu.assertNil(state.firstMismatch)
end

function TestSession.testEmptyCheckpointReplacementRetainsTheSessionExpectedState()
    local plan = fixturePlan()
    local firstRoom, secondRoom = plan.rooms[1], plan.rooms[2]
    local beforeEmpty = checkpointSnapshot(plan, firstRoom.trace[#firstRoom.trace])
    local empty = secondRoom.trace[1]
    lu.assertEquals(empty.frame, 2)
    lu.assertEquals(next(empty.replace), nil)
    local run = { CurrentRoom = { Name = secondRoom.gameName, RoomSetName = secondRoom.biomeKey, __runPlannerExecutionRoomId = secondRoom.id } }
    applyRunState(run, checkpointSnapshot(plan, empty))
    local state = start(plan, run)
    state.currentRoomId, state.traceCursor = secondRoom.id, nil
    state.expectedRunState, state.expectedRunStateFrame = beforeEmpty, 1
    session.observeRoom(state, run, run.CurrentRoom)
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.expectedRunStateFrame, 2)
    lu.assertEquals(state.expectedRunState.counters.routeEncounterDepth, beforeEmpty.counters.routeEncounterDepth)
end

function TestSession.testRunStateArcanaAutomaticOriginUsesCardDeclaration()
    local plan = openingCheckpointsOnly(fixturePlan())
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    snapshot.arcana.active = { { key = "AutoCard", origin = "automatic", rarity = "Common" } }
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    _G.MetaUpgradeCardData.AutoCard.AutoEquipRequirements = { { "example" } }
    local state = start(plan, run)
    session.observeRoom(state, run, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testTraceCursorRejectsAnOutOfOrderLifecycleCheckpoint()
    local plan = fixturePlan()
    local state, run = start(plan)
    local opening = plan.rooms[1]
    run.CurrentRoom = {
        Name = opening.gameName, RoomSetName = opening.biomeKey,
        __runPlannerExecutionRoomId = opening.id,
    }
    state.pendingExit = { sourceId = opening.id, destinationId = opening.outgoing.targets[1].room.id }
    -- No room-entered observation has consumed the first trace instruction.
    session.observeBeforeRoomExit(state, run)
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "trace-cursor")
end

function TestSession.testMissingRunStateValueIsAConformanceMismatch()
    local plan = fixturePlan()
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    run.EncounterDepth = nil
    local state = start(plan, run)
    session.observeRoom(state, run, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "roomEntered")
    lu.assertEquals(state.firstMismatch.disposition, "conformanceDiscrepancy")

    local missingBagRun = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(missingBagRun, snapshot)
    missingBagRun.RewardStores.MetaProgress = nil
    local missingBagState = start(plan, missingBagRun)
    session.observeRoom(missingBagState, missingBagRun, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(missingBagState.state, "desynchronized")
    lu.assertEquals(missingBagState.firstMismatch.checkpoint, "roomEntered")
    lu.assertEquals(missingBagState.firstMismatch.disposition, "conformanceDiscrepancy")
end

function TestSession.testOpeningWithoutHexUsesNativeAbsentHexDefaults()
    local plan = fixturePlan()
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    run.Hero.SlottedSpell = nil
    run.InvestedTalentPoints, run.AllSpellInvestedCache = nil, nil
    local state = start(plan, run)
    session.observeRoom(state, run, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testUnusedArtificerUsesNativeAbsentCounterAsZero()
    local plan = fixturePlan()
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    snapshot.artificer = { usedCount = 0, remainingCount = 3 }
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    run.MetaConversionUses = nil
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", plan.rooms[1].id, 1
    state.roomsById = { [plan.rooms[1].id] = plan.rooms[1] }
    state.expectedRunState, state.expectedRunStateFrame = snapshot, 0
    state.expectedRunStateCheckpoint = "roomEntered"
    session.observeRunState(state, run, "roomEntered")
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testRunStateExcludesNativeSupportTraitsButDetectsUnexpectedRunTraits()
    local plan = fixturePlan()
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    _G.TraitData = {
        TestKeepsake = { Slot = "Keepsake" },
        TestArcana = { MetaUpgrade = true },
        TestAspect = { Slot = "Aspect" },
        TestFamiliar = { Slot = "Familiar" },
        TestHiddenSupport = { Hidden = true },
        TestHistoryHiddenSupport = { HideInRunHistory = true },
        TestUnexpectedBoon = {},
    }
    for _, key in ipairs({ "TestKeepsake", "TestArcana", "TestAspect", "TestFamiliar",
        "TestHiddenSupport", "TestHistoryHiddenSupport" }) do
        run.Hero.Traits[#run.Hero.Traits + 1] = { Name = key }
    end
    local function observe()
        local state = session.newState()
        state.state, state.currentRoomId, state.traceCursor = "synchronized", plan.rooms[1].id, 1
        state.roomsById = { [plan.rooms[1].id] = plan.rooms[1] }
        state.expectedRunState, state.expectedRunStateFrame = snapshot, 0
        state.expectedRunStateCheckpoint = "roomEntered"
        session.observeRunState(state, run, "roomEntered")
        return state
    end
    run.Hero.GodBoonRarities = { Common = 0, Rare = 0, Epic = 0, Heroic = 0 }
    lu.assertEquals(observe().state, "synchronized")

    run.Hero.GodBoonRarities.Common = 1
    local rarityMismatch = observe()
    lu.assertEquals(rarityMismatch.state, "desynchronized")
    lu.assertEquals(rarityMismatch.firstMismatch.expected.kind, "godRarityCounts")
    run.Hero.GodBoonRarities.Common = 0

    run.Hero.Traits[#run.Hero.Traits + 1] = { Name = "TestUnexpectedBoon" }
    local mismatch = observe()
    lu.assertEquals(mismatch.state, "desynchronized")
    lu.assertEquals(mismatch.firstMismatch.expected.kind, "traitCount:TestUnexpectedBoon")
end

function TestSession.testKeepsakeRackConsumesOnlyAfterNativeCloseVerification()
    local state = session.newState()
    local step = { kind = "keepsakeRackChange", keepsakeKey = "TestKeepsake", equipResults = {} }
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
    state.roomsById = { room = { id = "room", trace = { step } } }
    -- Opening and closing without a changed selection makes no trace contact.
    lu.assertEquals(state.traceCursor, 1)
    session.beginKeepsakeRackChange(state, "TestKeepsake")
    lu.assertEquals(state.traceCursor, 1)
    session.verifyKeepsakeRackChange(state, "TestKeepsake", { Traits = {} })
    lu.assertEquals(state.traceCursor, 2)
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testEncounterPhasesAreObservedInDeclaredOrder()
    local plan = withoutOpeningAcquisition(fixturePlan())
    local state, run = start(plan)
    local opening = plan.rooms[1]
    local room = { Name = opening.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = opening.id }
    applyRunState(run, checkpointSnapshot(plan, opening.trace[1]))
    run.CurrentRoom = room
    session.observeRoom(state, run, room)
    session.observeEncounterStart(state, run, room, { Name = opening.contents.encounterPhases[1].encounterKey })
    session.observeEncounterEnd(state, run, room, { Name = opening.contents.encounterPhases[1].encounterKey })
    lu.assertEquals(state.state, "synchronized")
    local cursor = state.traceCursor
    session.observeEncounterStart(state, run, room, { Name = "WrongEncounter" })
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.traceCursor, cursor)
end

function TestSession.testUntracedNativeNonCombatCallbacksDoNotAdvanceChronology()
    local state = session.newState()
    local room = {
        id = "chaos-room",
        gameName = "Chaos_01",
        contents = { encounterPhases = {
            { slotKey = "Encounter", encounterKey = "Empty_Chaos", kind = "nonCombat" },
        } },
        trace = { { kind = "cleanup", owner = "chaos-room" } },
        outgoing = { kind = "terminal" },
    }
    local observed = { Name = room.gameName, __runPlannerExecutionRoomId = room.id }
    local run = { CurrentRoom = observed }
    state.state, state.currentRoomId, state.traceCursor = "synchronized", room.id, 1
    state.roomsById = { [room.id] = room }

    session.observeEncounterStart(state, run, observed, { Name = "Empty_Chaos" })
    session.observeEncounterEnd(state, run, observed, { Name = "Empty_Chaos" })

    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.traceCursor, 1)
end

function TestSession.testUntracedCombatCallbackIsOnlyASchedulingSignal()
    local state = session.newState()
    local room = {
        id = "combat-room",
        gameName = "F_Combat01",
        contents = { encounterPhases = {
            { slotKey = "Encounter", encounterKey = "GeneratedF", kind = "combat" },
        } },
        trace = { { kind = "cleanup", owner = "combat-room" } },
        outgoing = { kind = "terminal" },
    }
    local observed = { Name = room.gameName, __runPlannerExecutionRoomId = room.id }
    local run = { CurrentRoom = observed }
    state.state, state.currentRoomId, state.traceCursor = "synchronized", room.id, 1
    state.roomsById = { [room.id] = room }

    session.observeEncounterEnd(state, run, observed, { Name = "GeneratedF" })

    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.traceCursor, 1)
end

function TestSession.testCompletedExitBatchIsOneBlockingConformanceCheckpoint()
    local plan = openingCheckpointsOnly(fixturePlan())
    local opening = plan.rooms[1]
    local target = opening.outgoing.targets[1]
    local targetRoom = plan.rooms[2]
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", opening.id
    state.roomsById = { [opening.id] = opening, [targetRoom.id] = targetRoom }
    state.generation = {
        owner = opening.outgoing.owner,
        generated = { [target.index] = true },
        additional = {},
    }
    local observedRoom = { Name = opening.gameName, __runPlannerExecutionRoomId = opening.id }
    local generatedRoom = {
        Name = targetRoom.gameName,
        __runPlannerExecutionRoomId = targetRoom.id,
        ChosenRewardType = targetRoom.contents.incomingReward.rewardType,
        ForceLootName = targetRoom.contents.incomingReward.source,
    }
    session.observeExitsReady(state, { CurrentRoom = observedRoom }, observedRoom, {
        { Name = target.type, Room = generatedRoom },
    })
    lu.assertEquals(state.state, "synchronized")
    lu.assertTrue(state.diagnostics.exitsReady)

    local mismatch = session.newState()
    mismatch.state, mismatch.currentRoomId = "synchronized", opening.id
    mismatch.roomsById = state.roomsById
    mismatch.generation = state.generation
    session.observeExitsReady(mismatch, { CurrentRoom = observedRoom }, observedRoom, {})
    lu.assertEquals(mismatch.state, "desynchronized")
    lu.assertEquals(mismatch.firstMismatch.checkpoint, "exits-ready")
    lu.assertEquals(mismatch.firstMismatch.expected.kind, "exitCount")
end

function TestSession.testChaosReturnBatchMatchesEveryDeclaredPhysicalExitAtOneCheckpoint()
    local plan = fixturePlan("test/fixtures/execution-plan/fg-ixion-chaos.execution.json")
    local chaos
    local roomsById = {}
    for _, room in ipairs(plan.rooms) do
        roomsById[room.id] = room
        if room.gameName == "Chaos_01" then chaos = room end
    end
    lu.assertNotNil(chaos)
    lu.assertEquals(#chaos.outgoing.targets, 2)

    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", chaos.id
    state.roomsById = roomsById
    state.generation = {
        owner = chaos.outgoing.owner,
        generated = { [1] = true, [2] = true },
        additional = {},
    }
    local observedRoom = { Name = chaos.gameName, __runPlannerExecutionRoomId = chaos.id }
    local doors = {}
    for _, expectedExit in ipairs(chaos.outgoing.targets) do
        local target = roomsById[expectedExit.room.id]
        doors[#doors + 1] = {
            Name = "SecretExitDoor",
            Room = {
                Name = target.gameName,
                __runPlannerExecutionRoomId = target.id,
                ChosenRewardType = target.contents.incomingReward.rewardType,
                ForceLootName = target.contents.incomingReward.source,
            },
        }
    end

    session.observeExitsReady(state, { CurrentRoom = observedRoom }, observedRoom, doors)

    lu.assertEquals(state.state, "synchronized")
    lu.assertTrue(state.diagnostics.exitsReady)
end

function TestSession.testFGRoomDataSuppressesExcludedSpontaneousNpcFamiliesWithoutCallbackMatching()
    local plan = withoutOpeningAcquisition(fixturePlan())
    local state, run, game = start(plan)
    local opening = plan.rooms[1]
    game.RoomData[opening.gameName].LegalEncounters = { "NPC_Nemesis_01", "Narcissus" }
    local generated = session.chooseStartingRoom(state, run, { StartingBiome = "F" }, game)
    lu.assertEquals(#generated.LegalEncounters, 1)
    lu.assertEquals(generated.LegalEncounters[1], opening.contents.encounterPhases[1].encounterKey)
    local room = { Name = opening.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = opening.id }
    run.CurrentRoom = room
    applyRunState(run, checkpointSnapshot(plan, opening.trace[1]))
    session.observeRoom(state, run, room)
    session.observeEncounterStart(state, run, room, { Name = "NPC_Nemesis_01" })
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testMultiEncounterAssemblyIsVerifiedAfterVanillaSetup()
    local plan = fixturePlan()
    local state, run = start(plan)
    local room = plan.rooms[1]
    room = { Name = room.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = room.id,
        Encounters = { { Name = room.contents.encounterPhases[1].encounterKey } } }
    run.CurrentRoom = room
    session.verifyEncounterAssembly(state, run, room)
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testMultipleEncounterResolutionUsesOnlyTheFrozenPhase()
    local plan = fixturePlan()
    local state, run = start(plan)
    local expected = plan.rooms[1]
    local room = { Name = expected.gameName, RoomSetName = "F", __runPlannerExecutionRoomId = expected.id }
    run.CurrentRoom = room
    local game = { EncounterData = { [expected.contents.encounterPhases[1].encounterKey] = { Name = expected.contents.encounterPhases[1].encounterKey } } }
    session.beginMultipleEncounterResolution(state, run, room)
    local resolved = session.chooseResolvedEncounter(state, run, room, game)
    session.endMultipleEncounterResolution(state)
    lu.assertEquals(resolved.Name, expected.contents.encounterPhases[1].encounterKey)
    lu.assertEquals(state.state, "synchronized")
end

local function traceState(step)
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", "test"
    state.roomsById = { test = { id = "test", trace = { step } } }
    state.traceCursor = 1
    return state
end

local function ordinaryAction()
    return { id = "ordinary", kind = "acquireReward", roles = { {
        gameName = "ApolloUpgrade", role = "source", settlement = { site = "site", entry = "entry" },
        traitOffer = { kind = "traits", giver = "Apollo", selected = "option1", options = {
            { key = "ApolloWeaponBoon", rarity = "Rare", effectiveLevel = 2 },
            { key = "ApolloSpecialBoon", rarity = "Common", replacement = { replacedTraitKey = "OldSpecial", oldRarity = "Common" } },
        } },
    } } }
end

function TestSession.testOrdinaryLootRealizesExactOptionsAndVerifiesEffectiveLevel()
    local state, loot = traceState(ordinaryAction()), { Name = "ApolloUpgrade" }
    lu.assertEquals(session.prepareLootUse(state, loot).kind, "handled")
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "ApolloWeaponBoon")
    lu.assertEquals(loot.UpgradeOptions[1].Rarity, "Rare")
    lu.assertEquals(loot.UpgradeOptions[1].StackNum, 2)
    lu.assertEquals(loot.UpgradeOptions[2].TraitToReplace, "OldSpecial")
    session.observeTraitSelection(state, "ApolloWeaponBoon")
    session.verifyTraitAcquisition(state, { { Name = "ApolloWeaponBoon", Rarity = "Rare", StackNum = 2 } })
    lu.assertEquals(state.traceCursor, 2)
end

function TestSession.testEncounterOwnedTraitOfferUsesTheFollowingPublishedAcquisition()
    local offer = ordinaryAction().roles[1].traitOffer
    local interaction = {
        id = "artemis", kind = "encounterInteraction", phaseKey = "Encounter",
        resolution = { kind = "traitOffer", offer = offer },
    }
    local acquisition = ordinaryAction()
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
    state.roomsById = { room = {
        id = "room", gameName = "G_Combat01",
        contents = { encounterPhases = { { slotKey = "Encounter" } } },
        outgoing = { kind = "terminal" },
        trace = { interaction, acquisition },
    } }
    local loot = { Name = "NPC_Artemis_Field_01" }
    lu.assertEquals(session.prepareLootUse(state, loot).kind, "handled")
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "ApolloWeaponBoon")
    lu.assertEquals(state.traceCursor, 2)
    session.observeTraitSelection(state, "ApolloWeaponBoon")
    session.verifyTraitAcquisition(state, { { Name = "ApolloWeaponBoon", Rarity = "Rare", StackNum = 2 } })
    lu.assertEquals(state.traceCursor, 3)
    local room = { Name = "G_Combat01", __runPlannerExecutionRoomId = "room" }
    session.observeEncounterInteraction(state, { CurrentRoom = room }, room)
    lu.assertNil(state.encounterInteractionConsumed)
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testNarcissusResolvesItsDescriptorAtInteractionAndLeavesDropsSeparate()
    local offer = ordinaryAction().roles[1].traitOffer
    offer.giver = "Narcissus"
    local interaction = {
        id = "narcissus", kind = "encounterInteraction", phaseKey = "Encounter",
        resolution = { kind = "traitOffer", offer = offer },
    }
    local cleanup = { id = "cleanup", kind = "cleanup" }
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
    state.roomsById = { room = {
        id = "room", gameName = "G_Story01",
        contents = { encounterPhases = { { slotKey = "Encounter" } } },
        outgoing = { kind = "terminal" },
        trace = { interaction, cleanup },
    } }
    local args = { UpgradeOptions = {
        { ItemName = "ApolloWeaponBoon", Rarity = "Common" },
        { ItemName = "ApolloSpecialBoon", Rarity = "Common" },
    } }
    session.prepareNarcissusBenefit(state, args)
    lu.assertEquals(state.traceCursor, 2)
    lu.assertEquals(args.UpgradeOptions[1].Rarity, "Rare")
    session.observeTraitSelection(state, "ApolloWeaponBoon")
    session.verifyTraitAcquisition(state, { { Name = "ApolloWeaponBoon" } })
    lu.assertNil(state.pendingNarcissusOffer)
    lu.assertEquals(state.traceCursor, 2)
    local room = { Name = "G_Story01", __runPlannerExecutionRoomId = "room" }
    session.observeEncounterInteraction(state, { CurrentRoom = room }, room)
    lu.assertNil(state.encounterInteractionConsumed)
    lu.assertEquals(state.traceCursor, 2)
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testAnomalyOutcomeUsesThePublishedSuccessWithoutChangingRewardProvenance()
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", "anomaly"
    state.roomsById = { anomaly = { id = "anomaly", anomaly = { replacedRoomGameName = "G_Combat01", success = true } } }
    local encounter = { CapturePointProgress = 100 }
    session.verifyAnomalyOutcome(state, encounter)
    lu.assertEquals(state.state, "synchronized")
    state.roomsById.anomaly.anomaly.success = false
    encounter.CapturePointProgress = 0
    session.verifyAnomalyOutcome(state, encounter)
    lu.assertEquals(state.state, "synchronized")
    encounter.CapturePointProgress = 100
    session.verifyAnomalyOutcome(state, encounter)
    lu.assertEquals(state.state, "desynchronized")
end

function TestSession.testAnomalyGenerationPreservesItsHiddenOrdinaryReturn()
    local state = session.newState()
    state.state, state.currentRoomId, state.plan = "synchronized", "source", { planFingerprint = "test" }
    state.roomsById = {
        source = {
            id = "source", gameName = "G_Combat01", biomeKey = "G",
            outgoing = { kind = "batch", owner = "batch", targets = {
                { index = 1, exitKey = "exit1", type = "OceanusExitDoor", room = { id = "anomaly" } },
            } },
        },
        anomaly = {
            id = "anomaly", gameName = "B_Combat01", biomeKey = "G",
            anomaly = { replacedRoomGameName = "G_Combat02", success = true },
            outgoing = { kind = "batch", owner = "return", targets = {
                { index = 1, exitKey = "exit1", type = "OceanusExitDoor", room = { id = "return" } },
            } },
        },
        ["return"] = { id = "return", gameName = "G_Combat03", biomeKey = "G", outgoing = { kind = "terminal" } },
    }
    local run = { CurrentRoom = { Name = "G_Combat01", RoomSetName = "G", __runPlannerExecutionRoomId = "source" } }
    local game = { RoomData = {
        B_Combat01 = { Name = "B_Combat01", RoomSetName = "G" },
        G_Combat03 = { Name = "G_Combat03", RoomSetName = "G" },
    } }
    local generated = session.chooseNextRoomData(state, run, { ForceNextRoomSet = "Anomaly" }, { { Name = "OceanusExitDoor" } }, game)
    lu.assertEquals(generated.kind, "handled")
    lu.assertTrue(generated.roomData.__runPlannerExecutionAnomaly)
    state.currentRoomId = "anomaly"
    state.generation = nil -- observeRoom resets per-room batch generation before the hidden return.
    run.CurrentRoom = { Name = "B_Combat01", RoomSetName = "G", __runPlannerExecutionRoomId = "anomaly" }
    local returned = session.chooseNextRoomData(state, run, {}, { { Name = "OceanusExitDoor" } }, game)
    lu.assertEquals(returned.kind, "handled")
    lu.assertEquals(returned.roomData.__runPlannerExecutionRoomId, "return")
end

function TestSession.testNemesisTradeUsesClosedResponseAndExactTrait()
    local interaction = {
        id = "nemesis", kind = "encounterInteraction", phaseKey = "Encounter",
        resolution = { kind = "nemesisRandomEvent", outcome = {
            kind = "traitTrade", traitKey = "ApolloWeaponBoon", response = "accept",
        } },
    }
    local child = { kind = "acquireReward", roles = { { gameName = "HealDrop", role = "self" } } }
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "test", 1
    state.roomsById = { test = { id = "test", trace = { interaction, child } } }
    local source = {}
    local args = {
        GiveOptions = { { TraitName = "Other" }, { TraitName = "ApolloWeaponBoon" } },
        GetOptions = { { Name = "OtherDrop" }, { Name = "HealDrop" } },
    }
    session.prepareNemesisTrade(state, source, args)
    lu.assertNil(source.Accepted)
    lu.assertEquals(#args.GiveOptions, 1)
    lu.assertEquals(args.GiveOptions[1].TraitName, "ApolloWeaponBoon")
    lu.assertEquals(#args.GetOptions, 1)
    lu.assertEquals(args.GetOptions[1].Name, "HealDrop")
    -- Record the pending outcome as the native post-text interaction seam
    -- would after its validated room contact.
    state.state, state.pendingNemesisOutcome = "synchronized", interaction.resolution.outcome
    session.observeNemesisTraitRemoval(state, "ApolloWeaponBoon")
    lu.assertNil(state.pendingNemesisOutcome)
end

function TestSession.testNemesisFamilyFiltersNativeInteractionLinesBeforeSelection()
    local interaction = {
        id = "nemesis", kind = "encounterInteraction", phaseKey = "Encounter",
        resolution = { kind = "nemesisRandomEvent", outcome = { kind = "freeItem" } },
    }
    local state = traceState(interaction)
    local lines = session.nemesisInteractTextLineSets(state, { Name = "NPC_Nemesis_01" }, {
        NemesisGetFreeItem01 = {}, NemesisBuyItem01 = {}, NemesisDamageContest01 = {},
    })
    lu.assertNotNil(lines.NemesisGetFreeItem01)
    lu.assertNil(lines.NemesisBuyItem01)
    lu.assertNil(lines.NemesisDamageContest01)
end

function TestSession.testNemesisInteractionLinesPassThroughWithoutAnActiveSession()
    local lines = { NemesisGetFreeItem01 = {}, NemesisBuyItem01 = {} }
    lu.assertEquals(session.nemesisInteractTextLineSets(nil, { Name = "NPC_Nemesis_01" }, lines), lines)
end

function TestSession.testNemesisTradeObservesThePlayerResponse()
    local interaction = {
        id = "nemesis", kind = "encounterInteraction", phaseKey = "Encounter",
        resolution = { kind = "nemesisRandomEvent", outcome = { kind = "goldTrade", response = "decline" } },
    }
    local state = traceState(interaction)
    session.verifyNemesisTradeResponse(state, { Accepted = true })
    lu.assertEquals(state.firstMismatch.disposition, "playerDivergence")
end

function TestSession.testNemesisDamageContestObservesThePublishedResult()
    local interaction = {
        id = "nemesis", kind = "encounterInteraction", phaseKey = "Encounter",
        resolution = { kind = "nemesisRandomEvent", outcome = { kind = "damageContest", result = "success" } },
    }
    local state = traceState(interaction)
    session.verifyNemesisDamageContest(state, { DamageContestAmount = 1000, DamageContestArgs = { DamageGoal = 1000 } })
    lu.assertEquals(state.state, "synchronized")
    session.verifyNemesisDamageContest(state, { DamageContestAmount = 999, DamageContestArgs = { DamageGoal = 1000 } })
    lu.assertEquals(state.firstMismatch.disposition, "playerDivergence")
end

function TestSession.testNemesisRewardDropUsesTheFollowingOrdinaryAcquisition()
    for _, outcome in ipairs({
        { kind = "freeItem" },
        { kind = "goldTrade", response = "accept" },
        { kind = "damageTrade", response = "accept" },
        { kind = "traitTrade", traitKey = "ApolloWeaponBoon", response = "accept" },
        { kind = "damageContest", result = "success" },
        { kind = "damageContest", result = "failure" },
    }) do
        local interaction = { id = "nemesis", kind = "encounterInteraction", phaseKey = "Encounter", resolution = { kind = "nemesisRandomEvent", outcome = outcome } }
        local child = { kind = "acquireReward", roles = { { gameName = "HealDrop", role = "self" } } }
        local state = session.newState()
        state.state, state.currentRoomId, state.traceCursor = "synchronized", "room", 1
        state.roomsById = { room = { id = "room", trace = { interaction, child } } }
        local args = { Consumables = { RandomSelection = true, { Name = "Other" }, { Name = "HealDrop" } } }
        session.prepareNemesisRewardDrop(state, args)
        lu.assertEquals(#args.Consumables, 1)
        lu.assertEquals(args.Consumables[1].Name, "HealDrop")
    end
end

function TestSession.testNemesisDeclineDoesNotClaimAChildAcquisition()
    for _, outcome in ipairs({
        { kind = "goldTrade", response = "decline" },
        { kind = "damageTrade", response = "decline" },
        { kind = "traitTrade", traitKey = "ApolloWeaponBoon", response = "decline" },
    }) do
        local interaction = { id = "nemesis", kind = "encounterInteraction", phaseKey = "Encounter", resolution = { kind = "nemesisRandomEvent", outcome = outcome } }
        local state = traceState(interaction)
        local args = { Consumables = { { Name = "HealDrop" } } }
        session.prepareNemesisRewardDrop(state, args)
        lu.assertEquals(args.Consumables[1].Name, "HealDrop")
        lu.assertEquals(state.traceCursor, 1)
    end
end

function TestSession.testSuppressedIncomingRewardBlocksOnlyTheOrdinaryEncounterSpawn()
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", "room"
    state.roomsById = {
        room = {
            id = "room", gameName = "F_Combat01",
            contents = { incomingReward = { rewardType = "Boon", acquisitionEnabled = false } },
        },
    }
    local encounter = { Name = "NemesisRandomEvent" }
    local run = { CurrentRoom = { Name = "F_Combat01", __runPlannerExecutionRoomId = "room", Encounter = encounter } }
    lu.assertEquals(session.prepareIncomingRewardSpawn(state, run, encounter).kind, "suppress")
    lu.assertEquals(session.prepareIncomingRewardSpawn(state, run, { Name = "ProducedPickup" }).kind, "passThrough")
end

function TestSession.testSuccessfulAnomalyAllowsItsEncounterOwnedReward()
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", "room"
    state.roomsById = {
        room = {
            id = "room", gameName = "G_Anomaly01", anomaly = { success = true },
            contents = { incomingReward = { rewardType = "Boon", acquisitionEnabled = false } },
        },
    }
    local encounter = { Name = "AnomalyChallenge" }
    local run = { CurrentRoom = { Name = "G_Anomaly01", __runPlannerExecutionRoomId = "room", Encounter = encounter } }
    lu.assertEquals(session.prepareIncomingRewardSpawn(state, run, encounter).kind, "passThrough")
end

function TestSession.testOrdinaryLootRejectsWrongTrait()
    local state = traceState(ordinaryAction())
    session.prepareLootUse(state, { Name = "ApolloUpgrade" })
    session.observeTraitSelection(state, "ApolloCastBoon")
    lu.assertEquals(state.firstMismatch.disposition, "playerDivergence")
end

function TestSession.testReplacementRequiresThePublishedOldTraitToBeGone()
    local action = ordinaryAction()
    action.roles[1].traitOffer.selected = "option2"
    local state = traceState(action)
    session.prepareLootUse(state, { Name = "ApolloUpgrade" })
    session.observeTraitSelection(state, "ApolloSpecialBoon")
    session.verifyTraitAcquisition(state, {
        { Name = "ApolloSpecialBoon", Rarity = "Common" }, { Name = "OldSpecial", Rarity = "Common" },
    })
    lu.assertEquals(state.firstMismatch.checkpoint, "trait-acquisition")
end

function TestSession.testFallbackGoldIsSelectedAndVerifiedWithoutTraitLookup()
    local step = { id = "fallback", kind = "acquireReward", roles = { { gameName = "ApolloUpgrade", role = "source", settlement = { site = "s", entry = "e" }, traitOffer = { kind = "fallbackGold", giver = "Apollo" } } } }
    local state, loot = traceState(step), { Name = "ApolloUpgrade" }
    session.prepareLootUse(state, loot)
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "FallbackGold")
    session.observeTraitSelection(state, "FallbackGold")
    session.verifyTraitAcquisition(state, {})
    lu.assertEquals(state.state, "synchronized")
    lu.assertNil(state.pendingAcquisition)
end

function TestSession.testPomRequiresExactStackDelta()
    local step = { id = "pom", kind = "acquireReward", roles = { { gameName = "StackUpgrade", role = "self", settlement = { site = "s", entry = "e" }, levelResolution = { offeredTargets = { "ApolloWeaponBoon" }, selectedTarget = "ApolloWeaponBoon", levelCount = 2 } } } }
    local state, loot = traceState(step), { Name = "StackUpgrade" }
    session.prepareLootUse(state, loot)
    lu.assertEquals(loot.StackNum, 2)
    session.observePomSelection(state, "ApolloWeaponBoon", { { Name = "ApolloWeaponBoon", StackNum = 3 } })
    session.verifyPomResolution(state, { { Name = "ApolloWeaponBoon", StackNum = 5 } })
    lu.assertEquals(state.traceCursor, 2)
    lu.assertEquals(state.state, "synchronized")
    lu.assertNil(state.pendingPom)
end

function TestSession.testSimpleConsumableConsumesOnlyAfterConfirmation()
    local step = { id = "minor", kind = "acquireReward", roles = { { gameName = "HealDrop", role = "self", settlement = { site = "s", entry = "e" } } } }
    local state = traceState(step)
    lu.assertEquals(session.prepareLootUse(state, { Name = "HealDrop" }).kind, "handled")
    session.markSimpleAcquisitionContact(state, "HealDrop")
    session.completeSimpleAcquisition(state, "HealDrop")
    lu.assertEquals(state.traceCursor, 2)
end

function TestSession.testCanonicalGStoryEncounterInteractionConsumesOnlyTheDeclaredRow()
    local plan = fixturePlan("test/fixtures/execution-plan/fg.execution.json")
    local story
    for _, room in ipairs(plan.rooms) do if room.gameName == "G_Story01" then story = room end end
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", story.id, 2
    state.roomsById = { [story.id] = story }
    local room = { Name = story.gameName, RoomSetName = "G", __runPlannerExecutionRoomId = story.id }
    session.observeEncounterInteraction(state, { CurrentRoom = room }, room)
    lu.assertEquals(state.traceCursor, 3)
    lu.assertEquals(state.state, "synchronized")
    state.traceCursor = 1
    session.observeEncounterInteraction(state, { CurrentRoom = room }, room)
    lu.assertEquals(state.firstMismatch.checkpoint, "encounter-interaction")
end

function TestSession.testCleanupConsumesAuthoredSkipButRejectsRequiredPickup()
    local skipped = { id = "skip", kind = "acquireReward", roles = { { gameName = "Ignored", role = "self" } } }
    local state = traceState(skipped)
    session.observeCleanup(state, {})
    lu.assertEquals(state.traceCursor, 2)
    local required = { id = "required", kind = "acquireReward", roles = { { gameName = "Required", role = "self", settlement = { site = "s", entry = "e" } } } }
    state = traceState(required)
    session.observeCleanup(state, {})
    lu.assertEquals(state.firstMismatch.checkpoint, "acquisition-window-close")
end

function TestSession.testCleanupPhaseInteractionsAdvanceTheirLifecycleBoundary()
    local cases = {
        {
            step = { kind = "stygianWellPurchase", offerKey = "TemporaryForcedSecretDoorTrait" },
            observe = function(state)
                session.observeStygianWellPurchase(state, "TemporaryForcedSecretDoorTrait")
            end,
        },
        {
            step = { kind = "worldShopPurchase", offerKey = "ShopItem" },
            observe = function(state) session.observeWorldShopPurchase(state, "ShopItem") end,
        },
        {
            step = { kind = "purgingPoolSale", traitKey = "ApolloWeaponBoon" },
            observe = function(state) session.observePurgingPoolSale(state, "ApolloWeaponBoon") end,
        },
    }
    for _, case in ipairs(cases) do
        local state = traceState({ kind = "cleanup" })
        state.roomsById.test.trace[2] = case.step
        case.observe(state)
        lu.assertEquals(state.state, "synchronized")
        lu.assertEquals(state.traceCursor, 3)
    end
end

function TestSession.testCleanupPhaseInteractionStillRejectsAnUncollectedRequiredPickup()
    local state = traceState({
        kind = "acquireReward",
        owner = "required",
        roles = { { settlement = { site = "site", entry = "entry" } } },
    })
    state.roomsById.test.trace[2] = { kind = "cleanup" }
    state.roomsById.test.trace[3] = {
        kind = "stygianWellPurchase",
        offerKey = "TemporaryForcedSecretDoorTrait",
    }
    session.observeStygianWellPurchase(state, "TemporaryForcedSecretDoorTrait")
    lu.assertEquals(state.firstMismatch.checkpoint, "acquisition-window-close")
end

function TestSession.testSteadyGrowthRequiresReturnedAndLiveNextRarity()
    local state = traceState({ kind = "steadyGrowth", source = "SteadyGrowth", target = "ApolloWeaponBoon" })
    _G.GetUpgradedRarity = function() return "Epic" end
    local traits = { { Name = "ApolloWeaponBoon", Rarity = "Rare" } }
    lu.assertEquals(session.prepareSteadyGrowth(state, "SteadyGrowth", {}, traits).kind, "handled")
    traits[1].Rarity = "Epic"
    session.verifySteadyGrowth(state, traits, { Name = "ApolloWeaponBoon", Rarity = "Epic" })
    lu.assertEquals(state.traceCursor, 2)
end

function TestSession.testEmbryoRequiresExactReturnedTraitRarityAndDictionary()
    local state = traceState({ kind = "transcendentEmbryo", target = "ChaosBlessing", rarity = "Heroic" })
    lu.assertEquals(session.prepareEmbryo(state).target, "ChaosBlessing")
    local trait = { Name = "ChaosBlessing", Rarity = "Heroic", FromChaosKeepsake = true }
    session.verifyEmbryo(state, trait, { ChaosBlessing = { trait } })
    lu.assertEquals(state.traceCursor, 2)
end

function TestSession.testRunStateHammerRanksUseLiveHammerRarity()
    local plan = openingCheckpointsOnly(fixturePlan())
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    snapshot.traits.equipped = {
        { traitKey = "HammerOne", rarity = "Common", hammerRank = "RankI" },
        { traitKey = "HammerTwo", rarity = "Legendary", hammerRank = "RankII" },
    }
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    run.Hero.Traits[1].IsHammerTrait, run.Hero.Traits[2].IsHammerTrait = true, true
    local state = start(plan, run)
    session.observeRoom(state, run, { Name = "F_Opening01", RoomSetName = "F", __runPlannerExecutionRoomId = "golden-f-start" })
    lu.assertEquals(state.state, "synchronized")
    run.Hero.Traits[2].Rarity = "Common"
    local mismatch = session.newState()
    mismatch.state, mismatch.currentRoomId, mismatch.traceCursor = "synchronized", plan.rooms[1].id, 1
    mismatch.roomsById = { [plan.rooms[1].id] = plan.rooms[1] }
    mismatch.expectedRunState, mismatch.expectedRunStateFrame, mismatch.expectedRunStateCheckpoint = snapshot, 0, "roomEntered"
    session.observeRunState(mismatch, run, "roomEntered")
    lu.assertEquals(mismatch.firstMismatch.checkpoint, "roomEntered")
end

function TestSession.testRunStateUsesDirectKeepsakeAndHexContacts()
    local plan = openingCheckpointsOnly(fixturePlan())
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", plan.rooms[1].id, 1
    state.roomsById = { [plan.rooms[1].id] = plan.rooms[1] }
    state.expectedRunState, state.expectedRunStateFrame, state.expectedRunStateCheckpoint = snapshot, 0, "roomEntered"
    session.observeRunState(state, run, "roomEntered")
    lu.assertEquals(state.state, "synchronized")

    local mismatch = session.newState()
    mismatch.state, mismatch.currentRoomId, mismatch.traceCursor = "synchronized", plan.rooms[1].id, 1
    mismatch.roomsById = { [plan.rooms[1].id] = plan.rooms[1] }
    mismatch.expectedRunState, mismatch.expectedRunStateFrame, mismatch.expectedRunStateCheckpoint = snapshot, 0, "roomEntered"
    _G.GameState.FatedStatus = "Fated"
    session.observeRunState(mismatch, run, "roomEntered")
    lu.assertEquals(mismatch.firstMismatch.checkpoint, "roomEntered")
end

local function chaosTraceState()
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", "chaos", 1
    state.roomsById = { chaos = { trace = {
        { kind = "acquireReward", roles = {
            {
                gameName = "TrialUpgrade", role = "source", settlement = { site = "s", entry = "e" },
                traitOffer = {
                    kind = "chaos", giver = "Chaos",
                    curseOptions = {
                        { curseKey = "ChaosDamageCurse", requirementCount = 2 },
                        { curseKey = "ChaosDamageCurse", requirementCount = 3 },
                        { curseKey = "ChaosSpeedCurse", requirementCount = 4 },
                    },
                    selected = "option2", selectedCurseValues = { damageTaken = 0.4 },
                    blessingKey = "ChaosExSpeedBlessing", rarity = "Rare",
                    blessingValues = { propertySpeed = 0.6, weaponSpeed = 1.25 },
                },
            },
        } },
    } } }
    return state
end

function TestSession.testChaosOfferKeepsThreeRawPairsAndScopesSelectedPairOperands()
    local state = chaosTraceState()
    local first, selected, third = {}, {}, {}
    local firstPrepared = session.prepareTraitOfferOption(state, 1, first)
    lu.assertEquals(firstPrepared.kind, "handled")
    local prepared = session.prepareTraitOfferOption(state, 2, selected)
    local thirdPrepared = session.prepareTraitOfferOption(state, 3, third)
    lu.assertEquals(thirdPrepared.kind, "handled")
    lu.assertEquals(first.SecondaryItemName, "ChaosDamageCurse")
    lu.assertNil(first.ItemName)
    lu.assertEquals(selected.SecondaryItemName, "ChaosDamageCurse")
    lu.assertEquals(selected.ItemName, "ChaosExSpeedBlessing")
    lu.assertEquals(third.SecondaryItemName, "ChaosSpeedCurse")
    lu.assertNotNil(prepared.chaos)

    local firstCurse = { PropertyChanges = { {} }, AddIncomingDamageModifiers = { ValidWeaponMultiplier = 1 } }
    session.applyProcessedChaosCurse(firstCurse, firstPrepared.chaos)
    lu.assertEquals(firstCurse.RemainingUses, 2)
    lu.assertEquals(firstCurse.AddIncomingDamageModifiers.ValidWeaponMultiplier, 1)
    local curse = { PropertyChanges = { {} }, AddIncomingDamageModifiers = { ValidWeaponMultiplier = 1 } }
    session.applyProcessedChaosCurse(curse, prepared.chaos)
    lu.assertEquals(curse.RemainingUses, 3)
    lu.assertEquals(curse.AddIncomingDamageModifiers.ValidWeaponMultiplier, 1.4)
    local thirdCurse = { PropertyChanges = { {}, {} } }
    session.applyProcessedChaosCurse(thirdCurse, thirdPrepared.chaos)
    lu.assertEquals(thirdCurse.RemainingUses, 4)
    lu.assertNil(thirdCurse.PropertyChanges[2].ChangeValue)
    local blessing = { PropertyChanges = { {} }, WeaponSpeedMultiplier = {} }
    session.applyProcessedChaosBlessing(blessing, prepared.chaos)
    lu.assertEquals(blessing.Rarity, "Rare")
    lu.assertEquals(blessing.PropertyChanges[1].ChangeValue, 0.6)
    lu.assertEquals(blessing.WeaponSpeedMultiplier.Value, 1.25)
end

function TestSession.testChaosReservationKeepsNativePeersDistinct()
    local state = chaosTraceState()
    state.pendingAcquisition = {
        role = state.roomsById.chaos.trace[1].roles[1],
    }
    local loot = { UpgradeOptions = {
        { ItemName = "ChaosWeaponBlessing", Rarity = "Common", Type = "TransformingTrait" },
        { ItemName = "ChaosHealthBlessing", Rarity = "Epic", Type = "TransformingTrait" },
        { ItemName = "ChaosExSpeedBlessing", Rarity = "Heroic", Type = "TransformingTrait" },
    } }
    lu.assertEquals(session.reserveChaosSelectedBlessing(state, loot).kind, "handled")
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "ChaosWeaponBlessing")
    lu.assertEquals(loot.UpgradeOptions[2].ItemName, "ChaosExSpeedBlessing")
    lu.assertEquals(loot.UpgradeOptions[2].Rarity, "Heroic")
    lu.assertEquals(loot.UpgradeOptions[3].ItemName, "ChaosHealthBlessing")
    lu.assertEquals(loot.UpgradeOptions[3].Rarity, "Epic")

    loot.UpgradeOptions = {
        { ItemName = "ChaosWeaponBlessing", Rarity = "Common" },
        { ItemName = "ChaosHealthBlessing", Rarity = "Epic" },
        { ItemName = "ChaosManaBlessing", Rarity = "Rare" },
    }
    lu.assertEquals(session.reserveChaosSelectedBlessing(state, loot).kind, "handled")
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "ChaosWeaponBlessing")
    lu.assertEquals(loot.UpgradeOptions[2].ItemName, "ChaosExSpeedBlessing")
    lu.assertEquals(loot.UpgradeOptions[3].ItemName, "ChaosManaBlessing")

    loot.UpgradeOptions = {
        { ItemName = "ChaosWeaponBlessing", Rarity = "Common" },
        { ItemName = "ChaosHealthBlessing", Rarity = "Epic" },
    }
    lu.assertEquals(session.reserveChaosSelectedBlessing(state, loot).kind, "failed")
    lu.assertEquals(state.state, "desynchronized")
end

function TestSession.testChaosSelectionAndAcquisitionObserveTheNativePair()
    local state = chaosTraceState()
    local prepared = session.prepareTraitOfferOption(state, 2, {})
    local curse = { Name = "ChaosDamageCurse", PropertyChanges = { {} }, AddIncomingDamageModifiers = { ValidWeaponMultiplier = 1 } }
    local blessing = { Name = "ChaosExSpeedBlessing", PropertyChanges = { {} }, WeaponSpeedMultiplier = {} }
    session.applyProcessedChaosCurse(curse, prepared.chaos)
    session.applyProcessedChaosBlessing(blessing, prepared.chaos)
    curse.OnExpire = { TraitData = blessing }
    session.observeTraitSelection(state, "ChaosDamageCurse")
    session.verifyTraitAcquisition(state, { curse })
    lu.assertEquals(state.state, "synchronized")
    lu.assertEquals(state.traceCursor, 2)

    state = chaosTraceState()
    session.prepareTraitOfferOption(state, 2, {})
    session.observeTraitSelection(state, "ChaosSpeedCurse")
    lu.assertEquals(state.state, "desynchronized")
    lu.assertEquals(state.firstMismatch.checkpoint, "chaos-selection")
end

function TestSession.testSharedIxionChaosFixtureGeneratesItsGatePairAndFixedReturn()
    local plan = fixturePlan("test/fixtures/execution-plan/fg-ixion-chaos.execution.json")
    local state, run, game = start(plan)
    local intro = plan.roomsById and plan.roomsById["golden-g-intro"] or nil
    -- The decoder exposes rooms as an array; select the compiled G entry by
    -- its persisted occurrence identity rather than by its repeated game name.
    if intro == nil then
        for _, room in ipairs(plan.rooms) do
            if room.id == "golden-g-intro" then intro = room; break end
        end
    end
    lu.assertNotNil(intro)
    state.currentRoomId = intro.id
    run.CurrentRoom = { Name = intro.gameName, RoomSetName = intro.biomeKey, __runPlannerExecutionRoomId = intro.id }
    local gate = session.chooseNextRoomData(state, run, { ForceNextRoomSet = "Chaos" }, nil, game)
    lu.assertEquals(gate.kind, "handled")
    lu.assertEquals(gate.roomData.__runPlannerExecutionRoomId, "golden-g-intro:chaos")
    lu.assertEquals(gate.roomData.Name, "Chaos_01")

    -- Native generates the additional exit's reward while the source room is
    -- still CurrentRoom. It is the same owned-generation contact as an
    -- ordinary door target, not a mismatch against the source occurrence.
    local reward = session.chooseRoomReward(
        state,
        run,
        gate.roomData,
        game,
        function() return "TrialUpgrade" end,
        "RunProgress",
        {},
        {}
    )
    lu.assertEquals(reward.kind, "handled")
    lu.assertEquals(state.state, "synchronized")

    local chaosRoom = state.roomsById[gate.roomData.__runPlannerExecutionRoomId]
    state.currentRoomId, state.traceCursor = chaosRoom.id, 2
    run.CurrentRoom = gate.roomData
    local first, second, third = {}, {}, {}
    local firstPrepared = session.prepareTraitOfferOption(state, 1, first)
    local secondPrepared = session.prepareTraitOfferOption(state, 2, second)
    local thirdPrepared = session.prepareTraitOfferOption(state, 3, third)
    lu.assertEquals(first.SecondaryItemName, "ChaosNoMoneyCurse")
    lu.assertEquals(second.SecondaryItemName, "ChaosHealthCurse")
    lu.assertEquals(third.SecondaryItemName, "ChaosDamageCurse")
    lu.assertEquals(first.ItemName, "ChaosWeaponBlessing")
    lu.assertNil(second.ItemName)
    lu.assertNil(third.ItemName)
    lu.assertNotNil(firstPrepared.chaos)
    lu.assertNotNil(secondPrepared.chaos)
    lu.assertNotNil(thirdPrepared.chaos)
    local curse = {
        Name = "ChaosNoMoneyCurse",
        OnExpire = {
            TraitData = {
                Name = "ChaosWeaponBlessing",
                Rarity = "Common",
                AddOutgoingDamageModifiers = { ValidWeaponMultiplier = 1.2 },
            },
        },
    }
    session.applyProcessedChaosCurse(curse, firstPrepared.chaos)
    session.observeTraitSelection(state, "ChaosNoMoneyCurse")
    session.verifyTraitAcquisition(state, { curse })
    lu.assertEquals(state.state, "synchronized")

    local diverged = session.newState()
    diverged.state, diverged.currentRoomId, diverged.traceCursor = "synchronized", chaosRoom.id, 2
    diverged.roomsById = { [chaosRoom.id] = chaosRoom }
    session.prepareTraitOfferOption(diverged, 2, {})
    session.observeTraitSelection(diverged, "ChaosHealthCurse")
    lu.assertEquals(diverged.firstMismatch.disposition, "playerDivergence")

    state.currentRoomId, state.generation = chaosRoom.id, nil
    -- ChaosReturnExitDoor is the plan's semantic visible-return type; the
    -- native map obstacle is SecretExitDoor.
    local returned = session.chooseNextRoomData(state, run, {}, { { Name = "SecretExitDoor" } }, game)
    lu.assertEquals(returned.kind, "handled")
    lu.assertEquals(returned.roomData.__runPlannerExecutionRoomId, "golden-g-b2-e1")
    lu.assertEquals(returned.roomData.Name, "G_Combat02")
end

function TestSession.testSharedIxionChaosFixtureRunStateDetectsCounterRangeTraitAndRetainedMismatches()
    local plan = fixturePlan("test/fixtures/execution-plan/fg-ixion-chaos.execution.json")
    local chaosRoom
    for _, room in ipairs(plan.rooms) do
        if room.id == "golden-g-intro:chaos" then chaosRoom = room; break end
    end
    lu.assertNotNil(chaosRoom)
    local snapshot = checkpointSnapshot(plan, chaosRoom.trace[1])
    -- The comparison is bounded to the compiled diagnostic, so a test-only
    -- range proves acceptance within bounds without asking the module to
    -- reconstruct reward-bag policy.
    snapshot.bags[1].remaining = { kind = "range", min = snapshot.bags[1].remaining.count - 1, max = snapshot.bags[1].remaining.count + 1 }
    local run = { CurrentRoom = { Name = chaosRoom.gameName, RoomSetName = chaosRoom.biomeKey, __runPlannerExecutionRoomId = chaosRoom.id } }
    local function applyRangeSnapshot()
        local range = snapshot.bags[1].remaining
        snapshot.bags[1].remaining = { kind = "exact", count = range.min }
        applyRunState(run, snapshot)
        snapshot.bags[1].remaining = range
    end
    applyRangeSnapshot()
    local function stateForDiagnostic()
        local state = session.newState()
        state.state, state.currentRoomId, state.traceCursor = "synchronized", chaosRoom.id, 1
        state.roomsById = { [chaosRoom.id] = chaosRoom }
        state.expectedRunState, state.expectedRunStateFrame, state.expectedRunStateCheckpoint = snapshot, chaosRoom.trace[1].frame, "roomEntered"
        return state
    end
    local exact = stateForDiagnostic()
    session.observeRunState(exact, run, "roomEntered")
    lu.assertEquals(exact.state, "synchronized")

    local counter = stateForDiagnostic()
    run.EncounterDepth = run.EncounterDepth + 1
    session.observeRunState(counter, run, "roomEntered")
    lu.assertEquals(counter.firstMismatch.disposition, "conformanceDiscrepancy")
    applyRangeSnapshot()

    local bag = stateForDiagnostic()
    for index = 1, snapshot.bags[1].remaining.max + 1 do run.RewardStores[snapshot.bags[1].storeKey][index] = {} end
    session.observeRunState(bag, run, "roomEntered")
    lu.assertEquals(bag.firstMismatch.disposition, "conformanceDiscrepancy")
    applyRangeSnapshot()

    local trait = stateForDiagnostic()
    run.Hero.Traits[1].Name = "WrongTrait"
    session.observeRunState(trait, run, "roomEntered")
    lu.assertEquals(trait.firstMismatch.disposition, "conformanceDiscrepancy")
    applyRangeSnapshot()

    local retained = stateForDiagnostic()
    run.BannedTraits = { UnexpectedBan = true }
    session.observeRunState(retained, run, "roomEntered")
    lu.assertEquals(retained.firstMismatch.disposition, "conformanceDiscrepancy")
end

function TestSession.testChaosRunStateComparesNativeActiveAndMaturedStatus()
    local plan = openingCheckpointsOnly(fixturePlan())
    local snapshot = checkpointSnapshot(plan, plan.rooms[1].trace[1])
    snapshot.chaos.active = {
        { curseKey = "ChaosDamageCurse", blessingKey = "ChaosExSpeedBlessing", rarity = "Rare", clock = "encounters", remaining = 2 },
    }
    snapshot.chaos.matured = {}
    local run = { CurrentRoom = { RoomSetName = "F" } }
    applyRunState(run, snapshot)
    -- Chaos traits are intentionally absent from ordinary equipped-trait
    -- diagnostics; their status is compared only through diagnostic.chaos.
    local curse = { Name = "ChaosDamageCurse", Rarity = "Common" }
    table.insert(run.Hero.Traits, curse)
    curse.UsesAsEncounters, curse.RemainingUses = true, 2
    curse.OnExpire = { TraitData = { Name = "ChaosExSpeedBlessing", Rarity = "Rare" } }
    local state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", plan.rooms[1].id, 1
    state.roomsById = { [plan.rooms[1].id] = plan.rooms[1] }
    session.observeRunState(state, run, "roomEntered")
    lu.assertEquals(state.state, "synchronized")

    snapshot.chaos.active = {}
    snapshot.chaos.matured = { { blessingKey = "ChaosExSpeedBlessing", rarity = "Rare" } }
    run.Hero.Traits[#run.Hero.Traits] = { Name = "ChaosExSpeedBlessing", Rarity = "Rare" }
    state = session.newState()
    state.state, state.currentRoomId, state.traceCursor = "synchronized", plan.rooms[1].id, 1
    state.roomsById = { [plan.rooms[1].id] = plan.rooms[1] }
    session.observeRunState(state, run, "roomEntered")
    lu.assertEquals(state.state, "synchronized")
end

function TestSession.testFirstMismatchBlocksFurtherObservation()
    local state = start(fixturePlan())
    session.observeRoom(state, {}, { Name = "WrongRoom", RoomSetName = "F" })
    local first = state.firstMismatch
    lu.assertEquals(first.disposition, "conformanceDiscrepancy")
    session.observeRoom(state, {}, { Name = "F_Opening01", RoomSetName = "F" })
    lu.assertEquals(state.firstMismatch, first)
    lu.assertEquals(state.state, "desynchronized")
end

function TestSession.testInventoryGenerationConstrainsNativeCandidatesBeforeRecordsAreBuilt()
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", "shop"
    state.roomsById = { shop = { contents = { shop = { offers = {
        { offerKey = "one", optionKey = "RandomLoot", source = "ApolloUpgrade" },
        { offerKey = "two", optionKey = "RoomRewardHealDrop" },
        { offerKey = "three", optionKey = "MaxManaDrop" },
    } } } } }
    local args = { StoreData = { GroupsOf = {
        { OptionsData = { { Name = "RandomLoot" }, { Name = "BlindBoxLoot" } } },
        { OptionsData = { { Name = "RoomRewardHealDrop" }, { Name = "MaxHealthDrop" } } },
        { OptionsData = { { Name = "MaxManaDrop" }, { Name = "SpellDrop" } } },
    } } }
    local generation = session.prepareInventoryGeneration(state, args, false)
    lu.assertEquals(generation.kind, "handled")
    lu.assertEquals(generation.args.StoreData.GroupsOf[1].OptionsData[1].Name, "RandomLoot")
    lu.assertEquals(#generation.args.StoreData.GroupsOf[1].OptionsData, 1)
    lu.assertEquals(session.chooseInventoryGod(state, generation), "ApolloUpgrade")
    local nativeRecords = { StoreOptions = {
        { Name = "RandomLoot", Args = { ForceLootName = "ApolloUpgrade" } },
        { Name = "RoomRewardHealDrop" }, { Name = "MaxManaDrop" },
    } }
    local verified = session.verifyInventoryGeneration(state, generation, nativeRecords)
    lu.assertEquals(verified.kind, "handled")
    lu.assertEquals(state.state, "synchronized")
    nativeRecords.StoreOptions[2].Name = "MaxHealthDrop"
    session.verifyInventoryGeneration(state, generation, nativeRecords)
    lu.assertEquals(state.firstMismatch.checkpoint, "inventory-generation")
end

function TestSession.testInitialWellGenerationExcludesTravelDealRefillAndRefillUsesItsPhysicalSlot()
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", "well"
    state.roomsById = { well = { contents = { stygianWell = { interacted = true, offers = {
        { generationKey = "initial:healing", offerKey = "Heal" },
        { generationKey = "initial:secondLeft", offerKey = "Left" },
        { generationKey = "initial:secondRight", offerKey = "Right" },
        { generationKey = "travelDealRefill", offerKey = "Refill" },
    } } } } }
    local args = { StoreData = {
        HealingOffers = { WeightedList = { { Name = "Heal" }, { Name = "WrongHeal" } } },
        Traits = { "Left", "WrongTrait" }, Consumables = { "Right", "WrongConsumable" },
    } }
    local generation = session.prepareInventoryGeneration(state, args, false)
    lu.assertEquals(generation.kind, "handled")
    lu.assertEquals(generation.args.StoreData.HealingOffers.WeightedList[1].Name, "Heal")
    lu.assertNil(generation.args.StoreData.Traits[2])
    lu.assertEquals(generation.args.StoreData.Consumables[1], "Right")
    lu.assertEquals(#generation.well.offers, 4)
    local crossCategory = session.orderWellInventoryGeneration(generation, { StoreOptions = {
        { Name = "Heal" }, { Name = "Right" }, { Name = "Left" },
    } })
    lu.assertEquals(crossCategory.StoreOptions[2].Name, "Left")
    lu.assertEquals(crossCategory.StoreOptions[3].Name, "Right")

    state.roomsById.well.contents.stygianWell.offers[2].offerKey = "SecondRight"
    state.roomsById.well.contents.stygianWell.offers[3].offerKey = "SecondLeft"
    generation = session.prepareInventoryGeneration(state, args, false)
    local sameCategory = session.orderWellInventoryGeneration(generation, { StoreOptions = {
        { Name = "Heal" }, { Name = "SecondLeft" }, { Name = "SecondRight" },
    } })
    lu.assertEquals(sameCategory.StoreOptions[2].Name, "SecondRight")
    lu.assertEquals(sameCategory.StoreOptions[3].Name, "SecondLeft")

    state.roomsById.well.contents.shop = { offers = {
        { offerKey = "a", optionKey = "RandomLoot", source = "ApolloUpgrade" },
        { offerKey = "b", optionKey = "RoomRewardHealDrop" },
    }, travelDealRefill = {
        sourceOfferKey = "a", slotIndex = 0, optionKey = "RoomRewardHealDrop",
        reward = { rewardType = "MajorNonBoon", producerLifecycleKey = "Shop" },
    } }
    state.pendingTravelDealRefill = state.roomsById.well.contents.shop.travelDealRefill
    local refill = session.prepareInventoryGeneration(state, { StoreData = { GroupsOf = {
        { OptionsData = { { Name = "RandomLoot" }, { Name = "RoomRewardHealDrop" } } },
        { OptionsData = { { Name = "MaxManaDrop" } } },
    } } }, true)
    lu.assertEquals(refill.kind, "handled")
    lu.assertEquals(refill.args.StoreData.GroupsOf[1].OptionsData[1].Name, "RoomRewardHealDrop")
    lu.assertEquals(#refill.args.StoreData.GroupsOf[1].OptionsData, 1)
end

function TestSession.testUninteractedWellAndPoolKeepNativeInventoryUnconstrained()
    local state = session.newState()
    state.state, state.currentRoomId = "synchronized", "runtime-random"
    state.roomsById = { ["runtime-random"] = { contents = {
        stygianWell = { interacted = false },
        purgingPool = { interacted = false },
    } } }
    local well = session.prepareInventoryGeneration(state, { StoreData = {} }, false)
    lu.assertEquals(well.kind, "passThrough")
    local room = { SellOptions = { { Name = "TraitA" } } }
    local pool = session.applyPurgingPoolInventory(state, room)
    lu.assertEquals(pool.kind, "passThrough")
    lu.assertEquals(room.SellOptions[1].Name, "TraitA")
end

function TestSession.testForcedRewardAndFixedLinkMismatchesAreConformanceDiscrepancies()
    local plan = fixturePlan()
    local state, currentRun, game = start(plan)
    local opening = session.chooseStartingRoom(state, currentRun, {}, game)
    currentRun.CurrentRoom = opening
    local reward = session.chooseRoomReward(
        state, currentRun, opening, game,
        function() return { Name = "Boon" } end, "MetaProgress", {}, {}
    )
    lu.assertEquals(reward.kind, "failed")
    lu.assertEquals(state.firstMismatch.disposition, "conformanceDiscrepancy")

    local fixedState, fixedRun, fixedGame = start(plan)
    local preboss = plan.rooms[20]
    fixedState.currentRoomId = preboss.id
    fixedRun.CurrentRoom = {
        Name = preboss.gameName, RoomSetName = preboss.biomeKey,
        __runPlannerExecutionRoomId = preboss.id,
    }
    local boss = session.chooseNextRoomData(fixedState, fixedRun, {}, nil, fixedGame)
    lu.assertEquals(boss.kind, "handled")
    boss.roomData.__runPlannerExecutionRoomId = "wrong-fixed-room"
    session.observeExit(fixedState, fixedRun, { Room = boss.roomData })
    lu.assertEquals(fixedState.firstMismatch.disposition, "conformanceDiscrepancy")
end

function TestSession.testMalformedAndUnsupportedRunsRemainInactive()
    local cases = {
        { plan = nil, reason = "plan-unavailable:not-published" },
        { plan = { kind = "bad" }, reason = "unsupported-plan" },
    }
    for _, testCase in ipairs(cases) do
        local state = session.newState()
        local loader = testCase.plan == nil
            and { load = function() return false, "not-published" end }
            or planInbox(testCase.plan)
        session.startNewRun(state, { inbox = loader, currentRun = { CurrentRoom = { RoomSetName = "F" } }, args = { StartingBiome = "F" } })
        lu.assertEquals(state.state, "inactive")
        lu.assertEquals(state.reason, testCase.reason)
    end
end

return TestSession
