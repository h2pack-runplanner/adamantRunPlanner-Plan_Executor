-- luacheck: globals TestSeaStar
local lu = require("luaunit")
local seaStar = require("mods.room.timeline.acquisitions.sea_star")

TestSeaStar = {}

local function installed()
    local callbacks, mismatches = {}, {}
    seaStar.attach({ hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } })
    return callbacks, mismatches
end

local function payload(kind)
    return { detail = { seaStarResult = { kind = kind } } }
end

function TestSeaStar.testForcesBothPublishedChanceBranchesOnlyAfterTheNativeTraitRead()
    local callbacks = installed()
    for _, expected in ipairs({ "proc", "noProc" }) do
        local scope = seaStar.scope({}, payload(expected))
        local mismatches = {}
        local result = seaStar.call(scope, function()
            lu.assertEquals(callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0 end,
                "DoubleRewardChance", {}), 1)
            return callbacks.RandomChance(nil, {}, function() return "native" end, 0.25, {})
        end, function(_, checkpoint, wanted, observed)
            mismatches[#mismatches + 1] = { checkpoint, wanted, observed }
        end)
        lu.assertEquals(result, expected == "proc")
        lu.assertTrue(scope.chanceConsumed)
        lu.assertEquals(mismatches, {})
    end
end

function TestSeaStar.testMissingChanceContactIsARequiredSourceMismatch()
    local callbacks = installed()
    local mismatches = {}
    seaStar.call(seaStar.scope({}, payload("proc")), function()
        return callbacks.RandomChance(nil, {}, function() return "native" end, 0.25, {})
    end, function(_, checkpoint, wanted, observed)
        mismatches[#mismatches + 1] = { checkpoint, wanted, observed }
    end)
    lu.assertEquals(mismatches, { { "sea-star-chance", "proc", "missing" } })
end

function TestSeaStar.testProducedDuplicateWithoutAResultCannotArmAnotherChance()
    local callbacks = installed()
    local scope = seaStar.scope({}, { detail = {} })
    lu.assertEquals(seaStar.call(scope, function()
        return callbacks.RandomChance(nil, {}, function() return "native" end, 0.25, {})
    end, function() error("must not mismatch") end), "native")
end
