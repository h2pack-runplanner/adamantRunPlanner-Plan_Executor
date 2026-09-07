-- luacheck: globals TestConcaveStone
-- Concave Stone effect-primary witnesses. Ordinary trait carrier integration
-- remains covered by tests/room/test_ordinary_traits.lua.
local lu = require("luaunit")
local support = require("tests.room.ordinary_trait_support")
local json = require("mods.protocol.json")

TestConcaveStone = {}

local function concaveOffer(result, residual)
    return {
        kind = "traits",
        selected = "option1",
        options = {
            { key = "Primary", concaveStoneResult = result },
            residual or { key = "Residual" },
            { key = "Other" },
        },
    }
end

local function selectConcave(callbacks, loot, candidates, nested)
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function(_, outerButton)
        local stone = callbacks.HasHeroTraitValue(nil, {}, function()
            return { Uses = 1, DoubleBoonChance = 0.75 }
        end, "DoubleBoonChance")
        if callbacks.RandomChance(nil, {}, function() return false end, stone.DoubleBoonChance, {}) then
            local nextButton = callbacks.GetRandomValue(nil, {}, function(values) return values[1] end, candidates)
            callbacks.HandleUpgradeChoiceSelection(nil, {}, nested or function() return true end,
                {}, nextButton, { DoubleBoonChance = true })
        end
        return outerButton
    end, {}, { LootData = loot, Data = { Name = "Primary" } }, {})
end

function TestConcaveStone.testEpicNoProcConsumesTheNativeRollBeforeTheOuterTerminal()
    local callbacks, _, completed, mismatches = support.attached(concaveOffer({ kind = "noProc" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    selectConcave(callbacks, loot, {})
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestConcaveStone.testEpicProcForcesItsExactResidualButton()
    local callbacks, _, completed, mismatches = support.attached(concaveOffer({ kind = "proc", optionKey = "option2" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local residual = { LootData = loot, Data = { Name = "Residual" } }
    selectConcave(callbacks, loot, { { LootData = loot, Data = { Name = "Other" } }, residual })
    lu.assertEquals(mismatches(), {})
    lu.assertEquals(completed(), 1)
end

function TestConcaveStone.testForcedHeroicProcOverridesOnlyTheNativeRoll()
    local callbacks, _, completed, mismatches = support.attached(concaveOffer({ kind = "proc", optionKey = "option2" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    selectConcave(callbacks, loot, { { LootData = loot, Data = { Name = "Residual" } } })
    lu.assertEquals(mismatches(), {})
    lu.assertEquals(completed(), 1)
end

function TestConcaveStone.testResidualAllTogetherStaysWithinTheOuterC1Scope()
    local callbacks, _, completed, mismatches = support.attached(concaveOffer(
        { kind = "proc", optionKey = "option2" },
        { key = "AllElementalBoon", allTogetherResult = {
            earth = "Earth", fire = json.null, air = json.null, water = json.null,
        } }
    ))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local residual = { LootData = loot, Data = { Name = "AllElementalBoon" } }
    selectConcave(callbacks, loot, { residual }, function(_, nestedButton)
        callbacks.GrantBoons(nil, {}, function(args)
            lu.assertEquals(callbacks.GetRandomValue(nil, {}, function(values) return values[1] end,
                args.BoonSets[1]), "Earth")
        end, { BoonSets = { { "OtherEarth", "Earth" }, {}, {}, {} } }, nestedButton.Data)
        lu.assertEquals(completed(), 0)
        return true
    end)
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestConcaveStone.testResidualNaturalSelectionUsesItsOwnPublishedTargetOrder()
    local callbacks, _, completed, mismatches = support.attached(concaveOffer(
        { kind = "proc", optionKey = "option2" },
        { key = "GoodStuffBoon", naturalSelectionTargets = { "Attack", "Special" } }
    ))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local residual = { LootData = loot, Data = { Name = "GoodStuffBoon" } }
    local shuffled, applied
    selectConcave(callbacks, loot, { residual }, function(_, nestedButton)
        callbacks.DistributeLevels(nil, {}, function()
            shuffled = callbacks.FYShuffle(nil, {}, function(values) return values end,
                { "Special", "Attack", "Cast" })
            applied = {}
            for _, key in ipairs({ "Attack", "Special" }) do
                callbacks.IncreaseTraitLevel(nil, {}, function(trait)
                    applied[#applied + 1] = trait.Name
                end, { Name = key })
            end
        end, { Slots = {} }, nestedButton.Data)
        return true
    end)
    lu.assertEquals(shuffled, { "Attack", "Special", "Cast" })
    lu.assertEquals(applied, { "Attack", "Special" })
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestConcaveStone.testResidualBridalGlowUsesItsOwnPublishedTarget()
    local target = { Name = "ApolloSprintBoon", Rarity = "Epic" }
    local callbacks, _, completed, mismatches = support.attached(concaveOffer(
        { kind = "proc", optionKey = "option2" },
        { key = "BoonDecayBoon", targetTraitKey = target.Name }
    ), nil, "HeraUpgrade")
    local loot = { GodLoot = true, Name = "HeraUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { { Name = "ZeusWeaponBoon" }, target } } }
    local residual = { LootData = loot, Data = { Name = "BoonDecayBoon" } }
    local upgraded
    selectConcave(callbacks, loot, { residual }, function(_, nestedButton)
        callbacks.HeraSuperchargeBoon(nil, {}, function()
            callbacks.AddRarityToTraits(nil, {}, function(_, args)
                upgraded = args.ForceUpgrade[1]
                return upgraded
            end, nestedButton.Data, {})
        end, {}, nestedButton.Data, {})
        return true
    end)
    _G.CurrentRun = priorRun
    lu.assertTrue(rawequal(upgraded, target))
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestConcaveStone.testMissingOrUnavailableResidualLeavesOuterIncompleteAndCleansScope()
    local callbacks, _, completed, mismatches = support.attached(concaveOffer({ kind = "proc", optionKey = "option2" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    selectConcave(callbacks, loot, { { LootData = loot, Data = { Name = "Other" } } })
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches()[1].checkpoint, "concave-stone-residual")
    lu.assertFalse(callbacks.RandomChance(nil, {}, function() return false end, 1, {}))
end

function TestConcaveStone.testMissingNativeRollLeavesOuterIncompleteAndCleansScope()
    local callbacks, _, completed, mismatches = support.attached(concaveOffer({ kind = "noProc" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
        {}, { LootData = loot, Data = { Name = "Primary" } }, {})
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches()[1].checkpoint, "concave-stone-roll")
    lu.assertFalse(callbacks.RandomChance(nil, {}, function() return false end, 1, {}))
end

function TestConcaveStone.testNativeErrorClearsItsScopeWithoutCompletingC1()
    local callbacks, _, completed = support.attached(concaveOffer({ kind = "noProc" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local ok = pcall(function()
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function()
            local stone = callbacks.HasHeroTraitValue(nil, {}, function()
                return { Uses = 1, DoubleBoonChance = 0.75 }
            end, "DoubleBoonChance")
            callbacks.RandomChance(nil, {}, function() return false end, stone.DoubleBoonChance, {})
            error("native selection failure")
        end, {}, { LootData = loot, Data = { Name = "Primary" } }, {})
    end)
    lu.assertFalse(ok)
    lu.assertEquals(completed(), 0)
    lu.assertFalse(callbacks.RandomChance(nil, {}, function() return false end, 1, {}))
end
