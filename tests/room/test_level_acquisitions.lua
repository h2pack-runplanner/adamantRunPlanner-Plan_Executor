-- luacheck: globals TestLevelAcquisitions
local lu = require("luaunit")
local levels = require("mods.room.timeline.acquisitions.levels.hooks")
local binding = require("mods.room.timeline.acquisitions.binding")

TestLevelAcquisitions = {}

local function capture()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    return module, callbacks
end

local function harness(row, native, isBound)
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local begins, completions = 0, {}
    local handle = {}
    local active = { occurrence = { overview = {} } }
    local bound = isBound == false and {} or { [native] = handle }
    local room = {
        current = function() return active end,
        bound = function(_, _, value) return bound[value] end,
        peek = function(_, value) return value == handle and row or nil end,
        claimReady = function(_, _, contact, value, compatible)
            if bound[value] ~= nil or compatible(row.transaction, contact) == nil then return nil end
            bound[value] = handle
            return handle, row
        end,
        begin = function(_, value)
            if value ~= handle then return nil end
            begins = begins + 1
            return row
        end,
    }
    local session = {
        complete = function(_, value, verified, expected, observed)
            completions[#completions + 1] = {
                handle = value, verified = verified, expected = expected, observed = observed,
            }
        end,
    }
    levels.attach(module, session, function() return state end, function() end, room)
    return callbacks, room, state, handle, function() return begins end, completions
end

local function levelRow(name, count, target)
    local transaction = { owner = "level", kind = "acquisition", roles = {} }
    local detail = {
        role = "self", lifecyclePoint = "roomRewardPickup", kind = "loot", gameName = name,
        levelResolution = { offeredTargets = {}, selectedTarget = target, levelCount = count },
    }
    transaction.roles[1] = detail
    return { transaction = transaction, detail = detail }
end

function TestLevelAcquisitions.testVisibleCountsOneTwoThreeAndNativeFatedBonusIsAppliedOnce()
    local priorFate, priorValue = _G.IsFateValid, _G.GetTotalHeroTraitValue
    _G.IsFateValid = function() return true end
    _G.GetTotalHeroTraitValue = function(name) return name == "FatedPomLevelBonus" and 1 or 0 end
    for _, count in ipairs({ 1, 2, 3 }) do
        local row = levelRow("StackUpgrade", count, "Target")
        row.detail.levelResolution.offeredTargets = { "Target", "Other" }
        local loot = { Name = "StackUpgrade", UpgradeOptions = {} }
        local callbacks = harness(row, loot)
        callbacks.HandleLootPickup(nil, {}, function() end, {}, loot, {})
        callbacks.CreateBoonLootButtons(nil, {}, function(_, value)
            value.StackNum = value.StackNum + callbacks.GetTotalHeroTraitValue(nil, {}, function()
                return 1
            end, "FatedPomLevelBonus", {})
        end, {}, loot, false, {})
        lu.assertEquals(loot.StackNum, count)
        lu.assertEquals(loot.UpgradeOptions[1].ItemName, "Target")
        lu.assertEquals(loot.UpgradeOptions[2].ItemName, "Other")
    end
    _G.IsFateValid, _G.GetTotalHeroTraitValue = priorFate, priorValue
end

function TestLevelAcquisitions.testFailedUseLootDoesNotBeginOrRetryThePublishedOwner()
    local row = levelRow("StackUpgrade", 1, "Target")
    local loot = { Name = "StackUpgrade" }
    local callbacks, _, _, _, begins = harness(row, loot)
    lu.assertEquals(callbacks.UseLoot(nil, {}, function() return false end, loot, {}, {}), false)
    lu.assertEquals(begins(), 0)
    lu.assertEquals(callbacks.UseLoot(nil, {}, function() return false end, loot, {}, {}), false)
    lu.assertEquals(begins(), 0)
end

function TestLevelAcquisitions.testNativeRerollIsNotReSteeredAfterInitialVisibleRows()
    local row = levelRow("StackUpgrade", 1, "Target")
    row.detail.levelResolution.offeredTargets = { "Target", "Other" }
    local loot = { Name = "StackUpgrade", UpgradeOptions = {} }
    local callbacks = harness(row, loot)
    callbacks.HandleLootPickup(nil, {}, function() end, {}, loot, {})
    callbacks.CreateBoonLootButtons(nil, {}, function() end, {}, loot, false, {})
    callbacks.CreateBoonLootButtons(nil, {}, function(_, value)
        value.UpgradeOptions = { { ItemName = "NativeReroll" } }
    end, {}, loot, true, {})
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "NativeReroll")
end

function TestLevelAcquisitions.testVisibleSelectionUsesNativeSortedIdentityAndNormalizesUnsetStack()
    local target = { Name = "Target", StackNum = nil }
    local other = { Name = "Other", StackNum = 4 }
    local row = levelRow("StackUpgradeBig", 2, "Target")
    row.detail.levelResolution.offeredTargets = { "Target", "Other" }
    local loot = { Name = "StackUpgradeBig", UpgradeOptions = {} }
    local callbacks, _, _, _, _, completions = harness(row, loot)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { target, other } } }
    callbacks.HandleLootPickup(nil, {}, function() end, {}, loot, {})
    callbacks.CreateBoonLootButtons(nil, {}, function() end, {}, loot, false, {})
    -- Native row sorting can change physical order; the terminal uses the
    -- button's trait identity rather than the authored row index.
    loot.UpgradeOptions[1], loot.UpgradeOptions[2] = loot.UpgradeOptions[2], loot.UpgradeOptions[1]
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function(_, button)
        local trait = button.Data.Name == target.Name and target or other
        trait.StackNum = (trait.StackNum or 1) + button.LootData.StackNum
    end, {}, { LootData = loot, Data = { Name = target.Name } }, {})
    lu.assertEquals(target.StackNum, 3)
    lu.assertEquals(other.StackNum, 4)
    lu.assertEquals(#completions, 1)
    lu.assertTrue(completions[1].verified)
    _G.CurrentRun = priorRun
end

local function directFixture(selected, count, isBound)
    local item = { Name = "GiftDrop", UseFunctionArgs = { Thread = false, NumTraits = 1, NumStacks = 9 } }
    local row = levelRow("GiftDrop", count or 1, selected)
    local callbacks, room, state, handle, begins, completions = harness(row, item, isBound)
    return item, row, callbacks, room, state, handle, begins, completions
end

local function copy(value)
    local result = {}
    for key, nested in pairs(value or {}) do result[key] = nested end
    return result
end

local function useDirect(callbacks, item, terminal, nativeFatedBonus)
    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, nativeItem, {})
        callbacks.UseStoreRewardRandomStack(nil, {}, function(directArgs)
            if nativeFatedBonus then directArgs.NumStacks = directArgs.NumStacks + nativeFatedBonus end
            callbacks.AddStackToTraits(nil, {}, function(nativeSource, nativeArgs)
                local actual = nativeArgs or copy(nativeSource)
                if actual.Thread then
                    actual.Thread = false
                    callbacks.AddStackToTraits(nil, {}, function(terminalSource, terminalArgs)
                        terminal(nil, terminalArgs or terminalSource)
                    end, actual)
                else
                    terminal(nil, actual)
                end
            end, directArgs)
        end, nativeItem.UseFunctionArgs, nativeItem)
    end, item, {}, {})
end

function TestLevelAcquisitions.testRejectedConsumableDoesNotBeginDirectNectar()
    local item, _, callbacks, _, _, _, begins, completions = directFixture("Target")
    callbacks.UseConsumableItem(nil, {}, function() return false end, item, {}, {})
    lu.assertEquals(begins(), 0)
    lu.assertEquals(#completions, 0)
    callbacks.UseConsumableItem(nil, {}, function() return false end, item, {}, {})
    lu.assertEquals(begins(), 0)
    lu.assertEquals(#completions, 0)
end

function TestLevelAcquisitions.testRoomRewardNectarSteersTargetAndCompletesThreadedTerminalOnce()
    local item, _, callbacks, _, _, _, begins, completions = directFixture("Target")
    item.UseFunctionArgs.Thread = true
    local target = { Name = "Target", StackNum = 2 }
    local other = { Name = "Other", StackNum = 4 }
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { target, other } } }
    useDirect(callbacks, item, function(_, args)
        lu.assertEquals(args.TraitName, "Target")
        lu.assertEquals(args.NumStacks, 1)
        target.StackNum = target.StackNum + args.NumStacks
    end, 1)
    lu.assertTrue(begins() > 0)
    lu.assertEquals(target.StackNum, 3)
    lu.assertEquals(other.StackNum, 4)
    lu.assertEquals(#completions, 1)
    lu.assertTrue(completions[1].verified)
    _G.CurrentRun = priorRun
end

function TestLevelAcquisitions.testNullNectarIsNoOpOnlyWhenNativeHasNoEligibleTarget()
    local item, row, callbacks, _, _, _, _, completions = directFixture(nil)
    local prior = _G.GetAllUpgradeableGodTraits
    _G.GetAllUpgradeableGodTraits = function() return {} end
    useDirect(callbacks, item, function(_, args)
        lu.assertEquals(args.NumTraits, 0)
    end)
    lu.assertEquals(#completions, 1)
    lu.assertTrue(completions[1].verified)
    lu.assertEquals(row.detail.levelResolution.selectedTarget, nil)
    _G.GetAllUpgradeableGodTraits = prior
end

function TestLevelAcquisitions.testNullNectarDoesNotSuppressNativeEligibleTarget()
    local item, _, callbacks, _, _, _, _, completions = directFixture(nil)
    local prior = _G.GetAllUpgradeableGodTraits
    _G.GetAllUpgradeableGodTraits = function() return { Target = true } end
    local nativeCalled = false
    useDirect(callbacks, item, function(_, args)
        nativeCalled = true
        lu.assertEquals(args.NumTraits, 1)
    end)
    lu.assertTrue(nativeCalled)
    lu.assertEquals(#completions, 1)
    lu.assertFalse(completions[1].verified)
    _G.GetAllUpgradeableGodTraits = prior
end

function TestLevelAcquisitions.testIneligibleNectarRestoresNativeArgumentsBeforePassThrough()
    local item, _, callbacks, _, _, _, _, completions = directFixture("Target")
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    useDirect(callbacks, item, function(_, args)
        lu.assertNil(args.__runPlannerTimelineHandle)
        -- Preserve the native value after UseStoreRewardRandomStack has
        -- applied FatedPomLevelBonus; a mismatch stops steering, not gameplay.
        lu.assertEquals(args.NumStacks, 11)
        lu.assertEquals(args.NumTraits, 1)
        lu.assertNil(args.TraitName)
    end, 2)
    lu.assertEquals(#completions, 1)
    lu.assertFalse(completions[1].verified)
    _G.CurrentRun = priorRun
end

function TestLevelAcquisitions.testUnboundDirectNativeCallClaimsAtAcceptedPresentation()
    local item, _, callbacks, _, _, _, begins, completions = directFixture("Target", 1, false)
    local target = { Name = "Target", StackNum = 2 }
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { target } } }
    useDirect(callbacks, item, function(_, args)
        lu.assertEquals(args.TraitName, "Target")
        target.StackNum = target.StackNum + args.NumStacks
    end)
    lu.assertTrue(begins() > 0)
    lu.assertEquals(target.StackNum, 3)
    lu.assertEquals(#completions, 1)
    lu.assertTrue(completions[1].verified)
    _G.CurrentRun = priorRun
end

function TestLevelAcquisitions.testRoomRewardNectarBindsTheExactConsumableObject()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local current = {
        occurrence = {
            overview = { incomingReward = { producerLifecycleKey = "RoomReward", rewardType = "GiftDrop" } },
        },
    }
    local producer, handle, native = {}, {}, { Name = "GiftDrop" }
    local room = {
        current = function() return current end,
        resolve = function(_, _, contact)
            if contact.kind == "producer" and contact.rewardType == "GiftDrop" then return producer end
            if contact.kind == "materialized" and contact.source == producer and contact.gameName == "GiftDrop" then
                return handle
            end
        end,
        bind = function(_, _, value, _object)
            if value == handle then native.boundHandle = value end
            return value
        end,
    }
    binding.attach(module, {}, function() return state end, function() end, room)
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateConsumableItem(nil, {}, function() return native end, {})
    end, {}, {})
    lu.assertEquals(native.boundHandle, handle)
end
