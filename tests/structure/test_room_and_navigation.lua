-- luacheck: globals TestRoomNavigationStructure
local lu = require("luaunit")
local overview = require("mods.room.overview")
local encounters = require("mods.room.encounters")
local features = require("mods.room.features.structure")
local rewards = require("mods.navigation.rewards")
local doors = require("mods.navigation.doors")
local navigationHooks = require("mods.navigation.hooks")
local timelineHooks = require("mods.hooks_timeline")
local featureBindings = require("mods.room.features.native_bindings")
local rewardBindings = require("mods.navigation.native_bindings")

TestRoomNavigationStructure = {}

local function captureHooks()
    local callbacks = {}
    return {
        hooks = {
            wrap = function(name, _, callback) callbacks[name] = callback end,
        },
    }, callbacks
end

local function proveOverview(item, native, nativeContext)
    return overview.prove(item, native)
        and rewards.prove(item, native)
        and encounters.prove(item, native)
        and features.prove(item, native, nativeContext)
end

local function realizeOverview(item, game, native)
    local result = assert(overview.realize(item, game, native))
    rewards.realize(item, result)
    features.realize(item, result)
    return result
end

function TestRoomNavigationStructure.testNativeFactVocabularyIsClosedAndDoesNotTranslatePlannerAddresses()
    lu.assertEquals(featureBindings.features, {
        stygianWell = { carrier = "roomField", key = "WellShop" },
        purgingPool = { carrier = "roomField", key = "SellTraitShop" },
        keepsakeRack = { carrier = "obstacleUseFunction", key = "UseKeepsakeRack" },
        fountain = { carrier = "obstacleUseFunction", key = "UseHealthFountain" },
        shop = { carrier = "roomField", key = "StoreDataName" },
    })
    lu.assertEquals(rewardBindings.logicalRoomAcquisitions, { InfernalContractBoon = true })
    lu.assertNil(featureBindings.exitKey)
    lu.assertNil(featureBindings.owner)
    lu.assertNil(featureBindings.generationKey)
end

local function occurrence()
    return {
        gameName = "F_Test",
        overview = {
            incomingReward = { rewardType = "Boon" },
            encounterPhases = { { slotKey = "Encounter", encounterKey = "Fight" } },
            requiredObjects = { "SoulPylon" },
            stygianWell = { interacted = true }, purgingPool = { interacted = true },
            keepsakeRack = {}, fountain = {}, shop = { offers = {} },
            resources = { { acquisitionRole = "ore", grantedTraitKey = "FireEssence", contributions = {} } },
            additional = { { owner = "chaos", kind = "chaos", room = { gameName = "Chaos" } } },
        },
        doors = { kind = "batch", resolvedSharedRewardStoreKey = "RunProgress", targets = {
            { exitKey = "one", index = 0, room = { gameName = "F_One" }, reward = { rewardType = "Boon" } },
            { exitKey = "two", index = 1, room = { gameName = "F_Two" } },
        } },
    }
end

local function room()
    return { GenusName = "F_Test", RewardType = "Boon", ChosenRewardType = "Boon",
        Encounter = { Name = "Fight" }, PickaxePointSuccess = true,
        WellShop = {}, SellTraitShop = {}, StoreDataName = "WorldShop" }
end

local function context()
    return {
        activeObstacles = {
            { OnUsedFunctionName = "UseKeepsakeRack" },
            { OnUsedFunctionName = "UseHealthFountain" },
        },
        offeredExitDoors = {
            { Room = {
                Name = "Chaos",
                __runPlannerExecutionAdditionalKind = "chaos",
            } },
        },
        hasObject = function(key) return key == "SoulPylon" end,
    }
end

function TestRoomNavigationStructure.testRoomEntryComponentsProveThePublishedOverview()
    local item = occurrence()
    local native = room()
    lu.assertTrue(proveOverview(item, native, context()))
    lu.assertNil(features.prove(item, native, { hasObject = function() return false end }))
end

function TestRoomNavigationStructure.testResourceRealizationWinsOverCreateRoomRandomFields()
    local item = occurrence()
    local native = room()
    native.PickaxePointSuccess = false
    features.realize(item, native)
    lu.assertTrue(proveOverview(item, native, context()))
    native.PickaxePointSuccess = false
    lu.assertNil(features.prove(item, native, context()))
end

function TestRoomNavigationStructure.testRoomsWithoutPlannedResourceSuccessSuppressAndRejectRandomSuccesses()
    local item = occurrence()
    item.overview.resources = nil
    local native = room()
    native.PickaxePointSuccess = true

    features.realize(item, native)

    lu.assertFalse(native.PickaxePointSuccess)
    lu.assertFalse(native.ExorcismPointSuccess)
    lu.assertFalse(native.ShovelPointSuccess)
    lu.assertFalse(native.FishingPointSuccess)
    lu.assertTrue(proveOverview(item, native, context()))
    native.PickaxePointSuccess = true
    lu.assertNil(features.prove(item, native, context()))
end

function TestRoomNavigationStructure.testRoomRealizationReplacesRandomInputsButKeepsNativeFields()
    local item = occurrence()
    local game = { RoomData = { F_Test = { NativeOnly = "keep" } } }
    local realized = realizeOverview(item, game, { RandomNative = true })
    lu.assertEquals(realized.NativeOnly, "keep")
    lu.assertTrue(realized.RandomNative)
    lu.assertEquals(realized.__runPlannerExecutionRoomId, item.id)
    lu.assertNil(realized.ChosenRewardType)
    lu.assertNil(realized.EncounterPhases)
    lu.assertNil(realized.ObjectIds)
    lu.assertEquals(encounters.choose(item, "Other"), nil)
    lu.assertEquals(encounters.choose(item, "Encounter"), "Fight")
    realized.ChosenRewardType = "Boon"
    realized.Encounter = { Name = "Fight" }
    realized.WellShop = {}
    realized.SellTraitShop = {}
    realized.StoreDataName = "WorldShop"
    lu.assertTrue(proveOverview(item, realized, context()))
end

function TestRoomNavigationStructure.testIncomingRewardRejectsAStaleNativeChoice()
    local item = occurrence()
    local native = room()
    native.ChosenRewardType = "WeaponUpgrade"
    lu.assertNil(rewards.prove(item, native))
end

function TestRoomNavigationStructure.testIntermediateRewardReturnWaitsForRoomEntryProof()
    local item = occurrence()
    local module, callbacks = captureHooks()
    local state = {
        state = "synchronized",
        plan = { occurrencesById = { target = item } },
    }
    local session = {
        current = function() return { occurrence = item } end,
    }
    local producedRewards = timelineHooks.attach(module, session, function() return state end, function() end,
        session)
    navigationHooks.attach(module, session, function() return state end, function() end,
        { reportDestination = function() return true end }, session, producedRewards)

    local nativeRoom = room()
    nativeRoom.__runPlannerExecutionRoomId = "target"
    local intermediate = callbacks.ChooseRoomReward(nil, {}, function()
        return "WeaponUpgrade"
    end, {}, nativeRoom, "RunProgress", {}, {})

    lu.assertEquals(intermediate, "WeaponUpgrade")
    lu.assertNil(state.firstMismatch)

    nativeRoom.ChosenRewardType = "WeaponUpgrade"
    local ok, errorValue = rewards.prove(item, nativeRoom)
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "incomingReward")
end

function TestRoomNavigationStructure.testLogicalContractAcquisitionDoesNotReplaceItsNativeMetaReward()
    local item = occurrence()
    item.gameName = "C_Boss01"
    item.overview.incomingReward = { rewardType = "InfernalContractBoon" }
    local game = { RoomData = { C_Boss01 = { ForcedReward = "GemPointsBigDrop" } } }

    local realized = realizeOverview(item, game)

    lu.assertEquals(realized.ForcedReward, "GemPointsBigDrop")
    lu.assertNil(realized.RewardType)
    realized.ChosenRewardType = "GemPointsBigDrop"
    realized.Encounter = { Name = "Fight" }
    realized.WellShop = {}
    realized.SellTraitShop = {}
    realized.StoreDataName = "WorldShop"
    lu.assertTrue(proveOverview(item, realized, context()))
end

function TestRoomNavigationStructure.testEffectNeutralRequiredRewardPreservesAndAcceptsNativeBossDrop()
    local item = occurrence()
    item.gameName = "F_Boss01"
    item.overview.incomingReward = nil
    item.overview.effectNeutralRequiredReward = true
    local game = { RoomData = { F_Boss01 = { ForcedReward = "MixerFBossDrop" } } }

    local realized = realizeOverview(item, game)

    lu.assertEquals(realized.ForcedReward, "MixerFBossDrop")
    lu.assertNil(realized.RewardType)
    realized.ChosenRewardType = "MixerFBossDrop"
    realized.Encounter = { Name = "Fight" }
    realized.WellShop = {}
    realized.SellTraitShop = {}
    realized.StoreDataName = "WorldShop"
    lu.assertTrue(proveOverview(item, realized, context()))
    realized.ChosenRewardType = nil
    lu.assertNil(rewards.prove(item, realized))
end

function TestRoomNavigationStructure.testDoorsProveOrderTargetsRewardsAndTerminal()
    local item = occurrence()
    local native = { sharedRewardStoreKey = "RunProgress",
        { Room = { GenusName = "F_One", ChosenRewardType = "Boon" } },
        { Room = { GenusName = "F_Two" } } }
    lu.assertTrue(doors.prove(item, native))
    native[2].Room.GenusName = "F_Wrong"
    lu.assertNil(doors.prove(item, native))
    item.doors = { kind = "terminal" }
    lu.assertTrue(doors.prove(item, {}))
    lu.assertNil(doors.prove(item, native))
end

function TestRoomNavigationStructure.testNavigationProvesTheCompleteAdditionalDoorSet()
    local item = occurrence()
    local expected = item.overview.additional[1]
    local specialRoom = {
        Name = expected.room.gameName,
        __runPlannerExecutionRoomId = expected.room.id,
        __runPlannerExecutionAdditionalOwner = expected.owner,
        __runPlannerExecutionAdditionalKind = expected.kind,
    }
    local specialDoor = { Room = specialRoom }
    doors.bindAdditional(specialDoor, expected)

    lu.assertTrue(doors.proveAdditional(item, { specialDoor }))

    local ok, errorValue = doors.proveAdditional(item, {})
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "additionalCount")

    ok, errorValue = doors.proveAdditional(item, { specialDoor, specialDoor })
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "additionalCount")

    specialRoom.__runPlannerExecutionRoomId = "wrong-occurrence"
    ok, errorValue = doors.proveAdditional(item, { specialDoor })
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "additionalBinding")

    item.overview.additional = nil
    ok, errorValue = doors.proveAdditional(item, { specialDoor })
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "additionalCount")
end

function TestRoomNavigationStructure.testDoorRealizationOverwritesRandomRowsAndChoosesPublishedTarget()
    local item = occurrence()
    local game = { RoomData = { F_One = { GenusName = "wrong" }, F_Two = { GenusName = "wrong" } } }
    local realized = doors.realize(item, { { NativeOnly = true }, { Other = true } }, game)
    lu.assertTrue(realized[1].NativeOnly)
    lu.assertEquals(realized[1].Room.GenusName, "F_One")
    lu.assertEquals(realized[2].Room.GenusName, "F_Two")
    lu.assertTrue(doors.prove(item, realized))
    lu.assertEquals(doors.chooseNext(item, game, 2).GenusName, "F_Two")
end

function TestRoomNavigationStructure.testDoorRealizationPreservesAndRequiresNativeBossReward()
    local item = occurrence()
    item.doors = { kind = "fixed", target = {
        id = "boss", biomeKey = "F", gameName = "F_Boss01",
    } }
    local occurrencesById = {
        boss = { id = "boss", overview = { effectNeutralRequiredReward = true } },
    }
    local game = { RoomData = { F_Boss01 = { ForcedReward = "MixerFBossDrop" } } }

    local realized = doors.realize(item, { {} }, game, occurrencesById)

    lu.assertEquals(realized[1].Room.ForcedReward, "MixerFBossDrop")
    realized[1].Room.ChosenRewardType = "MixerFBossDrop"
    lu.assertTrue(doors.prove(item, realized, occurrencesById))
    realized[1].Room.ChosenRewardType = nil
    lu.assertNil(doors.prove(item, realized, occurrencesById))
end
