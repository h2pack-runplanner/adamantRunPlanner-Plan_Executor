-- luacheck: globals TestKeepsakeReplay
local lu = require("luaunit")
local loadoutHooks = require("mods/loadout/hooks")
local hexTree = require("mods.hex.tree")
local loadout = require("mods/loadout/session")

TestKeepsakeReplay = {}

local function capture(result)
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    local callbacks = {}
    local state = { initialized = true, state = "synchronized", room = {} }
    local observed, completed
    local coordinator = {
        current = function() return {} end,
        resolve = function(_, _, contact)
            observed = contact
            if contact.kind == "keepsakeReplay" then return "replay-handle" end
        end,
        begin = function() return { transaction = { equipResults = result } } end,
        complete = function(target) if target.state ~= "mismatch" then completed = true end end,
    }
    local sessionAdapter = {
        start = function() end,
        current = coordinator.current,
        resolve = coordinator.resolve,
        begin = coordinator.begin,
        complete = coordinator.complete,
        mismatch = function(target, checkpoint, expected, actual)
            target.state = "mismatch"
            target.firstMismatch = { checkpoint = checkpoint, expected = expected, observed = actual }
        end,
    }
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    hexTree.attach(module)
    loadoutHooks.attach(module, { session = sessionAdapter, loadout = loadout, inbox = {} },
        function() return state end, function() end, sessionAdapter)
    _G.import = priorImport
    return callbacks, state, function() return observed end, function() return completed end
end

local function exactArgs()
    return { ForceRarity = "Common", FromLoot = true, OverwriteSlot = true }
end

function TestKeepsakeReplay.testSelectedHammerReplayReusesTheNativeSelectorAndCompletes()
    local callbacks, state, observed, completed = capture({
        experimentalHammer = { kind = "selected", traitKey = "HammerTrait" },
    })
    local selected
    local acquire
    local result = callbacks.EquipKeepsake(nil, {}, function()
        acquire = function()
            return callbacks.GiveDurationHammer(nil, {}, function()
                selected = callbacks.GetRandomArrayValue(nil, {}, function(values) return values[1] end,
                    { { Name = "Wrong" }, { Name = "HammerTrait" } })
                return selected
            end)
        end
        return "native-equip"
    end, {}, "TempHammerKeepsake", exactArgs())
    lu.assertEquals(result, "native-equip")
    lu.assertEquals(observed(), { kind = "keepsakeReplay", keepsakeKey = "TempHammerKeepsake" })
    lu.assertNil(completed())
    lu.assertEquals(acquire().Name, "HammerTrait")
    lu.assertEquals(observed(), { kind = "keepsakeReplay", keepsakeKey = "TempHammerKeepsake" })
    lu.assertTrue(completed())
    lu.assertEquals(state.state, "synchronized")
end

function TestKeepsakeReplay.testExhaustedHammerAndEmbryoReplayRemainNativeContactBound()
    local callbacks, state, observed, completed = capture({ experimentalHammer = { kind = "exhausted" } })
    local hammerResult = callbacks.EquipKeepsake(nil, {}, function()
        return "native-equip"
    end, {}, "TempHammerKeepsake", exactArgs())
    lu.assertEquals(hammerResult, "native-equip")
    lu.assertEquals(observed().kind, "keepsakeReplay")
    lu.assertNil(completed())
    lu.assertNil(callbacks.GiveDurationHammer(nil, {}, function() return nil end))
    lu.assertEquals(observed().kind, "keepsakeReplay")
    lu.assertTrue(completed())
    lu.assertEquals(state.state, "synchronized")

    callbacks, state, observed, completed = capture({
        transcendentEmbryo = {
            blessingKey = "ChaosBlessing", blessingValues = { damageBonus = 0.35 },
        },
    })
    local selected
    local acquire
    local embryoEquip = callbacks.EquipKeepsake(nil, {}, function()
        acquire = function()
            return callbacks.ChaosBlessingBonus(nil, {}, function()
                return callbacks.AddRandomChaosBlessing(nil, {}, function()
                    selected = callbacks.GetRandomArrayValue(nil, {}, function(values) return values[1] end,
                        { { Name = "Wrong" }, { Name = "ChaosBlessing" } })
                    return selected
                end, "Common")
            end)
        end
        return "native-equip"
    end, {}, "RandomBlessingKeepsake", exactArgs())
    lu.assertEquals(embryoEquip, "native-equip")
    lu.assertEquals(observed().kind, "keepsakeReplay")
    lu.assertNil(completed())
    acquire()
    lu.assertEquals(selected.Name, "ChaosBlessing")
    lu.assertEquals(observed().kind, "keepsakeReplay")
    lu.assertTrue(completed())
    lu.assertEquals(state.state, "synchronized")
end

function TestKeepsakeReplay.testRackCarrierCannotClaimReplayAndSelectorMismatchKeepsNativeReturn()
    local callbacks, state, observed, completed = capture({
        experimentalHammer = { kind = "selected", traitKey = "HammerTrait" },
    })
    local nativeReturn = callbacks.EquipKeepsake(nil, {}, function() return "native-rack" end,
        {}, "TempHammerKeepsake", { FromLoot = true, OverwriteSlot = true })
    lu.assertEquals(nativeReturn, "native-rack")
    lu.assertEquals(observed().kind, "keepsake")
    lu.assertNil(completed())

    local nativeReplayReturn = callbacks.EquipKeepsake(nil, {}, function() return "native-replay" end,
        {}, "TempHammerKeepsake", exactArgs())
    lu.assertEquals(nativeReplayReturn, "native-replay")
    lu.assertEquals(observed().kind, "keepsakeReplay")
    local selectorReturn = callbacks.GiveDurationHammer(nil, {}, function()
        return callbacks.GetRandomArrayValue(nil, {}, function(values) return values[1] end,
            { { Name = "Wrong" } })
    end)
    lu.assertEquals(selectorReturn.Name, "Wrong")
    lu.assertEquals(state.state, "mismatch")
    lu.assertEquals(state.firstMismatch.checkpoint, "availability:traitEligibility")
    lu.assertNil(completed())
end

function TestKeepsakeReplay.testStartingCarrierCannotClaimReplay()
    local callbacks, state, observed, completed = capture({
        experimentalHammer = { kind = "exhausted" },
    })
    state.state = "starting"
    state.plan = {
        startingKeepsake = {
            keepsakeKey = "TempHammerKeepsake",
            equipResults = { experimentalHammer = { kind = "exhausted" } },
        },
    }
    local nativeReturn = callbacks.StartNewRun(nil, {}, function()
        local result = callbacks.EquipKeepsake(nil, {}, function() return "native-start" end,
            {}, "TempHammerKeepsake", exactArgs())
        state.state = "synchronized"
        return result
    end, {}, {})
    lu.assertEquals(nativeReturn, "native-start")
    lu.assertNil(observed())
    lu.assertNil(completed())
end
