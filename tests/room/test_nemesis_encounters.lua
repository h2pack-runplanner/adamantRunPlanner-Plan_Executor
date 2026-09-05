-- luacheck: globals TestNemesisEncounters
local lu = require("luaunit")
local nemesis = require("mods.room.timeline.encounters.nemesis")

TestNemesisEncounters = {}

local function harness(itemGameName)
    local callbacks = {}
    local module = {
        hooks = {
            wrap = function(name, _, callback) callbacks[name] = callback end,
        },
    }
    local state = {}
    local handle = {}
    local payload = {
        transaction = {
            kind = "encounterInteraction",
            resolution = {
                kind = "nemesisRandomEvent",
                outcome = { kind = "freeItem", itemGameName = itemGameName },
            },
        },
    }
    local mismatches, completions = {}, {}
    local session = {
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = {
                checkpoint = checkpoint,
                expected = expected,
                observed = observed,
            }
        end,
        complete = function(_, currentHandle)
            completions[#completions + 1] = currentHandle
        end,
    }
    local room = {
        encounterHandle = function() return handle end,
        begin = function(_, currentHandle)
            if currentHandle == handle then return payload end
        end,
    }
    nemesis.attach(module, session, function() return state end, function() end, room)
    return callbacks, state, handle, mismatches, completions
end

function TestNemesisEncounters.testFreeItemConstrainsNativePoolAndCompletesAfterDrop()
    local callbacks, _, handle, mismatches, completions = harness("ArmorBoost")
    local wanted = { Name = "ArmorBoost", marker = "wanted" }
    local args = {
        Consumables = {
            { Name = "HealDrop", marker = "other" },
            wanted,
            RandomSelection = true,
        },
    }
    local observed
    local result = callbacks.NPCRewardDropPreProcessArgs(nil, {}, function(nativeArgs)
        observed = nativeArgs.Consumables
        return "preprocessed"
    end, args, {}, {})

    lu.assertEquals(result, "preprocessed")
    lu.assertEquals(#observed, 1)
    lu.assertEquals(observed[1], wanted)
    lu.assertTrue(observed.RandomSelection)
    lu.assertEquals(mismatches, {})
    lu.assertEquals(completions, {})

    local dropped = callbacks.NPCRewardDrop(nil, {}, function() return "dropped" end, {}, {})
    lu.assertEquals(dropped, "dropped")
    lu.assertEquals(completions, { handle })
end

function TestNemesisEncounters.testUnavailableFreeItemReportsMismatchAndPreservesNativePool()
    local callbacks, _, _, mismatches, completions = harness("LastStandDrop")
    local available = { Name = "HealDrop" }
    local blocked = { Name = "LastStandDrop", GameStateRequirements = { "MissingLastStand" } }
    local consumables = { available, blocked, RandomSelection = true }
    local args = { Consumables = consumables }
    local called, observed = 0
    local priorEligibility = _G.IsGameStateEligible
    _G.IsGameStateEligible = function(row, requirements)
        lu.assertEquals(row, blocked)
        lu.assertEquals(requirements, blocked.GameStateRequirements)
        return false
    end
    local ok, result = pcall(callbacks.NPCRewardDropPreProcessArgs, nil, {}, function(nativeArgs)
            called = called + 1
            observed = nativeArgs.Consumables
            return "native-result"
        end, args, {}, {})
    _G.IsGameStateEligible = priorEligibility
    if not ok then error(result, 0) end

    lu.assertEquals(result, "native-result")
    lu.assertEquals(called, 1)
    lu.assertEquals(observed, consumables)
    lu.assertTrue(observed.RandomSelection)
    lu.assertEquals(mismatches, {
        { checkpoint = "nemesis-free-item", expected = "LastStandDrop", observed = nil },
    })
    lu.assertEquals(completions, {})

    callbacks.NPCRewardDrop(nil, {}, function() return true end, {}, {})
    lu.assertEquals(completions, {})
end
