-- luacheck: globals TestKeepsakeEncounterEffects
-- Fig Leaf and Gorgon effect-primary witnesses. Encounter identity and
-- lifecycle integration remain covered by tests/room/test_encounters.lua.
local lu = require("luaunit")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestKeepsakeEncounterEffects = {}

local function capture()
    local callbacks = {}
    return {
        hooks = {
            wrap = function(name, _, callback) callbacks[name] = callback end,
        },
    }, callbacks
end

function TestKeepsakeEncounterEffects.testFigLeafForcesTheExactDecisionAcrossBothSpawnHandlers()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter", figLeafSkip = false },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local room = {
        current = function() return active end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }
    local nativeCalls
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    for _, expected in ipairs({ false, true }) do
        active.occurrence.overview.encounterPhases[1].figLeafSkip = expected
        for _, handler in ipairs({ "HandleEncounterPreSpawns", "HandleEnemySpawns" }) do
            nativeCalls = 0
            local result, secondResult = callbacks[handler](nil, {}, function(encounter)
                lu.assertEquals(encounter, nativeEncounter)
                local first = callbacks.RandomChance(nil, {}, function()
                    nativeCalls = nativeCalls + 1
                    return true
                end, 0.9, {})
                local second = callbacks.RandomChance(nil, {}, function()
                    nativeCalls = nativeCalls + 1
                    return "native"
                end, 0.1, {})
                return first, second
            end, nativeEncounter)
            lu.assertEquals(result, expected)
            lu.assertEquals(secondResult, "native")
            lu.assertEquals(nativeCalls, 1)
        end
    end
end

function TestKeepsakeEncounterEffects.testFigLeafAbsenceLeavesNativeRandomnessUntouched()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter", blocksFigLeaf = true },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local nativeCalls = 0
    local room = {
        current = function() return active end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)
    local result = callbacks.HandleEnemySpawns(nil, {}, function()
        return callbacks.RandomChance(nil, {}, function() nativeCalls = nativeCalls + 1; return true end,
            0.9, {})
    end, nativeEncounter)
    lu.assertTrue(result)
    lu.assertEquals(nativeCalls, 1)
end

function TestKeepsakeEncounterEffects.testGorgonAthenaHandsItsPublishedOfferToOrdinaryUseLoot()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter" },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local athena = { Name = "NPC_Athena_Field_01" }
    local handle = {}
    local bound = setmetatable({}, { __mode = "k" })
    local payload = {
        transaction = {
            kind = "encounterInteraction",
            resolution = { kind = "traitOffer", offer = {
                kind = "traits", giver = "Athena", selected = "option1",
                options = {
                    { key = "AthenaAttack", rarity = "Rare", effectiveLevel = 2 },
                    { key = "AthenaSpecial", rarity = "Common", effectiveLevel = 1 },
                },
            } },
        },
    }
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Encounter = nativeEncounter }, Hero = { Traits = {} } }
    local room = {
        current = function() return active end,
        encounterPhase = function(_, encounter)
            return encounter == nativeEncounter and active.occurrence.overview.encounterPhases[1] or nil
        end,
        encounterHandle = function(_, source)
            bound[source] = handle
            return handle
        end,
        resolve = function() return nil end,
        peek = function(_, value) return value == handle and payload or nil end,
        begin = function(_, value) return value == handle and payload or nil end,
        bound = function(_, _, native) return bound[native] end,
        bind = function(_, _, value, native) bound[native] = value; return value end,
        sourceRole = function() return nil end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)
    local result = callbacks.AthenaUse(nil, {}, function() return "native-use" end,
        athena, { value = 1 }, { id = 2 })
    _G.CurrentRun = priorRun

    lu.assertEquals(result, "native-use")
    lu.assertEquals(bound[athena], handle)
end
