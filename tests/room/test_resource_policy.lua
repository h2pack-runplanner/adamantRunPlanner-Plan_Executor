-- luacheck: globals TestResourcePolicy
local lu = require("luaunit")
local structure = require("mods.room.features.structure")
local resourceHooks = require("mods.room.features.resources")
local support = require("tests.harness.hook_composition")
local capture = support.capture

TestResourcePolicy = {}

local dispositions = { Pickaxe = "native", Exorcism = "native", Shovel = "native", Fishing = "native" }

local function withCurrentOccurrence(occurrenceId, callback)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { __runPlannerExecutionRoomId = occurrenceId } }
    local ok, result = pcall(callback)
    _G.CurrentRun = priorRun
    if not ok then error(result, 0) end
    return result
end

function TestResourcePolicy.testPointDispositionPreservesNativeAndAppliesOnlyPublishedOverrides()
    local native = {
        PickaxePointSuccess = true, ExorcismPointSuccess = false,
        ShovelPointSuccess = true, FishingPointSuccess = false,
    }
    structure.realize(native, { pointDispositions = dispositions })
    lu.assertEquals(native.PickaxePointSuccess, true)
    lu.assertEquals(native.ExorcismPointSuccess, false)
    lu.assertEquals(native.ShovelPointSuccess, true)
    lu.assertEquals(native.FishingPointSuccess, false)

    structure.realize(native, { pointDispositions = {
        Pickaxe = "suppress", Exorcism = "force", Shovel = "native", Fishing = "native",
    } })
    lu.assertFalse(native.PickaxePointSuccess)
    lu.assertTrue(native.ExorcismPointSuccess)
    lu.assertTrue(native.ShovelPointSuccess)
    lu.assertFalse(native.FishingPointSuccess)
end

local function resourceFixture(disposition)
    local module, _, callbacks = capture()
    local policy = { pointDispositions = {
        Pickaxe = disposition, Exorcism = disposition, Shovel = disposition, Fishing = disposition,
    } }
    local state = {
        state = "synchronized",
        plan = { resources = { occurrences = { {
            occurrenceId = "room", pointDispositions = policy.pointDispositions,
        } } } },
    }
    resourceHooks.attach(module, function() return state end, function() end)
    return callbacks, function(callback) return withCurrentOccurrence("room", callback) end
end

function TestResourcePolicy.testEveryNativeToolUsesTheStampedCurrentRoomPolicy()
    local callbacks, inRoom = resourceFixture("force")
    inRoom(function()
        for _, tool in ipairs({ "ToolPickaxe2", "ToolExorcismBook2", "ToolShovel2", "ToolFishingRod2" }) do
            local calls = 0
            local result = callbacks.GrantElementFromTool(nil, {}, function(toolName)
                lu.assertEquals(toolName, tool)
                calls = calls + 1
                return callbacks.RandomChance(nil, {}, function() return false end, 0.25, {})
            end, tool, {})
            lu.assertTrue(result)
            lu.assertEquals(calls, 1)
        end
    end)
end

function TestResourcePolicy.testGrantElementScopeIsOneShotNestedAndExceptionSafe()
    local callbacks, inRoom = resourceFixture("force")
    inRoom(function()
        local nativeRolls = 0
        local function nativeRoll()
            nativeRolls = nativeRolls + 1
            return "native"
        end
        local result = callbacks.GrantElementFromTool(nil, {}, function()
            local first = callbacks.RandomChance(nil, {}, nativeRoll, 0.25, {})
            local unrelated = callbacks.RandomChance(nil, {}, nativeRoll, 0.25, {})
            local nested = callbacks.GrantElementFromTool(nil, {}, function()
                return callbacks.RandomChance(nil, {}, nativeRoll, 0.25, {})
            end, "ToolPickaxe2", {})
            local afterNested = callbacks.RandomChance(nil, {}, nativeRoll, 0.25, {})
            return { first, unrelated, nested, afterNested }
        end, "ToolPickaxe2", {})
        lu.assertEquals(result, { true, "native", true, "native" })
        lu.assertEquals(nativeRolls, 2)

        local ok = pcall(function()
            callbacks.GrantElementFromTool(nil, {}, function()
                callbacks.RandomChance(nil, {}, nativeRoll, 0.25, {})
                error("native failure")
            end, "ToolPickaxe2", {})
        end)
        lu.assertFalse(ok)
        lu.assertEquals(callbacks.RandomChance(nil, {}, nativeRoll, 0.25, {}), "native")
    end)
end

function TestResourcePolicy.testNativeDispositionForcesFailureAndManualAndAutoHarvestShareTheHook()
    local callbacks, inRoom = resourceFixture("native")
    inRoom(function()
        local nativeCalls = 0
        local function grant()
            nativeCalls = nativeCalls + 1
            return callbacks.RandomChance(nil, {}, function() return true end, 0.25, {})
        end
        local manual = callbacks.GrantElementFromTool(nil, {}, grant, "ToolPickaxe2", {})
        local automatic = (function()
            -- AutoHarvestOnExit reaches the same native GrantElementFromTool contact while
            -- CurrentRun.CurrentRoom still identifies the departing occurrence.
            return callbacks.GrantElementFromTool(nil, {}, grant, "ToolPickaxe2", {})
        end)()
        lu.assertFalse(manual)
        lu.assertFalse(automatic)
        lu.assertEquals(nativeCalls, 2)
    end)
end
