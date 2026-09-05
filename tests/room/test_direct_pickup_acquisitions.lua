-- luacheck: globals TestDirectPickupAcquisitions
local lu = require("luaunit")
local binding = require("mods.room.timeline.acquisitions.binding")
local pickups = require("mods.room.timeline.acquisitions.pickups.hooks")
local seaStar = require("mods.room.timeline.acquisitions.sea_star")

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

local function harness(row, item, isBound, installSeaStar)
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = {} } }
    local handle = {}
    local begins, completions, reports, releases = 0, {}, 0, 0
    local bound = isBound ~= false and item or nil
    local room = {
        current = function() return active end,
        bound = function(_, _, native) return native == bound and handle or nil end,
        peek = function(_, value) return value == handle and row or nil end,
        claimReady = function(_, _, contact, native, compatible)
            if bound ~= nil or compatible(row.transaction, contact) == nil then return nil end
            bound = native
            return handle, row
        end,
        begin = function(_, value)
            if value ~= handle then return nil end
            begins = begins + 1
            return row
        end,
        releaseCompletedBinding = function()
            releases = releases + 1
            return true
        end,
    }
    local session = {
        complete = function(_, value)
            completions[#completions + 1] = { handle = value }
        end,
    }
    pickups.attach(module, session, function() return state end, function() reports = reports + 1 end, room)
    if installSeaStar then seaStar.attach(module) end
    return callbacks, handle, function() return begins end, completions, function() return reports end,
        function() return releases end
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

function TestDirectPickupAcquisitions.testUnboundSameNameConsumableClaimsAtAcceptedPresentation()
    local item = { Name = "MaxHealthDrop" }
    local callbacks, handle, begins, completions = harness(acquisitionRow(item.Name), item, false)
    lu.assertEquals(acceptedUse(callbacks, item), "native-result")
    lu.assertEquals(begins(), 1)
    lu.assertEquals(#completions, 1)
    lu.assertEquals(completions[1].handle, handle)
end

function TestDirectPickupAcquisitions.testUnboundGeneratedPickupForcesBothSeaStarOutcomesAndReleasesProcObject()
    for _, expected in ipairs({ "proc", "noProc" }) do
        local item = { Name = "RoomMoneyDrop" }
        local row = acquisitionRow(item.Name, "resource")
        row.detail.seaStarResult = { kind = expected }
        local callbacks, _, _, completions, _, releases = harness(row, item, false, true)
        local chance = {}
        acceptedUse(callbacks, item, function()
            chance.value = callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0 end,
                "DoubleRewardChance", {})
            chance.result = callbacks.RandomChance(nil, {}, function() return nil end, 0.25, {})
        end)
        lu.assertEquals(chance.value, 1)
        lu.assertEquals(chance.result, expected == "proc")
        lu.assertEquals(#completions, 1)
        lu.assertEquals(releases(), expected == "proc" and 1 or 0)
    end
end

function TestDirectPickupAcquisitions.testUnselectedGeneratedPickupPassesThroughWithoutAnObligation()
    local item = { Name = "RoomMoneyDrop" }
    local module, callbacks = capture()
    local claims, begins, completions, reports = 0, 0, 0, 0
    local room = {
        current = function() return { occurrence = { overview = {} } } end,
        bound = function() return nil end,
        claimReady = function(_, _, contact)
            claims = claims + 1
            lu.assertEquals(contact, { kind = "directPickup", gameName = "RoomMoneyDrop" })
            return nil
        end,
        begin = function() begins = begins + 1 end,
    }
    local session = { complete = function() completions = completions + 1 end }
    pickups.attach(module, session, function() return { state = "synchronized" } end,
        function() reports = reports + 1 end, room)
    local nativeApplied = false
    lu.assertEquals(acceptedUse(callbacks, item, function() nativeApplied = true end), "native-result")
    lu.assertTrue(nativeApplied)
    lu.assertEquals(claims, 1)
    lu.assertEquals(begins, 0)
    lu.assertEquals(completions, 0)
    lu.assertEquals(reports, 0)
end

function TestDirectPickupAcquisitions.testSameIdentityGeneratedPickupsClaimReadyActionsInUseOrder()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local state, active = { state = "synchronized" }, { occurrence = { overview = {} } }
    local rows, handles = {}, { {}, {} }
    for index, owner in ipairs({ "buried-treasure-tiny-1", "buried-treasure-tiny-2" }) do
        rows[index] = acquisitionRow("RoomMoneyTinyDrop")
        rows[index].transaction.owner = owner
    end
    local nativeHandles, claimed, begins, completions = {}, {}, 0, {}
    local room = {
        current = function() return active end,
        bound = function(_, _, native) return nativeHandles[native] end,
        peek = function(_, handle)
            for index, value in ipairs(handles) do if value == handle then return rows[index] end end
        end,
        claimReady = function(_, _, contact, native, compatible)
            for index, row in ipairs(rows) do
                if not claimed[index] and compatible(row.transaction, contact) ~= nil then
                    claimed[index] = true
                    nativeHandles[native] = handles[index]
                    return handles[index], row
                end
            end
        end,
        begin = function(_, handle)
            begins = begins + 1
            for index, value in ipairs(handles) do if value == handle then return rows[index] end end
        end,
    }
    local session = {
        complete = function(_, handle) completions[#completions + 1] = handle end,
    }
    pickups.attach(module, session, function() return state end, function() end, room)

    local firstPhysical, secondPhysical = { Name = "RoomMoneyTinyDrop" }, { Name = "RoomMoneyTinyDrop" }
    lu.assertEquals(acceptedUse(callbacks, secondPhysical), "native-result")
    lu.assertEquals(acceptedUse(callbacks, firstPhysical), "native-result")
    lu.assertEquals(nativeHandles[secondPhysical], handles[1])
    lu.assertEquals(nativeHandles[firstPhysical], handles[2])
    lu.assertEquals(completions, { handles[1], handles[2] })
    lu.assertEquals(begins, 2)
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
