-- luacheck: globals TestNativeCheckpointsV10
local lu = require("luaunit")
local overview = require("mods/native_overview")
local doors = require("mods/native_doors")

TestNativeCheckpointsV10 = {}

local function occurrence()
    return {
        gameName = "F_Test",
        overview = {
            incomingReward = { rewardType = "Boon" },
            encounterPhases = { { slotKey = "Encounter", encounterKey = "Fight" } },
            requiredObjects = { "Fountain" },
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
    return { GenusName = "F_Test", RewardType = "Boon", EncounterPhases = { "Fight" },
        ObjectIds = { "Fountain" }, PickaxePointSuccess = true,
        WellShop = {}, PurgingPool = {}, KeepsakeRack = {}, Fountain = {}, Shop = {} }
end

function TestNativeCheckpointsV10.testOverviewProvesConstructionAndBindsPublishedFacts()
    local item = occurrence()
    local native = room()
    lu.assertTrue(overview.prove(item, native))
    local bound = overview.bind(item, native)
    lu.assertNotNil(bound.resources.ore)
    lu.assertNotNil(bound.additional.chaos)
    native.ObjectIds = {}
    lu.assertNil(overview.prove(item, native))
end

function TestNativeCheckpointsV10.testResourceRealizationWinsOverCreateRoomRandomFields()
    local item = occurrence()
    local native = room()
    native.PickaxePointSuccess = false
    overview.applyResources(item, native)
    lu.assertTrue(overview.prove(item, native))
    native.PickaxePointSuccess = false
    lu.assertNil(overview.prove(item, native))
end

function TestNativeCheckpointsV10.testOverviewRealizationReplacesRandomInputsButKeepsNativeFields()
    local item = occurrence()
    local game = { RoomData = { F_Test = { NativeOnly = "keep" } } }
    local realized = assert(overview.realize(item, game, { RandomNative = true }))
    lu.assertEquals(realized.NativeOnly, "keep")
    lu.assertTrue(realized.RandomNative)
    lu.assertEquals(realized.__runPlannerExecutionRoomId, item.id)
    lu.assertEquals(overview.chooseEncounter(item, "Other"), nil)
    lu.assertEquals(overview.chooseEncounter(item, "Encounter"), "Fight")
    lu.assertTrue(overview.prove(item, realized))
end

function TestNativeCheckpointsV10.testDoorsProveOrderTargetsRewardsAndTerminal()
    local item = occurrence()
    local native = { sharedRewardStoreKey = "RunProgress",
        { Room = { GenusName = "F_One" }, RewardType = "Boon", ExitKey = "one", Index = 0 },
        { Room = { GenusName = "F_Two" }, ExitKey = "two", Index = 1 } }
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
