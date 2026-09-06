-- luacheck: globals TestPathAcquisitions
local lu = require("luaunit")
local seaStar = require("mods.room.timeline.acquisitions.sea_star").create()
local path = require("mods.room.timeline.acquisitions.path.hooks")

TestPathAcquisitions = {}

local function capture(payload, bound, installSeaStar, pathAdapter, seaStarAdapter)
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local item = { Name = payload.detail.gameName, UseFunctionName = "OpenTalentScreen" }
    local state, handle = { state = "synchronized" }, {}
    local nativeHandle = bound == false and nil or item
    local began, completed, mismatches, reports = 0, {}, {}, 0
    local room = {
        current = function() return { id = "room" } end,
        bound = function(_, _, native) return native == nativeHandle and handle or nil end,
        peek = function(_, value) return value == handle and payload or nil end,
        claimReady = function(_, _, contact, native, compatible)
            if compatible(payload.transaction, contact) == nil then return nil end
            nativeHandle = native
            return handle, payload
        end,
        begin = function(_, value)
            if value ~= handle then return nil end
            began = began + 1
            return payload
        end,
        releaseCompletedBinding = function() return true end,
    }
    local session = {
        complete = function(_, value) completed[#completed + 1] = value end,
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = { checkpoint, expected, observed }
        end,
    }
    pathAdapter = pathAdapter or path
    seaStarAdapter = seaStarAdapter or seaStar
    pathAdapter.attach(module, session, function() return state end,
        function() reports = reports + 1 end, room, seaStarAdapter)
    if installSeaStar then seaStarAdapter.attach(module) end
    return callbacks, item, function() return began end, completed, mismatches, function() return reports end
end

local function payload(name)
    local role = {
        role = "self", disposition = "normal", lifecyclePoint = "roomRewardPickup",
        kind = "consumable", gameName = name,
    }
    return { transaction = { kind = "acquisition", roles = { role } }, detail = role }
end

local function use(callbacks, item, native)
    return callbacks.UseConsumableItem(nil, {}, function(source)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, source, {})
        return callbacks.OpenTalentScreen(nil, {}, native, {}, source, {})
    end, item, {}, {})
end

function TestPathAcquisitions.testOneThreeAndFivePointPickupsCompleteOnlyAfterTheirNativeScreenReturns()
    for _, name in ipairs({ "MinorTalentDrop", "TalentDrop", "TalentBigDrop" }) do
        local callbacks, item, began, completed, mismatches = capture(payload(name))
        local nativeSettled = false
        local result = use(callbacks, item, function(_, source)
            lu.assertEquals(began(), 1)
            lu.assertEquals(#completed, 0)
            lu.assertEquals(source, item)
            nativeSettled = true
            return "native-screen-return"
        end)
        lu.assertEquals(result, "native-screen-return")
        lu.assertTrue(nativeSettled)
        lu.assertEquals(began(), 1)
        lu.assertEquals(#completed, 1)
        lu.assertEquals(mismatches, {})
    end
end

function TestPathAcquisitions.testUnboundPathPickupClaimsOnlyAfterNativeAcceptance()
    local callbacks, item, began, completed = capture(payload("TalentDrop"), false)
    local result = use(callbacks, item, function() return "native-screen-return" end)
    lu.assertEquals(result, "native-screen-return")
    lu.assertEquals(began(), 1)
    lu.assertEquals(#completed, 1)
end

function TestPathAcquisitions.testFreshImportedPathCarrierUsesProvidedSeaStarThroughAcceptedClaim()
    local row = payload("TalentDrop")
    row.detail.seaStarResult = { kind = "proc" }
    local freshSeaStar = assert(loadfile("src/mods/room/timeline/acquisitions/sea_star.lua"))().create()
    local freshPath = assert(loadfile("src/mods/room/timeline/acquisitions/path/hooks.lua"))()
    local callbacks, item, _, completed = capture(row, false, true, freshPath, freshSeaStar)
    local chance = {}
    local result = callbacks.UseConsumableItem(nil, {}, function(source)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, source, {})
        chance.value = callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0 end,
            "DoubleRewardChance", {})
        chance.result = callbacks.RandomChance(nil, {}, function() return false end, 0.25, {})
        return callbacks.OpenTalentScreen(nil, {}, function() return "native-screen-return" end, {}, source, {})
    end, item, {}, {})
    lu.assertEquals(result, "native-screen-return")
    lu.assertEquals(chance.value, 1)
    lu.assertTrue(chance.result)
    lu.assertEquals(#completed, 1)
end

function TestPathAcquisitions.testAspectSpellDropUsesThePathScreenWithoutConstructingASpellOffer()
    local callbacks, item, began, completed, mismatches = capture(payload("SpellDrop"))
    local spellOfferBuilt = false
    local result = callbacks.OpenSpellScreen(nil, {}, function(source, args)
        spellOfferBuilt = false
        return callbacks.OpenTalentScreen(nil, {}, function(_, talentSource)
            lu.assertEquals(talentSource, source)
            return "native-screen-return"
        end, args, source, {})
    end, item, {}, nil)
    lu.assertEquals(result, "native-screen-return")
    lu.assertFalse(spellOfferBuilt)
    lu.assertEquals(began(), 1)
    lu.assertEquals(#completed, 1)
    lu.assertEquals(mismatches, {})
end

function TestPathAcquisitions.testAcceptedPathUseWithoutATalentScreenReportsTheBoundedContact()
    local callbacks, item, began, completed, mismatches = capture(payload("TalentDrop"))
    lu.assertEquals(callbacks.UseConsumableItem(nil, {}, function(source)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, source, {})
        return "native-return"
    end, item, {}, {}), "native-return")
    lu.assertEquals(began(), 0)
    lu.assertEquals(#completed, 0)
    lu.assertEquals(mismatches, { { "path-talent-screen", "OpenTalentScreen", "missing" } })
end
