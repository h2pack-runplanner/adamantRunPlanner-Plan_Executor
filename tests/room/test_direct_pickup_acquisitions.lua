-- luacheck: globals TestDirectPickupAcquisitions
local lu = require("luaunit")
local binding = require("mods.room.timeline.acquisitions.binding")
local pickups = require("mods.room.timeline.acquisitions.pickups.hooks")

TestDirectPickupAcquisitions = {}

local function capture()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    return module, callbacks
end

local function acquisitionRow(gameName, kind)
    local detail = {
        role = "self", lifecyclePoint = "roomRewardPickup", kind = kind or "consumable",
        gameName = gameName, disposition = "normal",
    }
    return { transaction = { owner = "pickup", kind = "acquisition", roles = { detail } }, detail = detail }
end

local function harness(row, item, isBound)
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = {} } }
    local handle = {}
    local begins, completions, reports = 0, {}, 0
    local room = {
        current = function() return active end,
        bound = function(_, _, native) return isBound ~= false and native == item and handle or nil end,
        peek = function(_, value) return value == handle and row or nil end,
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
    pickups.attach(module, session, function() return state end, function() reports = reports + 1 end, room)
    return callbacks, handle, function() return begins end, completions, function() return reports end
end

local function acceptedUse(callbacks, item, effect)
    return callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, nativeItem, {})
        if effect then effect() end
        return "native-result"
    end, item, {}, {})
end

function TestDirectPickupAcquisitions.testAcceptedPickupBeginsAfterGuardsAndCompletesAfterNativeReturn()
    local item = { Name = "MaxHealthDrop" }
    local row = acquisitionRow(item.Name)
    local callbacks, handle, begins, completions, reports = harness(row, item)
    local nativeSettled = false

    local result = callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        lu.assertEquals(begins(), 0)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, nativeItem, {})
        lu.assertEquals(begins(), 1)
        lu.assertEquals(#completions, 0)
        nativeSettled = true
        return "native-result"
    end, item, {}, {})

    lu.assertEquals(result, "native-result")
    lu.assertTrue(nativeSettled)
    lu.assertEquals(#completions, 1)
    lu.assertEquals(completions[1].handle, handle)
    lu.assertTrue(completions[1].verified)
    lu.assertEquals(completions[1].observed, "MaxHealthDrop")
    lu.assertEquals(reports(), 1)
end

function TestDirectPickupAcquisitions.testRejectedInteractionDoesNotBegin()
    local item = { Name = "MaxHealthDrop" }
    local callbacks, _, begins, completions, reports = harness(acquisitionRow(item.Name), item)
    lu.assertFalse(callbacks.UseConsumableItem(nil, {}, function() return false end, item, {}, {}))
    lu.assertEquals(begins(), 0)
    lu.assertEquals(#completions, 0)
    lu.assertEquals(reports(), 0)
end

function TestDirectPickupAcquisitions.testDeterministicPluralEffectSettlesBeforeCompletion()
    local item = { Name = "FireBoost", UseFunctionNames = { "AddTraitToHero" } }
    local callbacks, _, _, completions = harness(acquisitionRow(item.Name), item)
    local elementApplied = false
    acceptedUse(callbacks, item, function() elementApplied = true end)
    lu.assertTrue(elementApplied)
    lu.assertEquals(#completions, 1)
    lu.assertTrue(completions[1].verified)
end

function TestDirectPickupAcquisitions.testNativeErrorAfterAcceptanceDoesNotComplete()
    local item = { Name = "MaxHealthDrop" }
    local callbacks, _, begins, completions = harness(acquisitionRow(item.Name), item)
    local ok = pcall(function()
        callbacks.UseConsumableItem(nil, {}, function(nativeItem)
            callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, nativeItem, {})
            error("native failure")
        end, item, {}, {})
    end)
    lu.assertFalse(ok)
    lu.assertEquals(begins(), 1)
    lu.assertEquals(#completions, 0)
end

function TestDirectPickupAcquisitions.testUnboundSameNameConsumablePassesThrough()
    local item = { Name = "MaxHealthDrop" }
    local callbacks, _, begins, completions = harness(acquisitionRow(item.Name), item, false)
    lu.assertEquals(acceptedUse(callbacks, item), "native-result")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(#completions, 0)
end

function TestDirectPickupAcquisitions.testTalentDropRemainsOwnedByInteractiveHexAdapter()
    local item = { Name = "TalentDrop", UseFunctionName = "OpenTalentScreen" }
    local callbacks, _, begins, completions = harness(acquisitionRow(item.Name), item)
    lu.assertEquals(acceptedUse(callbacks, item), "native-result")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(#completions, 0)
end

function TestDirectPickupAcquisitions.testPurchaseTransactionRemainsWithCommerceAdapter()
    local item = { Name = "MaxHealthDrop" }
    local row = acquisitionRow(item.Name)
    row.transaction.kind = "shopPurchase"
    local callbacks, _, begins, completions = harness(row, item)
    lu.assertEquals(acceptedUse(callbacks, item), "native-result")
    lu.assertEquals(begins(), 0)
    lu.assertEquals(#completions, 0)
end

function TestDirectPickupAcquisitions.testRoomRewardBindsExactDirectConsumableObject()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local current = {
        occurrence = {
            overview = { incomingReward = { producerLifecycleKey = "RoomReward", rewardType = "MaxHealth" } },
        },
    }
    local producer, handle, native = {}, {}, { Name = "MaxHealthDrop" }
    local boundObject
    local room = {
        current = function() return current end,
        resolve = function(_, _, contact)
            if contact.kind == "producer" and contact.rewardType == "MaxHealth" then return producer end
            if contact.kind == "materialized" and contact.source == producer
                and contact.gameName == "MaxHealthDrop" then
                return handle
            end
        end,
        bind = function(_, _, value, object)
            if value == handle then boundObject = object end
            return value
        end,
    }
    binding.attach(module, {}, function() return state end, function() end, room)
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateConsumableItem(nil, {}, function() return native end, {})
    end, {}, {})
    lu.assertEquals(boundObject, native)
end
