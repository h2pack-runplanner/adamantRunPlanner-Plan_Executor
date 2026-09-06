-- luacheck: globals TestAromaticPhial
local lu = require("luaunit")
local fountain = require("mods.room.timeline.interactions.fountain")

TestAromaticPhial = {}

local function attach(transaction)
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local handle = {}
    local active = {}
    local state = { state = "synchronized" }
    local completed, mismatches, reports = 0, {}, 0
    local room = {
        current = function() return active end,
        resolve = function(_, _, contact)
            if contact.kind == "interaction" and contact.interactionKey == "fountain" then
                return handle
            end
        end,
        bind = function(_, _, value) return value end,
        begin = function(_, value)
            if value == handle then return { transaction = transaction } end
        end,
    }
    local session = {
        complete = function(_, value)
            lu.assertEquals(value, handle)
            completed = completed + 1
        end,
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = {
                checkpoint = checkpoint, expected = expected, observed = observed,
            }
        end,
    }
    fountain.attach(module, session, function() return state end, function() reports = reports + 1 end, room)
    return callbacks, function() return completed end, function() return mismatches end,
        function() return reports end
end

function TestAromaticPhial.testThreadedPhialContactForcesOnlyThePublishedTrait()
    local callbacks, completed, mismatches = attach({
        kind = "fountainUse", interactionKey = "fountain", aromaticPhialTarget = "TargetTrait",
    })
    local target = { Name = "TargetTrait", Rarity = "Common" }
    local other = { Name = "OtherTrait", Rarity = "Common" }
    local phial = { Name = "FountainRarityKeepsake", Uses = 1, FountainRarity = {} }
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { target, other, phial } } }
    local delayed
    local result = callbacks.UseHealthFountain(nil, {}, function()
        delayed = function()
            return callbacks.AddRarityToTraits(nil, {}, function(source, args)
                lu.assertEquals(source, phial)
                lu.assertEquals(args.ForceUpgrade, { target })
                return args.ForceUpgrade[1]
            end, phial, { NumTraits = 1 })
        end
        return "used"
    end, {}, {})
    lu.assertEquals(result, "used")
    lu.assertEquals(completed(), 0)

    local nativeCalls = 0
    lu.assertEquals(callbacks.AddRarityToTraits(nil, {}, function(source, args)
        nativeCalls = nativeCalls + 1
        lu.assertEquals(source.Name, "OtherRaritySource")
        lu.assertNil(args.ForceUpgrade)
        return other
    end, { Name = "OtherRaritySource" }, { NumTraits = 1 }), other)
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(completed(), 0)

    lu.assertEquals(delayed(), target)
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
    _G.CurrentRun = priorRun
end

function TestAromaticPhial.testThreadedMissingTargetPublishesMismatchAndLeavesNativeSelectionAlone()
    local callbacks, completed, mismatches, reports = attach({
        kind = "fountainUse", interactionKey = "fountain", aromaticPhialTarget = "MissingTrait",
    })
    local native = { Name = "NativeTrait" }
    local phial = { Name = "FountainRarityKeepsake", Uses = 1, FountainRarity = {} }
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { phial, native } } }
    local delayed
    callbacks.UseHealthFountain(nil, {}, function()
        delayed = function()
            return callbacks.AddRarityToTraits(nil, {}, function(_, args)
            lu.assertNil(args.ForceUpgrade)
            return native
            end, phial, { NumTraits = 1 })
        end
    end, {}, {})
    lu.assertEquals(reports(), 1)
    lu.assertEquals(delayed(), native)
    _G.CurrentRun = priorRun
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches()[1], {
        checkpoint = "aromatic-phial-target", expected = "MissingTrait", observed = "missing trait",
    })
    lu.assertEquals(reports(), 2)
end

function TestAromaticPhial.testFountainWithoutPublishedTargetCompletesAtNativeReturn()
    local callbacks, completed, mismatches = attach({
        kind = "fountainUse", interactionKey = "fountain",
    })
    lu.assertEquals(callbacks.UseHealthFountain(nil, {}, function() return "used" end, {}, {}), "used")
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end
