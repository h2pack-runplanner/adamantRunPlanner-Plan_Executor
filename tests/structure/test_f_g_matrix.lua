-- Gate B structural acceptance matrix.  Fixture rows are decoded through the
-- published protocol; small native witnesses cover source-backed families
-- that are not present in an F/G execution fixture.
-- luacheck: globals TestFGStructureMatrix
local lu = require("luaunit")
local json = require("mods/protocol/json")
local protocol = require("mods.protocol.decoder")
local overview = require("mods.room.overview")
local encounters = require("mods.room.timeline.encounters.phases")
local features = require("mods.room.features.structure")
local rewards = require("mods.navigation.rewards")
local doors = require("mods.navigation.doors")

TestFGStructureMatrix = {}

local fixtureRoot = "fixtures/execution-plan/"

local function fixture(name)
    local file = assert(io.open(fixtureRoot .. name .. ".execution.json", "rb"))
    local value = assert(json.decode(file:read("*a")))
    file:close()
    local plan, errorMessage = protocol.decode(value)
    return assert(plan, errorMessage)
end

local function collectNames(plan, names)
    for _, occurrence in ipairs(plan.occurrences) do names[occurrence.gameName] = true end
end

local function structuralOccurrence(gameName, rewardType, encounterKey, additional)
    return {
        id = gameName,
        gameName = gameName,
        overview = {
            incomingReward = rewardType and { rewardType = rewardType } or nil,
            encounterPhases = encounterKey and {
                { slotKey = "Encounter", encounterKey = encounterKey },
            } or {},
            requiredObjects = {},
            additional = additional,
        },
    }
end

local function nativeRoom(gameName, rewardType, encounterKey)
    return {
        Name = gameName,
        ChosenRewardType = rewardType,
        Encounter = encounterKey and { Name = encounterKey } or nil,
    }
end

local function context(additional)
    return {
        offeredExitDoors = additional and { {
            Room = {
                Name = additional.room.gameName,
                __runPlannerExecutionAdditionalKind = additional.kind,
            },
        } } or {},
    }
end

local function proveOverview(item, native, nativeContext)
    return overview.prove(item, native)
        and rewards.prove(item, native)
        and encounters.prove(item, native)
        and features.prove(item, native, nativeContext)
end

local function doorOccurrence(count, prefix)
    local targets = {}
    for index = 1, count do
        targets[index] = {
            room = { id = prefix .. index, gameName = prefix .. index },
        }
    end
    return {
        doors = { kind = "batch", targets = targets },
    }
end

local function nativeDoors(count, prefix)
    local result = {}
    for index = 1, count do
        result[index] = { Room = { Name = prefix .. index } }
    end
    return result
end

function TestFGStructureMatrix.testDecodedFixturesCoverFAndGRoomFamilies()
    local names = {}
    collectNames(fixture("f-opening"), names)
    collectNames(fixture("fg"), names)
    collectNames(fixture("fg-anomaly"), names)
    collectNames(fixture("fg-ixion-chaos"), names)

    for _, gameName in ipairs({
        "F_Opening01", "F_Combat02", "F_MiniBoss01", "F_PreBoss01", "F_Boss01", "F_PostBoss01",
        "G_Combat01", "G_Story01", "G_Shop01", "G_MiniBoss01", "G_PreBoss01", "G_Boss01", "G_PostBoss01",
        "B_Combat01", "Chaos_01",
    }) do
        lu.assertTrue(names[gameName], gameName .. " is absent from decoded F/G fixtures")
    end

    -- Story, Reprieve, and Shop are source-backed F declarations not reached
    -- by the short fixtures; their structural room identity is still checked
    -- through the same Overview adapter below.
    for _, gameName in ipairs({ "F_Story01", "F_Reprieve01", "F_Shop01" }) do
        local item = structuralOccurrence(gameName)
        lu.assertTrue(proveOverview(item, nativeRoom(gameName), context()))
    end
end

function TestFGStructureMatrix.testGDevotionAndContractUseTheirRoomEncounterShapes()
    local devotion = structuralOccurrence("G_Combat01", "Devotion", "GeneratedG")
    lu.assertTrue(proveOverview(devotion, nativeRoom("G_Combat01", "Devotion", "GeneratedG"), context()))

    local contract = structuralOccurrence("C_Boss01", "InfernalContractBoon", "BossZagreus01")
    lu.assertTrue(proveOverview(contract, nativeRoom("C_Boss01", "GemPointsBigDrop", "BossZagreus01"), context()))

    local anomaly = structuralOccurrence("B_Combat01", "MaxManaDrop", "GeneratedAnomalyB")
    lu.assertTrue(proveOverview(anomaly, nativeRoom("B_Combat01", "MaxManaDrop", "GeneratedAnomalyB"), context()))
end

function TestFGStructureMatrix.testNaturalAndIxionChaosHostsProveAsAdditionalStructure()
    local additional = { kind = "chaos", room = { gameName = "Chaos_01" } }
    local natural = structuralOccurrence("G_Combat01", "Boon", "GeneratedG", { additional })
    lu.assertTrue(proveOverview(natural, nativeRoom("G_Combat01", "Boon", "GeneratedG"), context(additional)))

    additional.owner = "natural-chaos"
    additional.room.id = "chaos-occurrence"
    local chaosRoom = {
        Name = "Chaos_01", __runPlannerExecutionRoomId = "chaos-occurrence",
        __runPlannerExecutionAdditionalOwner = "natural-chaos",
        __runPlannerExecutionAdditionalKind = "chaos",
    }
    local chaosDoor = { Room = chaosRoom }
    doors.bindAdditional(chaosDoor, additional)
    lu.assertTrue(doors.proveAdditional(natural, { chaosDoor }))

    local plan = fixture("fg-ixion-chaos")
    local chaos
    for _, occurrence in ipairs(plan.occurrences) do
        if occurrence.gameName == "Chaos_01" then chaos = occurrence; break end
    end
    lu.assertNotNil(chaos)
    lu.assertEquals(chaos.overview.incomingReward.rewardType, "TrialUpgrade")
    lu.assertEquals(chaos.doors.kind, "batch")
    lu.assertEquals(#chaos.doors.targets, 2)
end

function TestFGStructureMatrix.testNormalDoorBatchesCoverZeroThroughThreeExits()
    lu.assertTrue(doors.prove({ doors = { kind = "terminal" } }, {}))
    for count = 1, 3 do
        local occurrence = doorOccurrence(count, "F_Target")
        local result, errorValue = doors.prove(occurrence, nativeDoors(count, "F_Target"))
        lu.assertTrue(result, errorValue and errorValue.kind)
    end
end

function TestFGStructureMatrix.testChaosReturnBatchesCoverOneThroughThreeExits()
    for count = 1, 3 do
        local occurrence = doorOccurrence(count, "G_Return")
        local result, errorValue = doors.prove(occurrence, nativeDoors(count, "G_Return"))
        lu.assertTrue(result, errorValue and errorValue.kind)
    end
end

function TestFGStructureMatrix.testRoomEntryComponentsOwnFeatureAndRewardFailures()
    local item = structuralOccurrence("F_Reprieve01", "Boon", "GeneratedF")
    item.overview.fountain = {}
    local native = nativeRoom("F_Reprieve01", "Boon", "GeneratedF")

    native.Name = "F_Wrong"
    local ok, errorValue = overview.prove(item, native)
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "room")

    native.Name = "F_Reprieve01"
    ok, errorValue = features.prove(item, native, context())
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "feature")

    local featureContext = {
        offeredExitDoors = {},
        activeObstacles = { { OnUsedFunctionName = "UseHealthFountain" } },
    }
    lu.assertTrue(proveOverview(item, native, featureContext))

    native.ChosenRewardType = "WeaponUpgrade"
    ok, errorValue = rewards.prove(item, native)
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "incomingReward")
end

function TestFGStructureMatrix.testWellAndPoolPresenceIgnoresInteractionState()
    for _, key in ipairs({ "stygianWell", "purgingPool" }) do
        for _, interacted in ipairs({ false, true }) do
            local item = structuralOccurrence("F_PostBoss01")
            item.overview[key] = { interacted = interacted }
            local native = nativeRoom("F_PostBoss01")
            native[key == "stygianWell" and "WellShop" or "SellTraitShop"] = {}
            lu.assertTrue(proveOverview(item, native, context()))
        end
    end
end

function TestFGStructureMatrix.testDoorsOwnWrongRoomRewardAndCompleteBatchFailures()
    local item = doorOccurrence(2, "G_Target")
    local native = nativeDoors(2, "G_Target")
    native[2].Room.Name = "G_Wrong"
    local ok, errorValue = doors.prove(item, native)
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "target")

    native = nativeDoors(2, "G_Target")
    native[1].RewardType = "WeaponUpgrade"
    item.doors.targets[1].reward = { rewardType = "Boon" }
    ok, errorValue = doors.prove(item, native)
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "reward")

    ok, errorValue = doors.prove(item, nativeDoors(1, "G_Target"))
    lu.assertNil(ok)
    lu.assertEquals(errorValue.kind, "count")
end
