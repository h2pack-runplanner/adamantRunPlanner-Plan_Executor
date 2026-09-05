-- luacheck: globals TestHookComposition
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local roomHooks = require("mods.room.hooks")
local roomCoordinatorModule = require("mods.room.coordinator")
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local roomFeatureHooks = require("mods.room.features.hooks")
local routeSession = require("mods.route.session")
local timeline = require("mods/hooks_timeline")
local transformations = require("mods.room.timeline.transformations.hooks")
local acquisitions = require("mods.room.timeline.acquisitions.hooks")
local directPickups = require("mods.room.timeline.acquisitions.pickups.hooks")
local chaosAcquisitions = require("mods.room.timeline.acquisitions.traits.chaos")
local traitAcquisitions = require("mods.room.timeline.acquisitions.traits.hooks")
local npcAcquisitions = require("mods.room.timeline.acquisitions.npc.hooks")
local mysteryAcquisitions = require("mods.room.timeline.acquisitions.mystery.hooks")
local featureInventoryHooks = require("mods.room.features.inventory_hooks")
local featureInteractionHooks = require("mods.room.timeline.feature_interactions")
local logic = require("mods/logic")

TestHookComposition = {}

local function capture()
    local names, callbacks = {}, {}
    return {
        hooks = {
            wrap = function(name, id, callback)
                names[name] = names[name] or {}
                names[name][id] = true
                callbacks[name] = callback
            end,
        },
    }, names, callbacks
end

local fakePayloads = setmetatable({}, { __mode = "k" })
local fakeHandles = setmetatable({}, { __mode = "k" })

local function fakeHandle(row)
    if row == nil or fakePayloads[row] ~= nil then return row end
    local handle = fakeHandles[row]
    if handle == nil then
        handle = {}
        fakeHandles[row] = handle
        fakePayloads[handle] = {
            transaction = row.transaction,
            detail = row.detail,
        }
    end
    return handle
end

local function fakePayload(handle)
    return fakePayloads[handle]
end

local function stub()
    return {
        current = function() end,
        expectedOccurrence = function() end,
        proveOverview = function() end,
        additionalRoom = function() end,
        feature = function() end,
        mismatch = function() end,
        bound = function(_, context, native)
            return context and context.bound and context.bound(native) or nil
        end,
        sourceRole = function(_, context, handle, gameName)
            return context and context.sourceRole and context.sourceRole(fakePayload(handle), gameName) or nil
        end,
        resolve = function(_, context, contact)
            return context and context.resolve and context.resolve(contact) or nil
        end,
        bind = function(_, context, handle, native)
            return context and context.bind and context.bind(handle, native) or handle
        end,
        begin = function(_, handle)
            return fakePayload(handle)
        end,
        activePhase = function() return nil end,
        peek = function(_, handle) return fakePayload(handle) end,
    }
end

-- This composition harness intentionally knows no Timeline contact namespaces.
-- Each witness supplies its one expected opaque handle relation explicitly.
local function opaque(active, resolve, initial)
    local native = {}
    for value, handle in pairs(initial or {}) do native[value] = fakeHandle(handle) end
    active.resolve = function(contact)
        local forwarded = contact
        if contact and contact.source then
            forwarded = {}
            for key, value in pairs(contact) do forwarded[key] = value end
            forwarded.source = fakePayload(contact.source)
        end
        return fakeHandle(resolve(forwarded))
    end
    active.bound = function(value) return native[value] end
    active.bind = function(handle, value)
        handle = fakeHandle(handle)
        if handle ~= nil and value ~= nil then native[value] = handle end
        return handle
    end
    active.sourceRole = function(payload, gameName)
        for _, role in ipairs(payload and payload.transaction and payload.transaction.roles or {}) do
            if role.gameName == gameName then return role.role end
        end
    end
    active.bindingFor = function(value) return native[value] end
    return active
end

local navigationEntryStub = {
    realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
    proveIncomingReward = function() return true end,
}

local function attachRewardHooks(module, session, getState, report)
    timeline.attach(module, session, getState, report, session)
    navigation.attach(module, session, getState, report,
        { reportDestination = function() return true end }, session)
end

local function attachFeatureHooks(module, session, getState, report, room, route)
    local inventoryBindings = featureInventoryHooks.attach(module, session, getState, report, room, route)
    featureInteractionHooks.attach(module, session, getState, report, room, inventoryBindings)
    return inventoryBindings
end

function TestHookComposition.testDoorChoiceIsForcedDuringNativeGeneration()
    local module, _, callbacks = capture()
    local selected, mismatch
    local target = { room = { id = "next", gameName = "F_Next" }, reward = { rewardType = "Boon" } }
    local active = { occurrence = {
        overview = { additional = {} },
        doors = { kind = "batch", targets = { target } },
    } }
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local room = {
        current = function() return active end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local state = { state = "synchronized", plan = { occurrencesById = { next = {} } }, route = {} }
    navigation.attach(module, session, function() return state end, function() end,
        {
            current = function() return active.occurrence end,
            reportDestination = function() return true end,
        }, room)
    local priorMap, priorGame, priorCollapse = _G.MapState, _G.game, _G.CollapseTableOrdered
    local physicalDoor = { ObjectId = 101 }
    _G.MapState = { OfferedExitDoors = { [101] = physicalDoor } }
    _G.game = { RoomData = { F_Next = { GenusName = "F_Next" } } }
    _G.CollapseTableOrdered = function(values)
        lu.assertEquals(values[101], physicalDoor)
        return { physicalDoor }
    end
    callbacks.DoUnlockRoomExits(nil, {}, function()
        selected = callbacks.ChooseNextRoomData(nil, {}, function() return nil end, {}, {}, {})
        physicalDoor.Room = selected
        physicalDoor.RewardType = "Boon"
        return true
    end, {}, {})
    _G.MapState, _G.game, _G.CollapseTableOrdered = priorMap, priorGame, priorCollapse
    lu.assertEquals(selected.__runPlannerExecutionRoomId, "next")
    lu.assertNil(mismatch)
    lu.assertEquals(physicalDoor.Room.__runPlannerExecutionRoomId, "next")
end

function TestHookComposition.testDoorUseReportsSelectionWithoutAdvancingTheRouteCursor()
    local module, _, callbacks = capture()
    local first = {
        id = "first", gameName = "F_First",
        overview = { additional = {} },
        doors = { kind = "fixed", target = { id = "second", gameName = "F_Second" } },
    }
    local second = { id = "second", gameName = "F_Second" }
    local plan = {
        selectedOccurrenceIds = { "first", "second" },
        occurrencesById = { first = first, second = second },
    }
    local routeState = routeSession.new(plan)
    lu.assertEquals(routeSession.enter(routeState, "first", "F_First"), first)
    local active = { occurrence = first }
    local state = { state = "synchronized", route = routeState, plan = plan }
    local room = {
        current = function() return active end,
        checkpoint = function() return true end,
    }
    navigation.attach(module, stub(), function() return state end, function() end,
        routeSession, room)

    local door = { Room = { __runPlannerExecutionRoomId = "second" } }
    lu.assertEquals(callbacks.UseExitDoor(nil, {}, function() return "native" end, door, {}), "native")

    lu.assertEquals(routeState.index, 1)
    lu.assertEquals(routeState.currentOccurrence, first)
    lu.assertEquals(routeState.selectedDestinationId, "second")
    lu.assertEquals(active.occurrence, first)
end

function TestHookComposition.testChaosDoorIsExcludedAfterNormalDoorGeneration()
    local module, _, callbacks = capture()
    local additional = {
        owner = "chaos-exit", kind = "chaos",
        room = { id = "chaos", gameName = "Chaos_01" },
    }
    local occurrence = {
        id = "opening", overview = { additional = { additional } },
        doors = { kind = "batch", targets = {
            { room = { id = "next", gameName = "F_Next" } },
        } },
    }
    local active = { occurrence = occurrence }
    local mismatch
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local room = {
        current = function() return active end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local state = {
        state = "synchronized", route = {},
        plan = { occurrencesById = { next = {}, chaos = {} } },
    }
    local selectedDestination
    local priorGame = _G.game
    _G.game = { RoomData = { F_Next = { GenusName = "F_Next" } } }
    navigation.attach(module, session, function() return state end, function() end,
        {
            current = function() return active.occurrence end,
            reportDestination = function(_, occurrenceId)
                selectedDestination = occurrenceId
                return true
            end,
        }, room)

    local normalDoor = { ObjectId = 101 }
    local chaosRoom = {
        Name = "Chaos_01", __runPlannerExecutionRoomId = "chaos",
        __runPlannerExecutionAdditionalOwner = "chaos-exit",
        __runPlannerExecutionAdditionalKind = "chaos",
    }
    local chaosDoor = {
        ObjectId = 102, Room = chaosRoom,
        __runPlannerExecutionAdditionalOwner = "chaos-exit",
        __runPlannerExecutionAdditionalKind = "chaos",
    }
    local priorMap, priorCollapse = _G.MapState, _G.CollapseTableOrdered
    _G.MapState = { OfferedExitDoors = { [101] = normalDoor, [102] = chaosDoor } }
    _G.CollapseTableOrdered = function() return { normalDoor, chaosDoor } end
    callbacks.DoUnlockRoomExits(nil, {}, function()
        normalDoor.Room = callbacks.ChooseNextRoomData(nil, {}, function() return nil end, {}, {}, {})
        return true
    end, {}, {})
    callbacks.UseExitDoor(nil, {}, function() return true end, chaosDoor, {})
    _G.MapState, _G.CollapseTableOrdered, _G.game = priorMap, priorCollapse, priorGame

    lu.assertNil(mismatch)
    lu.assertEquals(normalDoor.Room.__runPlannerExecutionRoomId, "next")
    lu.assertEquals(chaosDoor.Room.__runPlannerExecutionRoomId, "chaos")
    lu.assertEquals(selectedDestination, "chaos")
end

function TestHookComposition.testRoomSessionStartsBeforeNativeFeatureSpawns()
    local module, _, callbacks = capture()
    local entered, proved = false, false
    local occurrence = { id = "opening", gameName = "F_Opening01" }
    local additional = { room = { id = "chaos", gameName = "Chaos_01" } }
    local session = stub()
    local route = {
        expected = function() return occurrence end,
        enter = function(_, id, gameName)
            lu.assertEquals(id, "opening")
            lu.assertEquals(gameName, "F_Opening01")
            return occurrence
        end,
    }
    local roomSession = {
        enter = function(_, enteredOccurrence)
            lu.assertEquals(enteredOccurrence, occurrence)
            entered = true
            return true
        end,
        additional = function()
            if entered then return additional.room, additional end
            return nil
        end,
        proveEntry = function(_, nativeRoom)
            proved = true
            lu.assertEquals(nativeRoom.__runPlannerExecutionRoomId, "opening")
            return true
        end,
    }
    local state = { state = "synchronized", route = {} }
    local featureScope = roomFeatureHooks.attach(module, session, function() return state end, function() end,
        roomSession)
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, featureScope, navigationEntryStub)

    local nativeRoom = { Name = "F_Opening01", __runPlannerExecutionRoomId = "opening" }
    local eligible
    callbacks.StartRoom(nil, {}, function()
        callbacks.HandleSecretSpawns(nil, {}, function()
            eligible = callbacks.IsSecretDoorEligible(nil, {}, function() return false end, {}, nativeRoom)
        end, {})
    end, {}, nativeRoom)

    lu.assertTrue(entered)
    lu.assertTrue(proved)
    lu.assertTrue(eligible)
end

function TestHookComposition.testCreateRoomReappliesForcedAndSuppressedResourceOutcomes()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening", gameName = "F_Opening01",
        overview = {
            encounterPhases = {}, requiredObjects = {}, additional = {},
            resources = {
                { acquisitionRole = "ore", grantedTraitKey = "FireEssence", contributions = {} },
            },
        },
    }
    local plan = { occurrencesById = { opening = occurrence } }
    local state = {
        state = "synchronized", plan = plan,
        room = roomCoordinatorModule.new(plan, function() end, {}),
    }
    local priorGame = _G.game
    _G.game = { RoomData = { F_Opening01 = { Name = "F_Opening01" } } }
    roomHooks.attach(module, stub(), function() return state end, function() end,
        {}, roomCoordinatorModule, nil, navigationEntryStub)

    local result = callbacks.CreateRoom(nil, {}, function(roomData)
        lu.assertTrue(roomData.PickaxePointSuccess)
        lu.assertFalse(roomData.FishingPointSuccess)
        return {
            Name = roomData.Name,
            PickaxePointSuccess = false,
            FishingPointSuccess = true,
        }
    end, { Name = "F_Opening01", __runPlannerExecutionRoomId = "opening" }, {})
    _G.game = priorGame

    lu.assertTrue(result.PickaxePointSuccess)
    lu.assertFalse(result.FishingPointSuccess)
    lu.assertEquals(result.__runPlannerExecutionRoomId, "opening")
end

function TestHookComposition.testIncomingRewardProofRemainsNavigationOwnedAtRoomEntry()
    local module, _, callbacks = capture()
    local occurrence = { id = "opening", gameName = "F_Opening01" }
    local state = { state = "synchronized", route = {} }
    local mismatch, roomProof
    local session = stub()
    session.mismatch = function(_, errorValue)
        mismatch = errorValue
        state.state = "desynchronized"
    end
    local route = {
        expected = function() return occurrence end,
        enter = function() return occurrence end,
    }
    local roomSession = {
        enter = function() return true end,
        proveEntry = function() roomProof = true; return true end,
    }
    local navigationEntry = {
        realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
        proveIncomingReward = function()
            return nil, { kind = "incomingReward", expected = "Boon", observed = "WeaponUpgrade" }
        end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, nil, navigationEntry)

    callbacks.StartRoom(nil, {}, function() return true end, {}, {
        Name = "F_Opening01", __runPlannerExecutionRoomId = "opening",
    })

    lu.assertEquals(mismatch.kind, "incomingReward")
    lu.assertNil(roomProof)
end

function TestHookComposition.testZagreusContractRemainsAnAdditionalDoorDuringNormalDoorProof()
    local module, _, callbacks = capture()
    local additional = {
        owner = "contract-exit", kind = "zagreusContract",
        room = { id = "contract", gameName = "C_Boss01" },
    }
    local occurrence = {
        id = "shop", overview = { additional = { additional } },
        doors = { kind = "batch", targets = {
            { room = { id = "one", gameName = "F_One" } },
            { room = { id = "two", gameName = "F_Two" } },
        } },
    }
    local contractOccurrence = {
        id = "contract", gameName = "C_Boss01",
        overview = { encounterPhases = {}, requiredObjects = {} },
    }
    local state = { state = "synchronized", route = {}, plan = { occurrencesById = {
        shop = occurrence, contract = contractOccurrence, one = {}, two = {},
    } } }
    local active = { occurrence = occurrence }
    local mismatch
    local session = stub()
    session.mismatch = function(_, value) mismatch = value end
    local roomSession = {
        current = function() return active end,
        additional = function()
            return additional, contractOccurrence
        end,
        realize = function(_, target)
            return { Name = target.gameName, GenusName = target.gameName,
                __runPlannerExecutionRoomId = target.id }
        end,
        realizeFeatures = function(_, nativeRoom) return nativeRoom end,
        checkpoint = function() return true end,
        window = function() return true end,
    }
    local route = {
        current = function() return active.occurrence end,
        reportDestination = function() return true end,
    }
    local featureScope = roomFeatureHooks.attach(module, session, function() return state end, function() end,
        roomSession)
    local navigationEntry = navigation.attach(module, session, function() return state end, function() end,
        route, roomSession)
    roomHooks.attach(module, session, function() return state end, function() end,
        route, roomSession, featureScope, navigationEntry)

    local contractRoom
    local contractDoor = { ObjectId = 3 }
    callbacks.SpawnZagContract(nil, {}, function()
        contractRoom = callbacks.CreateRoom(nil, {}, function(roomData) return roomData end,
            { Name = "C_Boss01" }, {})
        callbacks.AssignRoomToExitDoor(nil, {}, function(door, createdRoom)
            door.Room = createdRoom
        end, contractDoor, contractRoom)
    end, {}, {})
    lu.assertEquals(contractRoom.__runPlannerExecutionAdditionalOwner, "contract-exit")
    lu.assertEquals(contractRoom.__runPlannerExecutionAdditionalKind, "zagreusContract")
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalOwner, "contract-exit")
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalKind, "zagreusContract")

    local priorMap, priorCollapse, priorGame = _G.MapState, _G.CollapseTableOrdered, _G.game
    local oneDoor, twoDoor = { Room = { Name = "F_One" } }, { Room = { Name = "F_Two" } }
    _G.MapState = { OfferedExitDoors = { oneDoor, twoDoor, contractDoor } }
    _G.CollapseTableOrdered = function(value) return value end
    _G.game = { RoomData = { F_One = {}, F_Two = {} } }
    callbacks.DoUnlockRoomExits(nil, {}, function() return true end, {}, {})
    _G.MapState, _G.CollapseTableOrdered, _G.game = priorMap, priorCollapse, priorGame

    lu.assertNil(mismatch)
    lu.assertNil(oneDoor.__runPlannerExecutionAdditionalKind)
    lu.assertNil(twoDoor.__runPlannerExecutionAdditionalKind)
    lu.assertEquals(contractDoor.__runPlannerExecutionAdditionalKind, "zagreusContract")
end

function TestHookComposition.testEncounterForcingKeepsNativeSetupAndGeneration()
    local module, _, callbacks = capture()
    local declaration = { Name = "OpeningGeneratedF", Generated = true }
    local occurrence = {
        id = "opening",
        overview = { encounterPhases = { { slotKey = "Encounter", encounterKey = "OpeningGeneratedF" } } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { opening = occurrence } } }
    local active = { occurrence = occurrence }
    local session = stub()
    local boundEncounter
    local roomSession = {
        current = function() return active end,
        encounterAt = function(_, index) return active.occurrence.overview.encounterPhases[index] end,
        bindEncounter = function(_, native, slotKey)
            boundEncounter = { native = native, slotKey = slotKey }
            return active.occurrence.overview.encounterPhases[1]
        end,
        startEncounter = function() return true end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
        encounterIsFinal = function() return true end,
    }
    local priorGame, priorGlobalForce = _G.game, _G.ForceNextEncounter
    _G.game = { EncounterData = { OpeningGeneratedF = declaration } }
    _G.ForceNextEncounter = "DebugEncounter"
    encounterHooks.attach(module, session, function() return state end, function() end, roomSession)

    local run = { ForceNextEncounterData = { Name = "PriorEncounter" } }
    local nativeRoom = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseEncounter(nil, {}, function(currentRun, room, args)
        lu.assertEquals(currentRun.ForceNextEncounterData, declaration)
        lu.assertNil(_G.ForceNextEncounter)
        lu.assertEquals(room, nativeRoom)
        return { Name = declaration.Name, GeneratedWaves = true, Args = args }
    end, run, nativeRoom, { Source = "test" })

    lu.assertTrue(result.GeneratedWaves)
    lu.assertEquals(result.Args.Source, "test")
    lu.assertEquals(run.ForceNextEncounterData.Name, "PriorEncounter")
    lu.assertEquals(_G.ForceNextEncounter, "DebugEncounter")
    lu.assertEquals(boundEncounter.native, result)
    lu.assertEquals(boundEncounter.slotKey, "Encounter")
    _G.game, _G.ForceNextEncounter = priorGame, priorGlobalForce
end

function TestHookComposition.testRoomRewardForcingConsumesTheMatchingNativeBagEntry()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "opening",
        overview = { incomingReward = { rewardType = "WeaponUpgrade" } },
    }
    local state = {
        state = "synchronized",
        plan = { occurrencesById = { opening = occurrence } },
    }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = {},
        RewardStores = {
            RunProgress = { { Name = "Boon" }, { Name = "WeaponUpgrade" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "opening" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, _, rewardStoreName)
        local selected
        for index, reward in ipairs(currentRun.RewardStores[rewardStoreName]) do
            if callbacks.IsRoomRewardEligible(nil, {}, function() return true end,
                currentRun, room, reward, {}, {}) then
                selected = index
                break
            end
        end
        local reward = currentRun.RewardStores[rewardStoreName][selected]
        table.remove(currentRun.RewardStores[rewardStoreName], selected)
        return reward.Name
    end, run, room, "RunProgress", {}, {})

    lu.assertEquals(result, "WeaponUpgrade")
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "Boon" } })
end

function TestHookComposition.testPublishedRewardStoreOverridesAStaleNativeStore()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "target",
        overview = {
            incomingReward = {
                rewardType = "MetaCurrencyDrop",
                resolvedStoreKey = "MetaProgress",
            },
        },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { target = occurrence } } }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local run = {
        RewardPriorities = { "MetaCardPointsCommonDrop", "MetaCurrencyDrop", "Boon" },
        RewardStores = {
            RunProgress = { { Name = "HermesUpgrade" } },
            MetaProgress = { { Name = "MetaCardPointsCommonDrop" }, { Name = "MetaCurrencyDrop" } },
        },
    }
    local room = { __runPlannerExecutionRoomId = "target", RewardStoreName = "RunProgress" }
    local result = callbacks.ChooseRoomReward(nil, {}, function(currentRun, nativeRoom, rewardStoreName)
        lu.assertEquals(rewardStoreName, "MetaProgress")
        lu.assertEquals(nativeRoom.RewardStoreName, "MetaProgress")
        local eligible = {}
        for index, reward in ipairs(currentRun.RewardStores[rewardStoreName]) do
            if callbacks.IsRoomRewardEligible(nil, {}, function()
                -- The native eligibility result is deliberately hostile: the
                -- published reward must own this scoped choice regardless.
                return false
            end, currentRun, nativeRoom, reward, {}, {}) then
                eligible[#eligible + 1] = index
            end
        end
        lu.assertEquals(eligible, { 2 })
        local selected = eligible[1]
        local reward = currentRun.RewardStores[rewardStoreName][selected]
        table.remove(currentRun.RewardStores[rewardStoreName], selected)
        return reward.Name
    end, run, room, "RunProgress", {}, {})

    lu.assertEquals(result, "MetaCurrencyDrop")
    lu.assertEquals(run.RewardStores.MetaProgress, { { Name = "MetaCardPointsCommonDrop" } })
    lu.assertEquals(run.RewardStores.RunProgress, { { Name = "HermesUpgrade" } })
    lu.assertEquals(run.RewardPriorities, { "MetaCardPointsCommonDrop", "MetaCurrencyDrop", "Boon" })
end

function TestHookComposition.testContractTraitAcquisitionDoesNotOwnTheNativeMetaRewardChoice()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "contract",
        overview = { incomingReward = { rewardType = "InfernalContractBoon" } },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { contract = occurrence } } }
    local mismatches = {}
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    session.mismatch = function(_, checkpoint) mismatches[#mismatches + 1] = checkpoint end
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "contract", ForcedReward = "GemPointsBigDrop" }
    local result = callbacks.ChooseRoomReward(nil, {}, function()
        return "GemPointsBigDrop"
    end, {}, room, "MetaProgress", {}, {})

    lu.assertEquals(result, "GemPointsBigDrop")
    lu.assertEquals(mismatches, {})
end

function TestHookComposition.testEffectNeutralBossRewardUsesNativeForcedRewardChoice()
    local module, _, callbacks = capture()
    local occurrence = {
        id = "boss",
        overview = { effectNeutralRequiredReward = true },
    }
    local state = { state = "synchronized", plan = { occurrencesById = { boss = occurrence } } }
    local session = stub()
    session.current = function() return { occurrence = occurrence } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "boss", ForcedReward = "MixerFBossDrop" }
    local baseCalled = false
    local result = callbacks.ChooseRoomReward(nil, {}, function(_, nativeRoom)
        baseCalled = true
        return nativeRoom.ForcedReward
    end, {}, room, "RunProgress", {}, {})

    lu.assertTrue(baseCalled)
    lu.assertEquals(result, "MixerFBossDrop")
end

function TestHookComposition.testRewardSourceUsesTheTargetOccurrenceNotTheCurrentRoom()
    local module, _, callbacks = capture()
    local current = {
        id = "current",
        overview = { incomingReward = { rewardType = "Boon", source = "ApolloUpgrade" } },
    }
    local target = {
        id = "target",
        overview = { incomingReward = { rewardType = "Boon", source = "ZeusUpgrade" } },
    }
    local state = {
        plan = { occurrencesById = { current = current, target = target } },
    }
    local session = stub()
    session.current = function() return { occurrence = current } end
    attachRewardHooks(module, session, function() return state end, function() end)

    local room = { __runPlannerExecutionRoomId = "target" }
    callbacks.SetupRoomReward(nil, {}, function(_, nativeRoom)
        nativeRoom.ForceLootName = "RandomUpgrade"
        return true
    end, {}, room, {}, {})

    lu.assertEquals(room.ForceLootName, "ZeusUpgrade")
end

function TestHookComposition.testWorldShopCompletionUsesCurrentRoomPurchaseCounter()
    local module, _, callbacks = capture()
    local completed
    local node = { owner = "shop", kind = "shopPurchase", offerKey = "Boon" }
    local active = opaque({
        occurrence = { overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
        } } } },
    }, function(contact)
        if contact.kind == "offer" and contact.offerKey == "Boon" then return { transaction = node } end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        completed = { row = row }
        return true
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { StoreItemsPurchased = 0 }, StoreItemsPurchased = 99 }
    local generated = callbacks.FillInShopOptions(nil, {}, function(args)
        return { StoreOptions = { args.StoreData.GroupsOf[1].OptionsData[1] } }
    end, { StoreData = { GroupsOf = { { OptionsData = { { Name = "BlindBoxLoot" } } } } } })
    local itemData = generated.StoreOptions[1]
    lu.assertEquals(itemData.__runPlannerOfferKey, "Boon")
    local world = { ObjectId = 7 }
    callbacks.SpawnStoreItemInWorld(nil, {}, function() return world end, itemData, nil)
    callbacks.RemoveStoreItem(nil, {}, function()
        _G.CurrentRun.CurrentRoom.StoreItemsPurchased = _G.CurrentRun.CurrentRoom.StoreItemsPurchased + 1
    end, { Id = 7 })
    _G.CurrentRun = priorRun
    lu.assertEquals(fakePayload(completed.row).transaction.owner, "shop")
end

function TestHookComposition.testSuccessfulNativeKeepsakeEquipCompletesTheRackTransaction()
    local module, _, callbacks = capture()
    local completed
    local node = {
        owner = "rack", kind = "keepsakeChange", keepsakeKey = "GoldifyKeepsake",
        window = { kind = "standard", phase = "beforeCombat" }, equipResults = {},
    }
    local occurrence = { transactionsByOwner = { rack = node }, timeline = { dependencies = {}, obligations = {} } }
    local plan = { occurrencesById = { one = occurrence } }
    local state = { initialized = true, state = "synchronized", plan = plan, route = {} }
    state.room = roomCoordinatorModule.new(plan, function() end, {})
    assert(roomCoordinatorModule.enter(state, occurrence))
    local session = stub()
    session.defineCache = function() end
    session.get = function() return state end
    session.complete = function(_, handle)
        completed = { handle = handle }
        return true
    end
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    logic.attach(module, { session = session })
    callbacks.EquipKeepsake(nil, {}, function() return true end, {}, "GoldifyKeepsake", {})
    _G.import = priorImport

    lu.assertNotNil(completed.handle)
end

function TestHookComposition.testMysteryBoonPurchaseWaitsForItsTraitResolution()
    local module, _, callbacks = capture()
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    local completions = {}
    local node = {
        owner = "mystery", kind = "shopPurchase", offerKey = "Boon",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            { role = "box", lifecyclePoint = "purchase", gameName = "BlindBoxLoot" },
            {
                role = "hiddenSource", lifecyclePoint = "afterUnwrap", kind = "trait",
                disposition = "normal", gameName = "HeraUpgrade",
                traitOffer = {
                    kind = "traits", giver = "Hera", selected = "option1",
                    options = {
                        { key = "HeraCastBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraSprintBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraManaBoon", rarity = "Common", effectiveLevel = 4 },
                    },
                },
            },
        },
    }
    local occurrence = {
        id = "shop",
        overview = { shop = { offers = { { offerKey = "Boon", optionKey = "BlindBoxLoot" } } } },
        transactionsByOwner = { mystery = node },
        timeline = { transactions = { node }, dependencies = {}, obligations = {} },
    }
    local plan = { occurrencesById = { shop = occurrence } }
    local mismatches = {}
    local room = roomCoordinatorModule.new(plan, function(errorValue, expected, observed)
        mismatches[#mismatches + 1] = { error = errorValue, expected = expected, observed = observed }
    end)
    local state = { state = "synchronized", plan = plan, room = room }
    local active = assert(roomCoordinatorModule.enter(state, occurrence))
    local root = assert(roomCoordinatorModule.resolve(state, active, { kind = "offer", offerKey = "Boon" }))
    local box = { Name = "BlindBoxLoot" }
    local loot = { Name = "HeraUpgrade", GodLoot = true }
    local boxHandle = assert(roomCoordinatorModule.resolve(state, active,
        { kind = "materialized", gameName = box.Name, source = root }))
    lu.assertTrue(roomCoordinatorModule.bind(state, active, boxHandle, box) ~= nil)
    lu.assertNotNil(roomCoordinatorModule.peek(state, boxHandle))
    local session = {
        current = roomCoordinatorModule.current,
        peek = roomCoordinatorModule.peek,
        bind = roomCoordinatorModule.bind,
        bound = roomCoordinatorModule.bound,
        begin = roomCoordinatorModule.begin,
        resolve = roomCoordinatorModule.resolve,
        claimReady = roomCoordinatorModule.claimReady,
        mismatch = function() end,
    }
    session.complete = function(runtimeState, handle)
        completions[#completions + 1] = { handle = handle }
        return roomCoordinatorModule.complete(runtimeState, handle)
    end
    mysteryAcquisitions.attach(module, session, function() return state end, function() end, roomCoordinatorModule)
    local mysteryCallbacks = {
        CreateLoot = callbacks.CreateLoot,
        UseConsumableItem = callbacks.UseConsumableItem,
        ConsumableUsedPresentation = callbacks.ConsumableUsedPresentation,
        UnwrapRandomLoot = callbacks.UnwrapRandomLoot,
        GiveLoot = callbacks.GiveLoot,
    }
    timeline.attach(module, session, function() return state end, function() end, roomCoordinatorModule)
    for name, callback in pairs(mysteryCallbacks) do callbacks[name] = callback end
    traitAcquisitions.attach(module, session, function() return state end, function() end, roomCoordinatorModule)

    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        lu.assertTrue(callbacks.ConsumableUsedPresentation(nil, {}, function() return true end,
            _G.CurrentRun, nativeItem, {}))
        lu.assertNotNil(roomCoordinatorModule.peek(state, boxHandle))
        callbacks.UnwrapRandomLoot(nil, {}, function()
            callbacks.GiveLoot(nil, {}, function(args)
                lu.assertEquals(args.ForceLootName, "HeraUpgrade")
                return callbacks.CreateLoot(nil, {}, function() return loot end, { Name = args.ForceLootName })
            end, {})
        end, nativeItem)
    end, box, {}, {})
    lu.assertEquals(#completions, 0)
    lu.assertTrue(rawequal(roomCoordinatorModule.bound(state, active, loot), boxHandle))
    lu.assertEquals(roomCoordinatorModule.peek(state, boxHandle).detail, node.roles[2])
    callbacks.HandleLootPickup(nil, {}, function() end, _G.CurrentRun, loot, {})
    lu.assertEquals(#completions, 0)
    _G.CurrentRun.Hero.Traits = { { Name = "HeraCastBoon", Rarity = "Common", StackNum = 4 } }
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
        {}, { LootData = loot, Data = { Name = "HeraCastBoon" } }, {})
    lu.assertEquals(#completions, 1)
    lu.assertEquals(mismatches, {})
    _G.CurrentRun = priorRun
end

function TestHookComposition.testDestinationShopInventoryUsesTheNextOccurrenceBeforeRoomEntry()
    local module, _, callbacks = capture()
    local shop = opaque({
        occurrence = { id = "shop", overview = { shop = { offers = {
            { offerKey = "Boon", optionKey = "BlindBoxLoot" },
            { offerKey = "MajorNonBoon", optionKey = "ArmorBoost" },
            { offerKey = "Minor", optionKey = "MaxManaDrop" },
        } } } },
    }, function() return nil end)
    local session = stub()
    session.current = function() return nil end
    session.prepare = function(_, value)
        lu.assertEquals(value, shop.occurrence)
        return shop
    end
    local state = { route = {} }
    local route = { expected = function() return shop.occurrence end }
    attachFeatureHooks(module, session, function() return state end, function() end, session, route)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { __runPlannerExecutionRoomId = "shop" } }
    local result = callbacks.FillInShopOptions(nil, {}, function(args)
        local options = {}
        for _, group in ipairs(args.StoreData.GroupsOf) do options[#options + 1] = group.OptionsData[1] end
        return { StoreOptions = options }
    end, { StoreData = { GroupsOf = {
        { OptionsData = { { Name = "RandomLoot" }, { Name = "BlindBoxLoot" } } },
        { OptionsData = { { Name = "ArmorBoost" }, { Name = "MetaCurrencyDrop" } } },
        { OptionsData = { { Name = "StackUpgrade" }, { Name = "MaxManaDrop" } } },
    } } })
    _G.CurrentRun = priorRun

    lu.assertEquals(result.StoreOptions[1].Name, "BlindBoxLoot")
    lu.assertEquals(result.StoreOptions[2].Name, "ArmorBoost")
    lu.assertEquals(result.StoreOptions[3].Name, "MaxManaDrop")
end

function TestHookComposition.testProcessedWellButtonRetainsItsExactGenerationBinding()
    local module, _, callbacks = capture()
    local completed
    local node = {
        owner = "well-left", kind = "wellPurchase", generationKey = "initial:secondLeft",
        offerKey = "TemporaryEmptySlotDamageTrait", twistResultKey = nil,
    }
    local well = { transaction = node }
    local active = opaque({}, function(contact)
        if contact.kind == "generation" and contact.generationKey == "initial:secondLeft" then return well end
        if contact.kind == "offer" and contact.offerKey == "TemporaryEmptySlotDamageTrait" then return well end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        completed = { row = row }
        return true
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    local raw = {
        Name = "TemporaryEmptySlotDamageTrait",
        __runPlannerOfferKey = "TemporaryEmptySlotDamageTrait",
        __runPlannerGenerationKey = "initial:secondLeft",
    }
    local screen = { Components = {} }
    _G.CurrentRun = {
        WellPurchases = 0,
        CurrentRoom = { Store = { StoreOptions = { raw } } },
    }
    local priorTraitData, priorEligibility = _G.TraitData, _G.IsTraitEligible
    _G.TraitData = { TemporaryEmptySlotDamageTrait = {} }
    _G.IsTraitEligible = function() return true end
    callbacks.CreateStoreButtons(nil, {}, function(nativeScreen)
        local processed = { Name = "TemporaryEmptySlotDamageTrait", Type = "Trait", Processed = true }
        _G.CurrentRun.CurrentRoom.Store.StoreOptions[1] = processed
        nativeScreen.Components.PurchaseButton1 = { Data = processed }
    end, screen, false)

    local item = screen.Components.PurchaseButton1.Data
    lu.assertEquals(item.__runPlannerGenerationKey, "initial:secondLeft")
    callbacks.HandleStorePurchase(nil, {}, function()
        _G.CurrentRun.WellPurchases = _G.CurrentRun.WellPurchases + 1
    end, screen, screen.Components.PurchaseButton1, {})
    _G.TraitData, _G.IsTraitEligible = priorTraitData, priorEligibility
    _G.CurrentRun = priorRun

    lu.assertEquals(fakePayload(completed.row).transaction.owner, "well-left")
end

function TestHookComposition.testRejectedWellPurchaseReportsMismatchWithoutCompleting()
    local module, _, callbacks = capture()
    local completed, mismatch, nativeCalls = 0, 0, 0
    local node = {
        owner = "well-left", kind = "wellPurchase", generationKey = "initial:secondLeft",
        offerKey = "TemporaryEmptySlotDamageTrait", twistResultKey = nil,
    }
    local well = { transaction = node }
    local active = opaque({}, function(contact)
        if contact.kind == "generation" and contact.generationKey == "initial:secondLeft" then return well end
        if contact.kind == "offer" and contact.offerKey == "TemporaryEmptySlotDamageTrait" then return well end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function() completed = completed + 1 end
    session.mismatch = function() mismatch = mismatch + 1 end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    local priorTraitData, priorEligibility = _G.TraitData, _G.IsTraitEligible
    _G.TraitData = { TemporaryEmptySlotDamageTrait = {} }
    _G.IsTraitEligible = function() return false end
    _G.CurrentRun = {
        WellPurchases = 0,
        CurrentRoom = { Store = { StoreOptions = {
            { Name = "TemporaryEmptySlotDamageTrait", __runPlannerOfferKey = "TemporaryEmptySlotDamageTrait",
                __runPlannerGenerationKey = "initial:secondLeft" },
        } } },
    }
    local result = callbacks.HandleStorePurchase(nil, {}, function()
        nativeCalls = nativeCalls + 1
        return true
    end, {}, { Data = _G.CurrentRun.CurrentRoom.Store.StoreOptions[1] }, {})
    _G.TraitData, _G.IsTraitEligible = priorTraitData, priorEligibility
    _G.CurrentRun = priorRun

    lu.assertTrue(result == nil or result == true)
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(completed, 0)
    lu.assertEquals(mismatch, 1)
end

function TestHookComposition.testTravelDealRefillKeepsSlotBindingSeparateFromReplacementItem()
    local module, _, callbacks = capture()
    local completed, refilled
    local node = {
        owner = "travel-refill", kind = "wellRefill", generationKey = "travelDealRefill",
        offerKey = "ShopHermesUpgrade",
    }
    local refill = { transaction = node }
    local active = opaque({
        occurrence = { overview = { shop = {
            offers = { { offerKey = "Boon", optionKey = "BlindBoxLoot" } },
            travelDealRefill = {
                sourceOfferKey = "Boon", slotIndex = 0, optionKey = "ShopHermesUpgrade",
                reward = { rewardType = "ShopHermesUpgrade" },
            },
        } } },
    }, function(contact)
        if contact.kind == "generation" and contact.generationKey == "travelDealRefill" then return refill end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        lu.assertTrue(refilled)
        completed = { row = row }
        return true
    end
    attachFeatureHooks(module, session, function() return {} end, function() end, session)

    callbacks.RestockWorldItem(nil, {}, function()
        refilled = true
        local generated = callbacks.FillInShopOptions(nil, {}, function(args)
            return { StoreOptions = { args.StoreData.GroupsOf[1].OptionsData[1] } }
        end, { StoreData = { GroupsOf = { { OptionsData = {
            { Name = "BlindBoxLoot" }, { Name = "ShopHermesUpgrade" },
        } } } } })
        local item = generated.StoreOptions[1]
        lu.assertEquals(item.__runPlannerOfferKey, "Boon")
        lu.assertEquals(item.__runPlannerGenerationKey, "travelDealRefill")
        callbacks.SpawnStoreItemInWorld(nil, {}, function() return { ObjectId = 73 } end, item, 10)
    end, 1, 10, {})

    lu.assertEquals(fakePayload(completed.row).transaction.owner, "travel-refill")
end

function TestHookComposition.testChaosChoiceCompletesItsBoundOwner()
    local module, _, callbacks = capture()
    local completed = {}
    local chaos = {
        transaction = {
            owner = "chaos",
            resolution = {
                kind = "traitOffer",
                offer = {
                    kind = "chaos", blessingKey = "ChaosSpeedBlessing", rarity = "Rare",
                    blessingValues = {}, selectedCurseValues = {}, selected = "option1",
                    curseOptions = {
                        { curseKey = "ChaosNoMoneyCurse", requirementCount = 1 },
                        { curseKey = "ChaosHealthCurse", requirementCount = 2 },
                        { curseKey = "ChaosDamageCurse", requirementCount = 3 },
                    },
                },
            },
        },
    }
    local active = opaque({}, function() return nil end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        completed[#completed + 1] = { row = row }
        return true
    end
    timeline.attach(module, session, function() return {} end, function() end, session)
    local chaosLoot = {
        Name = "TrialUpgrade",
        UpgradeOptions = {
            { ItemName = "ChaosPeerA", Rarity = "Common" },
            { ItemName = "ChaosPeerB", Rarity = "Common" },
            { ItemName = "ChaosSpeedBlessing", Rarity = "Common" },
        },
    }
    active.bind(chaos, chaosLoot)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    chaosAcquisitions.attach(module, session, function() return {} end, function() end, session)
    callbacks.HandleLootPickup(nil, {}, function()
        local selectedButton
        callbacks.CreateBoonLootButtons(nil, {}, function()
            for index, itemData in ipairs(chaosLoot.UpgradeOptions) do
                local button = callbacks.CreateUpgradeChoiceButton(nil, {}, function(_, _, _, item)
                    return {
                        Data = {
                            Name = item.SecondaryItemName, RemainingUses = ({ 1, 2, 3 })[index],
                            OnExpire = { TraitData = { Name = item.ItemName, Rarity = item.Rarity } },
                        }, LootData = chaosLoot,
                    }
                end, nil, chaosLoot, index, itemData, {})
                selectedButton = index == 1 and button or selectedButton
            end
        end, nil, chaosLoot, false, {})
        _G.CurrentRun.Hero.Traits = { {
            Name = "ChaosNoMoneyCurse", RemainingUses = 1,
            OnExpire = { TraitData = { Name = "ChaosSpeedBlessing", Rarity = "Rare" } },
        } }
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
            nil, selectedButton, {})
    end, {}, chaosLoot, {})
    _G.CurrentRun = priorRun
    lu.assertEquals(fakePayload(completed[1].row).transaction.owner, "chaos")
end

function TestHookComposition.testMysteryBoonBindsItsUnwrappedSourceTraitOffer()
    local module, _, callbacks = capture()
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    local node = {
        owner = "mystery-boon",
        kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            {
                role = "box", lifecyclePoint = "roomRewardPickup", kind = "consumable",
                disposition = "normal", gameName = "BlindBoxLoot",
            },
            {
                role = "hiddenSource", lifecyclePoint = "afterUnwrap", kind = "trait",
                disposition = "normal", gameName = "HeraUpgrade",
                traitOffer = {
                    kind = "traits", giver = "Hera", selected = "option1",
                    options = {
                        { key = "HeraCastBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraSprintBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraManaBoon", rarity = "Common", effectiveLevel = 4 },
                    },
                },
            },
        },
    }
    local occurrence = {
        id = "mystery-room", overview = {}, transactionsByOwner = { [node.owner] = node },
        timeline = { transactions = { node }, dependencies = {}, obligations = {} },
    }
    local plan = { occurrencesById = { [occurrence.id] = occurrence } }
    local mismatches = {}
    local room = roomCoordinatorModule.new(plan, function(errorValue, expected, observed)
        mismatches[#mismatches + 1] = { error = errorValue, expected = expected, observed = observed }
    end)
    local state = { state = "synchronized", plan = plan, room = room }
    local active = assert(roomCoordinatorModule.enter(state, occurrence))
    local box = { Name = "BlindBoxLoot" }
    local loot = { Name = "HeraUpgrade", GodLoot = true }
    local completions = {}
    local session = {
        current = roomCoordinatorModule.current,
        peek = roomCoordinatorModule.peek,
        bind = roomCoordinatorModule.bind,
        bound = roomCoordinatorModule.bound,
        begin = roomCoordinatorModule.begin,
        resolve = roomCoordinatorModule.resolve,
        claimReady = roomCoordinatorModule.claimReady,
        mismatch = function() end,
    }
    session.complete = function(runtimeState, handle)
        completions[#completions + 1] = { handle = handle }
        return roomCoordinatorModule.complete(runtimeState, handle)
    end
    mysteryAcquisitions.attach(module, session, function() return state end, function() end, roomCoordinatorModule)
    local mysteryCallbacks = {
        CreateLoot = callbacks.CreateLoot,
        UseConsumableItem = callbacks.UseConsumableItem,
        ConsumableUsedPresentation = callbacks.ConsumableUsedPresentation,
        UnwrapRandomLoot = callbacks.UnwrapRandomLoot,
        GiveLoot = callbacks.GiveLoot,
    }
    timeline.attach(module, session, function() return state end, function() end, roomCoordinatorModule)
    for name, callback in pairs(mysteryCallbacks) do callbacks[name] = callback end
    traitAcquisitions.attach(module, session, function() return state end, function() end, roomCoordinatorModule)

    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        lu.assertTrue(callbacks.ConsumableUsedPresentation(nil, {}, function() return true end,
            _G.CurrentRun, nativeItem, {}))
        callbacks.UnwrapRandomLoot(nil, {}, function()
            callbacks.GiveLoot(nil, {}, function(args)
                lu.assertEquals(args.ForceLootName, "HeraUpgrade")
                return callbacks.CreateLoot(nil, {}, function() return loot end, { Name = args.ForceLootName })
            end, {})
        end, nativeItem)
    end, box, {}, {})
    lu.assertEquals(#completions, 0)
    local boxHandle = roomCoordinatorModule.bound(state, active, box)
    lu.assertNotNil(boxHandle)
    lu.assertEquals(roomCoordinatorModule.peek(state, boxHandle).detail, node.roles[2])
    lu.assertTrue(rawequal(roomCoordinatorModule.bound(state, active, loot), boxHandle))
    callbacks.HandleLootPickup(nil, {}, function(_, nativeLoot)
        return callbacks.CreateBoonLootButtons(nil, {}, function()
            lu.assertEquals(nativeLoot.UpgradeOptions, {
                { Type = "Trait", ItemName = "HeraCastBoon", Rarity = "Common", StackNum = 4 },
                { Type = "Trait", ItemName = "HeraSprintBoon", Rarity = "Common", StackNum = 4 },
                { Type = "Trait", ItemName = "HeraManaBoon", Rarity = "Common", StackNum = 4 },
            })
        end, {}, nativeLoot, false, {})
    end, _G.CurrentRun, loot, {})
    lu.assertEquals(#completions, 0)
    _G.CurrentRun.Hero.Traits = { { Name = "HeraCastBoon", Rarity = "Common", StackNum = 4 } }
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
        {}, { LootData = loot, Data = { Name = "HeraCastBoon" } }, {})
    lu.assertEquals(#completions, 1)
    lu.assertEquals(mismatches, {})
    _G.CurrentRun = priorRun
end

function TestHookComposition.testEachNativeNpcChoiceFunctionBindsItsPublishedTraitOffer()
    local contacts = {
        ArachneCostumeChoice = "Arachne",
        NarcissusBenefitChoice = "Narcissus",
        MedeaCurseChoice = "Medea",
        CirceBlessingChoice = "Circe",
        IcarusBenefitChoice = "Icarus",
        EchoChoice = "Echo",
    }
    local priorEligibility = _G.IsGameStateEligible
    _G.IsGameStateEligible = function() return true end
    for functionName, giver in pairs(contacts) do
        local module, _, callbacks = capture()
        local state = {}
        local selected = giver .. "Selected"
        local source = { Name = giver }
        local node = {
            owner = giver .. "-offer", kind = "encounterInteraction",
            resolution = {
                kind = "traitOffer",
                offer = {
                    kind = "traits", giver = giver, selected = "option2",
                    options = {
                        { key = giver .. "First" }, { key = selected }, { key = giver .. "Third" },
                    },
                },
            },
        }
        local row = { transaction = node }
        local active = opaque({
            occurrence = { overview = { encounterPhases = {
                { slotKey = "Encounter", encounterKey = giver .. "Encounter" },
            } } },
        }, function(contact)
            if contact.kind == "encounterInteraction" and contact.phaseKey == "Encounter" then return row end
        end)
        local completed
        local session = stub()
        session.current = function() return active end
        session.encounterHandle = function()
            return active.resolve({ kind = "encounterInteraction", phaseKey = "Encounter" })
        end
        session.complete = function(_, actualRow)
            completed = { row = actualRow }
            return true
        end
        timeline.attach(module, session, function() return state end, function() end, session)
        if giver == "Arachne" or giver == "Narcissus" then
            npcAcquisitions.attach(module, session, function() return state end, function() end, session)
        end
        local priorRun = _G.CurrentRun
        _G.CurrentRun = {
            CurrentRoom = { Encounter = { Name = giver .. "Encounter" } },
            Hero = { Traits = {} },
        }
        local args = { UpgradeOptions = {
            { ItemName = giver .. "Third", Marker = 3 },
            { ItemName = giver .. "First", Marker = 1, GameStateRequirements = { "ignored" } },
            { ItemName = selected, Marker = 2, PriorityRequirements = { "ignored" } },
        } }
        callbacks[functionName](nil, {}, function(nativeSource, prepared)
            local function select()
                _G.CurrentRun.Hero.Traits = { { Name = selected } }
                callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
                    { Source = source }, { Data = { Name = selected } }, {})
                return true
            end
            if giver == "Arachne" or giver == "Narcissus" then
                return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(nativeNpc)
                    lu.assertEquals(nativeNpc.UpgradeOptions, {
                        { ItemName = giver .. "First", Marker = 1 },
                        { ItemName = selected, Marker = 2 },
                        { ItemName = giver .. "Third", Marker = 3 },
                    })
                    return select()
                end, nativeSource, prepared)
            end
            lu.assertEquals(prepared.UpgradeOptions, {
                { ItemName = giver .. "First", Marker = 1 },
                { ItemName = selected, Marker = 2 },
                { ItemName = giver .. "Third", Marker = 3 },
            })
            return select()
        end, source, args, { Source = source })
        _G.CurrentRun = priorRun
        lu.assertEquals(fakePayload(completed.row), row, functionName)
    end
    _G.IsGameStateEligible = priorEligibility
end

function TestHookComposition.testIncidentalConsumableDoesNotClaimTheIncomingRewardTransaction()
    local module, _, callbacks = capture()
    local completed = {}
    local node = {
        owner = "hammer",
        producerLifecycleKey = "RoomReward",
        reward = { rewardType = "WeaponUpgrade" },
        roles = {
            { role = "self", lifecyclePoint = "roomRewardPickup", gameName = "WeaponUpgrade" },
        },
    }
    local active = opaque({
        occurrence = {
            overview = {
                incomingReward = { producerLifecycleKey = "RoomReward", rewardType = "WeaponUpgrade" },
            },
        },
    }, function(contact)
        if contact.kind == "producer" and contact.producerLifecycleKey == "RoomReward"
            and contact.rewardType == "WeaponUpgrade" then return { transaction = node } end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        completed[#completed + 1] = { row = row }
    end
    timeline.attach(module, session, function() return {} end, function() end, session)
    directPickups.attach(module, session, function() return {} end, function() end, session)

    local consolation = { Name = "RoomRewardConsolationPrize" }
    callbacks.UseConsumableItem(nil, {}, function() return true end, consolation, {}, {})
    callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, consolation, {})

    lu.assertEquals(completed, {})
    lu.assertNil(active.bindingFor(consolation))
end

function TestHookComposition.testBossWindowUsesTheRoomCoordinator()
    local module, _, callbacks = capture()
    local state = { state = "synchronized" }
    local active = {
        occurrence = {
            overview = {
                encounterPhases = { { slotKey = "Encounter", encounterKey = "Boss" } },
            },
        },
    }
    local opened
    local roomCoordinator = {
        current = function() return active end,
        window = function(_, value) opened = value; return true end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }

    encounterHooks.attach(module, {}, function() return state end, function() end, roomCoordinator)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Encounter = {} } }
    local result = callbacks.Kill(nil, {}, function() return "native-result" end, { IsBoss = true }, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(result, "native-result")
    lu.assertEquals(opened, "bossDefeated:Encounter")
end

function TestHookComposition.testDirectConsumableLevelResolutionForcesAndCompletesThePublishedTarget()
    local module, _, callbacks = capture()
    local target = { Name = "ZeusWeaponBoon", StackNum = 2 }
    local other = { Name = "ApolloSpecialBoon", StackNum = 4 }
    local row = {
        transaction = {
            owner = "room-nectar", kind = "acquisition", producerLifecycleKey = "RoomReward",
            reward = { rewardType = "GiftDrop" }, roles = {},
        },
        detail = {
            gameName = "GiftDrop", disposition = "normal",
            levelResolution = {
                offeredTargets = {}, selectedTarget = target.Name, levelCount = 1,
            },
        },
    }
    row.transaction.roles = { row.detail }
    local item = {
        Name = "GiftDrop",
        UseFunctionArgs = { Thread = true, NumTraits = 1, NumStacks = 9 },
    }
    local active = opaque({
        occurrence = { overview = {} },
    }, function(contact)
        if contact.kind == "offer" and contact.offerKey == "Minor" then return row end
        if contact.kind == "materialized" and contact.source and contact.source.transaction == row.transaction
            and contact.gameName == item.Name then return row end
    end, { [item] = row })
    local completions = {}
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, completedRow)
        completions[#completions + 1] = { row = completedRow }
    end
    acquisitions.attach(module, session, function() return {} end, function() end, session)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { target, other } } }
    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        local threadedArgs = nativeItem.UseFunctionArgs
        callbacks.UseStoreRewardRandomStack(nil, {}, function(directArgs)
            callbacks.AddStackToTraits(nil, {}, function(firstSource, firstArgs)
                firstArgs = firstArgs or firstSource
                lu.assertEquals(firstArgs.TraitName, target.Name)
                lu.assertEquals(firstArgs.NumStacks, 1)
                local realizedArgs = {}
                for key, value in pairs(firstArgs) do realizedArgs[key] = value end
                realizedArgs.Thread = false
                callbacks.AddStackToTraits(nil, {}, function(terminalSource, terminalArgs)
                    terminalArgs = terminalArgs or terminalSource
                    lu.assertEquals(terminalArgs.TraitName, target.Name)
                    lu.assertEquals(terminalArgs.NumStacks, 1)
                    target.StackNum = target.StackNum + terminalArgs.NumStacks
                end, realizedArgs)
            end, directArgs)
        end, threadedArgs, nativeItem)
    end, item, {}, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(item.UseFunctionArgs, { Thread = true, NumTraits = 1, NumStacks = 9 })
    lu.assertEquals(target.StackNum, 3)
    lu.assertEquals(other.StackNum, 4)
    lu.assertEquals(#completions, 1)
    lu.assertEquals(fakePayload(completions[1].row).transaction, row.transaction)
    lu.assertEquals(fakePayload(completions[1].row).detail, row.detail)
end

function TestHookComposition.testExplicitGateBHookGroupsStayInstalled()
    local module, names = capture()
    local session = stub()
    local getState, report = function() end, function() end
    local route = { expected = function() end, reportDestination = function() return true end }
    timeline.attach(module, session, getState, report, session)
    acquisitions.attach(module, session, getState, report, session)
    local transformationScope = transformations.attach(module, session, getState, report, session)
    local featureScope = roomFeatureHooks.attach(module, session, getState, report, session)
    local navigationEntry = navigation.attach(module, session, getState, report, route, session, transformationScope)
    roomHooks.attach(module, session, getState, report, route, session, featureScope, navigationEntry)
    encounterHooks.attach(module, session, getState, report, session)
    attachFeatureHooks(module, session, getState, report, session, route)
    for _, name in ipairs({
        "ChooseStartingRoom", "StartRoom", "DoUnlockRoomExits", "LeaveRoom",
        "StartEncounter", "EndEncounterEffects",
        "UseLoot", "UseConsumableItem", "AddStackToTraits", "HandleLootPickup",
        "ConvertMetaRewardPresentation", "CreateLoot", "UnwrapRandomLoot",
        "ArachneCostumeChoice", "NarcissusBenefitChoice", "MedeaCurseChoice", "CirceBlessingChoice",
        "IcarusBenefitChoice", "EchoChoice", "SpawnNemesisForRandomEvents", "CheckAvailableTextLines",
        "NemesisTradeChoice", "NPCRewardDropPreProcess", "NPCRewardDropPreProcessArgs", "NemesisDamageContestTimer",
        "AddRandomMetaUpgrades", "FillInShopOptions", "CreateStoreButtons", "RestockWorldItem",
        "SpawnStoreItemInWorld", "RemoveStoreItem", "HandleStorePurchase",
    }) do
        lu.assertNotNil(names[name], name)
    end
    lu.assertNil(names.GoldifyPresentation)
    lu.assertNil(names.SetTransformingTraitsOnLoot)
end

function TestHookComposition.testMismatchStopsEnforcementWithoutBlockingNativeRoomFlow()
    local module, _, callbacks = capture()
    local session = stub()
    local getState = function()
        return { state = "desynchronized" }
    end
    local route = { expected = function() end, reportDestination = function() return true end }
    local featureScope = roomFeatureHooks.attach(module, session, getState, function() end, session)
    local navigationEntry = navigation.attach(module, session, getState, function() end, route, session)
    roomHooks.attach(module, session, getState, function() end,
        route, session, featureScope, navigationEntry)

    local starting = callbacks.ChooseStartingRoom(nil, {}, function()
        return { Name = "NativeOpening" }
    end, {}, {})
    local entered = callbacks.StartRoom(nil, {}, function()
        return "native-entry"
    end, {}, { Name = "NativeOpening" })
    local used = callbacks.UseExitDoor(nil, {}, function(door)
        return door.Name
    end, { Name = "NativeDoor" }, {})
    local left = callbacks.LeaveRoom(nil, {}, function()
        return "native-exit"
    end, {}, {})

    lu.assertEquals(starting, { Name = "NativeOpening" })
    lu.assertEquals(entered, "native-entry")
    lu.assertEquals(used, "NativeDoor")
    lu.assertEquals(left, "native-exit")
end

function TestHookComposition.testRoomAfterConfiguredPrefixHandsControlBackToNativeGame()
    local module, _, callbacks = capture()
    local state = { state = "synchronized", route = {}, room = {} }
    local session = stub()
    local enteredRoom = false
    local route = {
        expected = function() return nil end,
        enter = function() return true end,
    }
    local room = {
        enter = function() enteredRoom = true end,
        realize = function() return nil end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, room, { currentAdditional = function() return nil end }, navigationEntryStub)

    local result = callbacks.StartRoom(nil, {}, function()
        return "native-entry"
    end, {}, { Name = "H_Opening01" })

    lu.assertEquals(result, "native-entry")
    lu.assertFalse(enteredRoom)
    lu.assertEquals(state.state, "inactive")
    lu.assertEquals(state.reason, "configured-prefix-complete")
end
