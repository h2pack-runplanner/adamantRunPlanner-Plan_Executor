-- Mourning Fields feature realization. Native setup owns object creation; the
-- adapter only selects the published finite placements and optional outcomes.
-- luacheck: globals TestFieldsFeatures
local lu = require("luaunit")
local fields = require("mods.room.features.fields")
local support = require("tests.harness.hook_composition")

TestFieldsFeatures = {}

local function fixture(layout, occurrenceId)
    local module, _, callbacks = support.capture()
    local occurrence = { id = occurrenceId or "fields", overview = { fields = layout } }
    local state = { state = "synchronized" }
    local mismatches = {}
    local reports = 0
    local room = { current = function() return occurrence end }
    local session = {
        mismatch = function(_, kind, expected, observed)
            mismatches[#mismatches + 1] = { kind = kind, expected = expected, observed = observed }
        end,
    }
    fields.attach(module, session, function() return state end, function() reports = reports + 1 end, room)
    return callbacks, state, mismatches, function() return reports end
end

function TestFieldsFeatures.testPlannedDoorPayloadSurvivesNativeCageRebuildBranch()
    local expected = {
        { RewardType = "MaxHealthDrop", ForceLootName = "MaxHealthDrop" },
        { RewardType = "WeaponUpgrade", ForceLootName = "WeaponUpgrade" },
    }
    local nativeRoom = { MaxCageRewards = 2, CageRewards = expected }
    fields.realize(nativeRoom, {
        entryPair = { startPointId = 1, endPointId = 2 },
        cagePoints = {
            { slotKey = "cage1", pointId = 11 },
            { slotKey = "cage2", pointId = 12 },
        },
        optionalRewards = {},
    })

    -- This is the native DoUnlockRoomExits branch that previously replaced
    -- the planner payload after navigation had installed it on the door.
    if nativeRoom.MaxCageRewards ~= nil then
        nativeRoom.CageRewards = {
            { RewardType = "native-random-cage-1" },
            { RewardType = "native-random-cage-2" },
        }
    end
    lu.assertEquals(nativeRoom.CageRewards, expected)
end

function TestFieldsFeatures.testTwoCagesAndSourceSpecificOptionalRewardUsePublishedPlacements()
    local callbacks, _, mismatches, reports = fixture({
        entryPair = { startPointId = 101, endPointId = 102 },
        cagePoints = {
            { slotKey = "cage1", pointId = 11 },
            { slotKey = "cage2", pointId = 12 },
        },
        optionalRewards = {
            {
                slotKey = "optional1", pointId = 21,
                reward = { rewardType = "Boon", source = "DemeterUpgrade" },
            },
        },
    })
    local nativeRoom = {
        OptionalRewardChances = { 0.95, 0.75, 0.50 },
        BonusRewardStoreName = "FieldsOptionalRewards",
    }
    local cages = { 11, 12, 13 }
    local optional = { 21, 22 }
    local selectedReward
    local result = callbacks.SpawnRewardCages(nil, {}, function(room)
        lu.assertEquals(callbacks.RemoveRandomValue(nil, {}, function(values)
            return table.remove(values, 1)
        end, cages), 11)
        lu.assertEquals(callbacks.RemoveRandomValue(nil, {}, function(values)
            return table.remove(values, 1)
        end, cages), 12)
        lu.assertTrue(callbacks.RandomChance(nil, {}, function() return false end, 0.95, {}))
        lu.assertFalse(callbacks.RandomChance(nil, {}, function() return true end, 0.75, {}))
        lu.assertFalse(callbacks.RandomChance(nil, {}, function() return true end, 0.50, {}))
        lu.assertEquals(callbacks.RemoveRandomValue(nil, {}, function(values)
            return table.remove(values, 1)
        end, optional), 21)
        selectedReward = callbacks.ChooseRoomReward(nil, {}, function(run, rewardRoom, store)
            lu.assertEquals(store, "FieldsOptionalRewards")
            local candidate = { Name = "Boon" }
            lu.assertTrue(callbacks.IsRoomRewardEligible(nil, {}, function() return false end,
                run, rewardRoom, candidate, {}, {}))
            return candidate.Name
        end, {}, {}, "FieldsOptionalRewards", {}, {})
        lu.assertEquals(selectedReward, "Boon")
        callbacks.SpawnRoomReward(nil, {}, function(_, args)
            lu.assertEquals(args.RewardOverride, "Boon")
            lu.assertEquals(args.LootName, "DemeterUpgrade")
            return { Name = "Boon" }
        end, room, { RewardOverride = selectedReward, SpawnRewardOnId = 21, NotRequiredPickup = true })
        return true
    end, nativeRoom, {})

    lu.assertTrue(result)
    lu.assertEquals(cages, { 13 })
    lu.assertEquals(optional, { 22 })
    lu.assertEquals(selectedReward, "Boon")
    lu.assertEquals(mismatches, {})
    lu.assertEquals(reports(), 1)
end

function TestFieldsFeatures.testThreeCagesAreBoundedToTheThreePublishedPoints()
    local callbacks, _, mismatches = fixture({
        entryPair = { startPointId = 201, endPointId = 202 },
        cagePoints = {
            { slotKey = "cage1", pointId = 31 },
            { slotKey = "cage2", pointId = 32 },
            { slotKey = "cage3", pointId = 33 },
        },
        optionalRewards = {},
    })
    local nativeRoom = { OptionalRewardChances = {}, BonusRewardStoreName = "FieldsOptionalRewards" }
    local points = { 31, 32, 33, 34 }
    callbacks.SpawnRewardCages(nil, {}, function()
        for _, expected in ipairs({ 31, 32, 33 }) do
            lu.assertEquals(callbacks.RemoveRandomValue(nil, {}, function(values)
                return table.remove(values, 1)
            end, points), expected)
        end
        return true
    end, nativeRoom, {})
    lu.assertEquals(points, { 34 })
    lu.assertEquals(mismatches, {})
end

function TestFieldsFeatures.testHCombat13UsesTheSameFieldsAdapter()
    local callbacks, _, mismatches = fixture({
        entryPair = { startPointId = 251, endPointId = 252 },
        cagePoints = {
            { slotKey = "cage1", pointId = 81 },
            { slotKey = "cage2", pointId = 82 },
        },
        optionalRewards = {},
    }, "h-combat13")
    local nativeRoom = {
        __runPlannerExecutionRoomId = "h-combat13",
        OptionalRewardChances = {},
        BonusRewardStoreName = "FieldsOptionalRewards",
    }
    local points = { 81, 82, 83 }
    callbacks.SpawnRewardCages(nil, {}, function()
        for _, expected in ipairs({ 81, 82 }) do
            lu.assertEquals(callbacks.RemoveRandomValue(nil, {}, function(values)
                return table.remove(values, 1)
            end, points), expected)
        end
        return true
    end, nativeRoom, {})
    lu.assertEquals(points, { 83 })
    lu.assertEquals(mismatches, {})
end

function TestFieldsFeatures.testNemesisUsesPublishedPointAndMustInvokeTheNativeSelector()
    local callbacks, state, mismatches, reports = fixture({
        entryPair = { startPointId = 301, endPointId = 302 },
        cagePoints = {
            { slotKey = "cage1", pointId = 41 },
            { slotKey = "cage2", pointId = 42 },
        },
        optionalRewards = {},
        nemesisPointId = 51,
    })
    local nativeRoom = { __runPlannerExecutionRoomId = "fields" }
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = nativeRoom }
    local selected = callbacks.SpawnNemesisForRandomEvents(nil, {}, function(source)
        return callbacks.SelectSpawnPoint(nil, {}, function() return 99 end,
            nativeRoom, {}, source, {}, 0)
    end, {}, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(selected, 51)
    lu.assertEquals(mismatches, {})
    lu.assertEquals(reports(), 1)
    lu.assertEquals(state.state, "synchronized")
end

function TestFieldsFeatures.testMissingNemesisSelectorReportsWithoutBlockingNativeCall()
    local callbacks, _, mismatches = fixture({
        entryPair = { startPointId = 401, endPointId = 402 },
        cagePoints = {
            { slotKey = "cage1", pointId = 61 },
            { slotKey = "cage2", pointId = 62 },
        },
        optionalRewards = {},
        nemesisPointId = 71,
    })
    local returned = callbacks.SpawnNemesisForRandomEvents(nil, {}, function() return "native" end, {}, {})
    lu.assertEquals(returned, "native")
    lu.assertEquals(mismatches[1].kind, "fields-nemesis-point")
end
