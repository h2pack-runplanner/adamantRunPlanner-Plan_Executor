-- D1 encounter ownership and identity witnesses.
-- luacheck: globals TestEncounters
local lu = require("luaunit")
local bindings = require("mods.room.timeline.bindings")
local lifecycle = require("mods.room.timeline.lifecycle")
local phases = require("mods.room.timeline.encounters.phases")
local encounterHooks = require("mods.room.timeline.encounters.hooks")

TestEncounters = {}

local function capture()
    local callbacks = {}
    return {
        hooks = {
            wrap = function(name, _, callback) callbacks[name] = callback end,
        },
    }, callbacks
end

function TestEncounters.testNativeEncounterObjectsBindDuplicateNamesToDifferentPhases()
    local first, second = {}, {}
    local occurrence = {
        id = "room",
        overview = { encounterPhases = {
            { slotKey = "first", encounterKey = "SameEncounter" },
            { slotKey = "second", encounterKey = "SameEncounter" },
        } },
    }
    lu.assertEquals(phases.bind(occurrence, first, "first").slotKey, "first")
    lu.assertEquals(phases.bind(occurrence, second, "second").slotKey, "second")
    lu.assertEquals(phases.forNative(first).phase.slotKey, "first")
    lu.assertEquals(phases.forNative(second).phase.slotKey, "second")
    lu.assertNotEquals(phases.forNative(first).phase, phases.forNative(second).phase)
end

function TestEncounters.testPhaseIsNotAStandaloneTimelineContactNamespace()
    local occurrence = {
        overview = { encounterPhases = {} },
        transactionsByOwner = {
            interaction = {
                owner = "interaction", kind = "encounterInteraction", phaseKey = "phase",
                window = { kind = "encounterEnd", phaseKey = "phase" },
            },
            automatic = {
                owner = "automatic", kind = "automatic", effect = "steadyGrowth", phaseKey = "phase",
                window = { kind = "encounterEnd", phaseKey = "phase" },
            },
        },
    }
    local index = assert(bindings.index(occurrence))
    lu.assertNil(index.phase)
    lu.assertNotNil(bindings.resolve(index, { kind = "encounterInteraction", phaseKey = "phase" }))
    lu.assertNotNil(bindings.resolve(index, {
        kind = "automatic", effect = "steadyGrowth", phaseKey = "phase",
    }))
    lu.assertNil(bindings.resolve(index, { kind = "phase", phaseKey = "phase" }))
end

function TestEncounters.testEncounterLifecycleUsesExactNativeIdentity()
    local module, callbacks = capture()
    local occurrence = {
        id = "room",
        overview = { encounterPhases = {
            { slotKey = "first", encounterKey = "SameEncounter" },
            { slotKey = "second", encounterKey = "SameEncounter" },
        } },
    }
    local active = { occurrence = occurrence }
    local state = { state = "synchronized" }
    local nativeRoom = {}
    local selected = {}
    local opened = {}
    local events = {}
    local capabilities = lifecycle.new()
    local started = {}
    local room = {
        current = function() return active end,
        encounterAt = function(_, index) return occurrence.overview.encounterPhases[index] end,
        bindEncounter = function(_, native, slotKey)
            phases.bind(occurrence, native, slotKey)
            selected[#selected + 1] = native
            return occurrence.overview.encounterPhases[slotKey == "first" and 1 or 2]
        end,
        encounterPhase = function(_, native)
            local binding = phases.forNative(native)
            return binding and binding.phase
        end,
        encounterIsFinal = function(_, native)
            local binding = phases.forNative(native)
            return binding ~= nil and phases.isFinal(occurrence, binding.phase)
        end,
        startEncounter = function(_, native)
            started[#started + 1] = native
            lifecycle.startEncounter(capabilities)
            events[#events + 1] = "start"
            return true
        end,
        window = function(_, window)
            opened[#opened + 1] = window
            events[#events + 1] = "window:" .. window
            return lifecycle.open(capabilities, window)
        end,
    }
    local session = {}
    local priorGame = _G.game
    _G.game = { EncounterData = { SameEncounter = { Name = "SameEncounter" } } }
    encounterHooks.attach(module, session, function() return state end, function() end, room)

    local run = {}
    local first, second = {}, {}
    local index = 0
    local function choose()
        index = index + 1
        return callbacks.ChooseEncounter(nil, {}, function()
            return index == 1 and first or second
        end, run, nativeRoom, {})
    end
    callbacks.SetupRoomMultipleEncountersData(nil, {}, function()
        first = { Name = "SameEncounter" }
        second = { Name = "SameEncounter" }
        choose()
        choose()
        return true
    end, nativeRoom, {})
    callbacks.StartEncounter(nil, {}, function() return true end, run, nativeRoom, first)
    callbacks.EndEncounterEffects(nil, {}, function()
        events[#events + 1] = "native-end:first"
        return true
    end, run, nativeRoom, first)
    lu.assertTrue(lifecycle.accepts(capabilities, { kind = "encounterEnd", phaseKey = "first" }))
    callbacks.StartEncounter(nil, {}, function() return true end, run, nativeRoom, second)
    lu.assertFalse(lifecycle.accepts(capabilities, { kind = "encounterEnd", phaseKey = "first" }))
    callbacks.EndEncounterEffects(nil, {}, function()
        events[#events + 1] = "native-end:second"
        return true
    end, run, nativeRoom, second)
    _G.game = priorGame

    lu.assertEquals(selected, { first, second })
    lu.assertEquals(started, { first, second })
    lu.assertEquals(opened, { "encounterEnd:first", "encounterEnd:second", "afterCombat" })
    lu.assertEquals(events, {
        "start", "window:encounterEnd:first", "native-end:first", "start",
        "window:encounterEnd:second", "native-end:second", "window:afterCombat",
    })
end

function TestEncounters.testUnboundEncounterDoesNotOpenPlannedAfterCombat()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local opened = {}
    local room = {
        encounterPhase = function() return nil end,
        encounterIsFinal = function() return false end,
        window = function(_, window) opened[#opened + 1] = window; return true end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)

    local result = callbacks.EndEncounterEffects(nil, {}, function() return "native-result" end,
        {}, {}, {})

    lu.assertEquals(result, "native-result")
    lu.assertEquals(opened, {})
end

function TestEncounters.testFigLeafForcesTheExactDecisionAcrossBothSpawnHandlers()
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

function TestEncounters.testFigLeafAbsenceLeavesNativeRandomnessUntouched()
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

function TestEncounters.testAthenaUseBindsOnlyThePublishedExactPhaseInteraction()
    local module, callbacks = capture()
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = { encounterPhases = {
        { slotKey = "phase", encounterKey = "Encounter" },
    } } } }
    local nativeEncounter = { Name = "Encounter" }
    local athena = { Name = "NPC_Athena_Field_01" }
    local handle = {}
    local bound
    local resolvedContact
    local payload = {
        transaction = {
            kind = "encounterInteraction",
            resolution = { kind = "traitOffer", offer = { kind = "traits", giver = "Athena" } },
        },
    }
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Encounter = nativeEncounter } }
    local room = {
        current = function() return active end,
        encounterPhase = function(_, encounter)
            return encounter == nativeEncounter and active.occurrence.overview.encounterPhases[1] or nil
        end,
        encounterHandle = function(_, source)
            resolvedContact = { kind = "encounterInteraction", phaseKey = "phase" }
            bound = { handle = handle, native = source }
            return handle
        end,
        peek = function(_, value) return value == handle and payload or nil end,
    }
    encounterHooks.attach(module, {}, function() return state end, function() end, room)
    local result, resultArgs, resultUser = callbacks.AthenaUse(nil, {}, function(source, args, user)
        return source, args, user
    end, athena, { value = 1 }, { id = 2 })
    _G.CurrentRun = priorRun

    lu.assertEquals(result, athena)
    lu.assertEquals(resultArgs, { value = 1 })
    lu.assertEquals(resultUser, { id = 2 })
    lu.assertEquals(resolvedContact, { kind = "encounterInteraction", phaseKey = "phase" })
    lu.assertEquals(bound, { handle = handle, native = athena })
    lu.assertNil(callbacks.HandleAthenaSpawn)
    lu.assertNil(callbacks.StartEncounterEffects)
end

function TestEncounters.testGorgonAthenaHandsItsPublishedOfferToOrdinaryUseLoot()
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
    local session = {
    }
    encounterHooks.attach(module, session, function() return state end, function() end, room)
    local result = callbacks.AthenaUse(nil, {}, function() return "native-use" end,
        athena, { value = 1 }, { id = 2 })
    _G.CurrentRun = priorRun

    lu.assertEquals(result, "native-use")
    lu.assertEquals(bound[athena], handle)
end
