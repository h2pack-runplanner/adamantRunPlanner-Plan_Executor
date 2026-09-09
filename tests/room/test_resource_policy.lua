-- luacheck: globals TestResourcePolicy
local lu = require("luaunit")
local resourceHooks = require("mods.room.features.resources")
local support = require("tests.harness.hook_composition")
local capture = support.capture

TestResourcePolicy = {}

local function withCurrentOccurrence(occurrenceId, callback)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { __runPlannerExecutionRoomId = occurrenceId } }
    local ok, result = pcall(callback)
    _G.CurrentRun = priorRun
    if not ok then error(result, 0) end
    return result
end

local function resourceFixture(disposition)
    local module, _, callbacks = capture()
    local pointDispositions = type(disposition) == "table" and disposition or {
        Pickaxe = disposition, Exorcism = disposition,
        Shovel = disposition, Fishing = disposition,
    }
    local policy = { pointDispositions = pointDispositions }
    local state = {
        state = "synchronized",
        plan = { resources = { occurrences = { {
            occurrenceId = "room", pointDispositions = policy.pointDispositions,
        } } } },
    }
    resourceHooks.attach(module, function() return state end, function() end)
    return callbacks, function(callback) return withCurrentOccurrence("room", callback) end
end

function TestResourcePolicy.testSetupHarvestPointsRealizesPublishedPointPolicy()
    local callbacks = resourceFixture({
        Pickaxe = "force", Exorcism = "native", Shovel = "suppress", Fishing = "native",
    })
    local restored = {
        __runPlannerExecutionRoomId = "room",
        PickaxePointSuccess = false,
        ExorcismPointSuccess = true,
        ShovelPointSuccess = true,
        FishingPointSuccess = true,
    }
    local priorMapState = _G.MapState
    _G.MapState = { ActiveObstacles = {} }
    local result = callbacks.SetupHarvestPoints(nil, {}, function(currentRoom, args)
        lu.assertEquals(currentRoom, restored)
        lu.assertEquals(args, { restored = true })
        lu.assertTrue(currentRoom.PickaxePointSuccess)
        lu.assertTrue(currentRoom.ExorcismPointSuccess)
        lu.assertFalse(currentRoom.ShovelPointSuccess)
        lu.assertTrue(currentRoom.FishingPointSuccess)
        currentRoom.PickaxePointChoices = { 101 }
        currentRoom.ExorcismPointChoices = { 102 }
        _G.MapState.ActiveObstacles[101] = {}
        _G.MapState.ActiveObstacles[102] = {}
        return "spawned"
    end, restored, { restored = true })
    lu.assertEquals(result, "spawned")
    lu.assertEquals(_G.MapState.ActiveObstacles[101].__runPlannerResourceOccurrenceId, "room")
    lu.assertEquals(_G.MapState.ActiveObstacles[102].__runPlannerResourceOccurrenceId, "room")

    local suppressedCallbacks = resourceFixture("suppress")
    restored.PickaxePointSuccess = true
    suppressedCallbacks.SetupHarvestPoints(nil, {}, function(currentRoom)
        lu.assertFalse(currentRoom.PickaxePointSuccess)
    end, restored, {})
    _G.MapState = priorMapState
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

function TestResourcePolicy.testNativeDispositionForcesElementFailureForActiveRoom()
    local callbacks, inRoom = resourceFixture("native")
    inRoom(function()
        local nativeCalls = 0
        local function grant()
            nativeCalls = nativeCalls + 1
            return callbacks.RandomChance(nil, {}, function() return true end, 0.25, {})
        end
        lu.assertFalse(callbacks.GrantElementFromTool(nil, {}, grant, "ToolPickaxe2", {}))
        lu.assertEquals(nativeCalls, 1)
    end)
end

function TestResourcePolicy.testSuppressedPointCannotLeakAnElementThroughAutoHarvest()
    local callbacks, inRoom = resourceFixture("suppress")
    inRoom(function()
        local result = callbacks.GrantElementFromTool(nil, {}, function()
            return callbacks.RandomChance(nil, {}, function() return true end, 0.25, {})
        end, "ToolShovel2", { SkipDelay = true })
        lu.assertFalse(result)
    end)
end

function TestResourcePolicy.testDepartingSideRoomPolicySurvivesNativeParentRestoration()
    local module, _, scopedCallbacks = capture()
    resourceHooks.attach(module, function()
        return {
            state = "synchronized",
            plan = { resources = { occurrences = {
                { occurrenceId = "side", pointDispositions = {
                    Pickaxe = "force", Exorcism = "force", Shovel = "force", Fishing = "force",
                } },
                { occurrenceId = "parent", pointDispositions = {
                    Pickaxe = "suppress", Exorcism = "suppress",
                    Shovel = "suppress", Fishing = "suppress",
                } },
            } } },
        }
    end, function() end)
    local priorMapState = _G.MapState
    _G.MapState = { ActiveObstacles = {} }
    local sideRoom = { __runPlannerExecutionRoomId = "side" }
    local contacts = {
        { "Pickaxe", "PickaxePointChoices", "UsePickaxePointOnExit", "ToolPickaxe2", 101 },
        { "Exorcism", "ExorcismPointChoices", "UseExorcismPointOnExit", "ToolExorcismBook2", 102 },
        { "Shovel", "ShovelPointChoices", "UseShovelPointOnExit", "ToolShovel2", 103 },
        { "Fishing", "FishingPointChoices", "UseFishingPointOnExit", "ToolFishingRod2", 104 },
    }
    scopedCallbacks.SetupHarvestPoints(nil, {}, function(nativeRoom)
        for _, contact in ipairs(contacts) do
            nativeRoom[contact[2]] = { contact[5] }
            _G.MapState.ActiveObstacles[contact[5]] = {}
        end
    end, sideRoom, {})

    withCurrentOccurrence("parent", function()
        for _, contact in ipairs(contacts) do
            local point = _G.MapState.ActiveObstacles[contact[5]]
            lu.assertEquals(point.__runPlannerResourceOccurrenceId, "side")
            local callback = scopedCallbacks[contact[3]]
            local result = callback(nil, {}, function(source)
                lu.assertEquals(source, point)
                return scopedCallbacks.GrantElementFromTool(nil, {}, function()
                    return scopedCallbacks.RandomChance(nil, {}, function() return false end, 0.5, {})
                end, contact[4], {})
            end, point, {}, {})
            lu.assertTrue(result, contact[1])
        end

        local nativeRolls = 0
        local unstamped = scopedCallbacks.UsePickaxePointOnExit(nil, {}, function()
            return scopedCallbacks.GrantElementFromTool(nil, {}, function()
                return scopedCallbacks.RandomChance(nil, {}, function()
                    nativeRolls = nativeRolls + 1
                    return "native"
                end, 0.5, {})
            end, "ToolPickaxe2", {})
        end, {}, {}, {})
        lu.assertEquals(unstamped, "native")
        lu.assertEquals(nativeRolls, 1)
    end)
    _G.MapState = priorMapState
end
