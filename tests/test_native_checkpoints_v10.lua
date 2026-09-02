-- luacheck: globals TestNativeCheckpointsV10
local lu = require("luaunit")
local overview = require("mods/native_overview")
local doors = require("mods/native_doors")
local nativeFacts = require("mods/native_fact_bindings")

TestNativeCheckpointsV10 = {}

function TestNativeCheckpointsV10.testNativeFactVocabularyIsClosedAndDoesNotTranslatePlannerAddresses()
    lu.assertEquals(nativeFacts.overview.features, {
        stygianWell = { carrier = "roomField", key = "WellShop" },
        purgingPool = { carrier = "roomField", key = "SellTraitShop" },
        keepsakeRack = { carrier = "obstacleUseFunction", key = "UseKeepsakeRack" },
        fountain = { carrier = "obstacleUseFunction", key = "UseHealthFountain" },
        shop = { carrier = "roomField", key = "StoreDataName" },
    })
    lu.assertNil(nativeFacts.exitKey)
    lu.assertNil(nativeFacts.owner)
    lu.assertNil(nativeFacts.generationKey)
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

function TestNativeCheckpointsV10.testOverviewProvesConstructionAndBindsPublishedFacts()
    local item = occurrence()
    local native = room()
    lu.assertTrue(overview.prove(item, native, context()))
    local bound = overview.bind(item, native)
    lu.assertNotNil(bound.resources.ore)
    lu.assertNotNil(bound.additional.chaos)
    lu.assertNil(overview.prove(item, native, { hasObject = function() return false end }))
end

function TestNativeCheckpointsV10.testResourceRealizationWinsOverCreateRoomRandomFields()
    local item = occurrence()
    local native = room()
    native.PickaxePointSuccess = false
    overview.applyResources(item, native)
    lu.assertTrue(overview.prove(item, native, context()))
    native.PickaxePointSuccess = false
    lu.assertNil(overview.prove(item, native, context()))
end

function TestNativeCheckpointsV10.testRoomsWithoutPlannedResourceSuccessSuppressAndRejectRandomSuccesses()
    local item = occurrence()
    item.overview.resources = nil
    local native = room()
    native.PickaxePointSuccess = true

    overview.applyResources(item, native)

    lu.assertFalse(native.PickaxePointSuccess)
    lu.assertFalse(native.ExorcismPointSuccess)
    lu.assertFalse(native.ShovelPointSuccess)
    lu.assertFalse(native.FishingPointSuccess)
    lu.assertTrue(overview.prove(item, native, context()))
    native.PickaxePointSuccess = true
    lu.assertNil(overview.prove(item, native, context()))
end

function TestNativeCheckpointsV10.testOverviewRealizationReplacesRandomInputsButKeepsNativeFields()
    local item = occurrence()
    local game = { RoomData = { F_Test = { NativeOnly = "keep" } } }
    local realized = assert(overview.realize(item, game, { RandomNative = true }))
    lu.assertEquals(realized.NativeOnly, "keep")
    lu.assertTrue(realized.RandomNative)
    lu.assertEquals(realized.__runPlannerExecutionRoomId, item.id)
    lu.assertNil(realized.ChosenRewardType)
    lu.assertNil(realized.EncounterPhases)
    lu.assertNil(realized.ObjectIds)
    lu.assertEquals(overview.chooseEncounter(item, "Other"), nil)
    lu.assertEquals(overview.chooseEncounter(item, "Encounter"), "Fight")
    realized.ChosenRewardType = "Boon"
    realized.Encounter = { Name = "Fight" }
    realized.WellShop = {}
    realized.SellTraitShop = {}
    realized.StoreDataName = "WorldShop"
    lu.assertTrue(overview.prove(item, realized, context()))
end

function TestNativeCheckpointsV10.testOverviewRejectsAStaleNativeChosenReward()
    local item = occurrence()
    local native = room()
    native.ChosenRewardType = "WeaponUpgrade"
    lu.assertNil(overview.prove(item, native))
end

function TestNativeCheckpointsV10.testLogicalContractAcquisitionDoesNotReplaceItsNativeMetaReward()
    local item = occurrence()
    item.gameName = "C_Boss01"
    item.overview.incomingReward = { rewardType = "InfernalContractBoon" }
    local game = { RoomData = { C_Boss01 = { ForcedReward = "GemPointsBigDrop" } } }

    local realized = assert(overview.realize(item, game))

    lu.assertEquals(realized.ForcedReward, "GemPointsBigDrop")
    lu.assertNil(realized.RewardType)
    realized.ChosenRewardType = "GemPointsBigDrop"
    realized.Encounter = { Name = "Fight" }
    realized.WellShop = {}
    realized.SellTraitShop = {}
    realized.StoreDataName = "WorldShop"
    lu.assertTrue(overview.prove(item, realized, context()))
end

function TestNativeCheckpointsV10.testEffectNeutralRequiredRewardPreservesAndAcceptsNativeBossDrop()
    local item = occurrence()
    item.gameName = "F_Boss01"
    item.overview.incomingReward = nil
    item.overview.effectNeutralRequiredReward = true
    local game = { RoomData = { F_Boss01 = { ForcedReward = "MixerFBossDrop" } } }

    local realized = assert(overview.realize(item, game))

    lu.assertEquals(realized.ForcedReward, "MixerFBossDrop")
    lu.assertNil(realized.RewardType)
    realized.ChosenRewardType = "MixerFBossDrop"
    realized.Encounter = { Name = "Fight" }
    realized.WellShop = {}
    realized.SellTraitShop = {}
    realized.StoreDataName = "WorldShop"
    lu.assertTrue(overview.prove(item, realized, context()))
    realized.ChosenRewardType = nil
    lu.assertNil(overview.prove(item, realized, context()))
end

function TestNativeCheckpointsV10.testDoorsProveOrderTargetsRewardsAndTerminal()
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

function TestNativeCheckpointsV10.testDoorRealizationOverwritesRandomRowsAndChoosesPublishedTarget()
    local item = occurrence()
    local game = { RoomData = { F_One = { GenusName = "wrong" }, F_Two = { GenusName = "wrong" } } }
    local realized = doors.realize(item, { { NativeOnly = true }, { Other = true } }, game)
    lu.assertTrue(realized[1].NativeOnly)
    lu.assertEquals(realized[1].Room.GenusName, "F_One")
    lu.assertEquals(realized[2].Room.GenusName, "F_Two")
    lu.assertTrue(doors.prove(item, realized))
    lu.assertEquals(doors.chooseNext(item, game, 2).GenusName, "F_Two")
end

function TestNativeCheckpointsV10.testDoorRealizationPreservesAndRequiresNativeBossReward()
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
