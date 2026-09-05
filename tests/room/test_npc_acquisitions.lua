-- luacheck: globals TestNpcAcquisitions
local lu = require("luaunit")
local npc = require("mods.room.timeline.acquisitions.npc.hooks")

TestNpcAcquisitions = {}

local function capture()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    return module, callbacks
end

local function offer(giver, selected)
    local value = {
        kind = "traits", giver = giver, selected = "option2",
        options = {
            { key = giver .. "One" }, { key = selected }, { key = giver .. "Three" },
        },
    }
    return value
end

local function harness(giver, _, options)
    local module, callbacks = capture()
    local state = {}
    local source = { Name = giver }
    local handle = {}
    local row = {
        transaction = {
            owner = "encounter", kind = "encounterInteraction",
            resolution = { kind = "traitOffer", offer = options.offer },
        },
    }
    local active = {
        occurrence = { overview = { encounterPhases = {
            { slotKey = "phase", encounterKey = giver .. "Encounter" },
        } } },
    }
    local bound = {}
    local payloads = { [handle] = row }
    local mismatches, completions = {}, {}
    local session = {
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = { checkpoint = checkpoint, expected = expected, observed = observed }
        end,
        complete = function(_, currentHandle)
            completions[#completions + 1] = { handle = currentHandle }
            return true
        end,
    }
    local room = {
        current = function() return active end,
        encounterHandle = function() return handle end,
        resolve = function(_, _, contact)
            if contact.kind == "encounterInteraction" and contact.phaseKey == "phase" then return handle end
        end,
        bind = function(_, _, currentHandle, native)
            bound[native] = currentHandle
            return currentHandle
        end,
        begin = function(_, currentHandle) return payloads[currentHandle] end,
        peek = function(_, currentHandle) return payloads[currentHandle] end,
    }
    npc.attach(module, session, function() return state end, function() end, room)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = {
        CurrentRoom = { Encounter = { Name = giver .. "Encounter" } },
        Hero = { Traits = {} },
    }
    local function finish()
        _G.CurrentRun = priorRun
    end
    return callbacks, source, handle, row, active, room, payloads, bound, mismatches, completions, finish
end

local function runMenu(callbacks, callbackName, source, args, selected, body, afterSelection, beforeMenu)
    return callbacks[callbackName](nil, {}, function(nativeSource, nativeArgs)
        if beforeMenu then beforeMenu(nativeSource, nativeArgs) end
        nativeSource.UpgradeOptions = nativeArgs.UpgradeOptions
        return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(openSource)
            _G.CurrentRun.Hero.Traits = { { Name = selected } }
            if body then body(openSource) end
            return callbacks.HandleUpgradeChoiceSelection(nil, {}, function()
                if afterSelection then afterSelection() end
                return true
            end,
                { Source = source }, { Data = { Name = selected } }, {})
        end, nativeSource, nativeArgs)
    end, source, args, { Source = source })
end

function TestNpcAcquisitions.testNpcMenuInstallsPublishedRowsAndCompletesExactSelection()
    local selected = "NarcissusTwo"
    local callbacks, source, _, _, _, _, _, _, _, completions, finish = harness(
        "Narcissus", selected, { offer = offer("Narcissus", selected) })
    local args = { UpgradeOptions = {
        { ItemName = "NarcissusThree", Marker = 3, GameStateRequirements = { "native" } },
        { ItemName = "NarcissusOne", Marker = 1 },
        { ItemName = selected, Marker = 2, PriorityRequirements = { "priority" } },
    } }
    local priorEligibility = _G.IsGameStateEligible
    _G.IsGameStateEligible = function() return true end
    runMenu(callbacks, "NarcissusBenefitChoice", source, args, selected, function(nativeSource)
        lu.assertEquals(nativeSource.UpgradeOptions, {
            { ItemName = "NarcissusOne", Marker = 1 },
            { ItemName = selected, Marker = 2, PriorityRequirements = { "priority" } },
            { ItemName = "NarcissusThree", Marker = 3, GameStateRequirements = { "native" } },
        })
    end)
    _G.IsGameStateEligible = priorEligibility
    finish()
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testSharedCarrierHandlesMedeaArachneAndNarcissus()
    for _, choice in ipairs({
        { giver = "Medea", callback = "MedeaCurseChoice" },
        { giver = "Arachne", callback = "ArachneCostumeChoice" },
        { giver = "Narcissus", callback = "NarcissusBenefitChoice" },
    }) do
        local selected = choice.giver .. "Two"
        local callbacks, source, _, _, _, _, _, _, _, completions, finish = harness(
            choice.giver, selected, { offer = offer(choice.giver, selected) })
        local args = { UpgradeOptions = {
            { ItemName = choice.giver .. "Three", Marker = 3 },
            { ItemName = choice.giver .. "One", Marker = 1 },
            { ItemName = selected, Marker = 2 },
        } }
        runMenu(callbacks, choice.callback, source, args, selected)
        finish()
        lu.assertEquals(#completions, 1, choice.giver)
    end
end

function TestNpcAcquisitions.testNpcInvocationDoesNotConsumeSharedNativeOptionPool()
    local selected = "NarcissusTwo"
    local callbacks, source, _, row, _, _, _, _, _, completions, finish = harness(
        "Narcissus", selected, { offer = offer("Narcissus", selected) })
    local args = { UpgradeOptions = {
        { ItemName = "NarcissusOne" },
        { ItemName = selected },
        { ItemName = "NarcissusThree" },
        { ItemName = "NarcissusFour" },
    } }
    runMenu(callbacks, "NarcissusBenefitChoice", source, args, selected)
    lu.assertEquals(#args.UpgradeOptions, 4)
    row.transaction.resolution.offer = offer("Narcissus", "NarcissusFour")
    runMenu(callbacks, "NarcissusBenefitChoice", source, args, "NarcissusFour")
    finish()
    lu.assertEquals(#completions, 2)
end

function TestNpcAcquisitions.testNativePreprocessingSeesAuthoredRowsBeforeMenuRestoration()
    local selected = "CirceTwo"
    local callbacks, source, _, _, _, _, _, _, _, completions, finish = harness(
        "Circe", selected, { offer = offer("Circe", selected) })
    local args = { UpgradeOptions = {
        { ItemName = "CirceThree", Marker = 3 },
        { ItemName = "CirceOne", Marker = 1 },
        { ItemName = selected, Marker = 2 },
    } }
    runMenu(callbacks, "CirceBlessingChoice", source, args, selected, function(nativeSource)
        lu.assertTrue(nativeSource.UpgradeOptions[1].NativePrepared)
        lu.assertEquals(nativeSource.UpgradeOptions[1].ItemName, "CirceOne")
    end, nil, function(_, nativeArgs)
        lu.assertEquals(nativeArgs.UpgradeOptions[1].ItemName, "CirceOne")
        nativeArgs.UpgradeOptions[1].NativePrepared = true
    end)
    finish()
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testNativeNpcPostSelectionSideEffectRunsWithOuterCompletion()
    local selected = "ArachneTwo"
    local callbacks, source, _, _, _, _, _, _, _, completions, finish = harness(
        "Arachne", selected, { offer = offer("Arachne", selected) })
    local nativeSideEffect = false
    local args = { UpgradeOptions = {
        { ItemName = "ArachneOne" }, { ItemName = selected }, { ItemName = "ArachneThree" },
    } }
    runMenu(callbacks, "ArachneCostumeChoice", source, args, selected, nil, function()
        nativeSideEffect = true
    end)
    finish()
    lu.assertTrue(nativeSideEffect)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testUnavailablePublishedNpcRowLeavesNativeMenuIntact()
    local selected = "NarcissusTwo"
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Narcissus", selected, { offer = offer("Narcissus", selected) })
    local args = { UpgradeOptions = {
        { ItemName = "NarcissusOne", GameStateRequirements = { "missing-requirement" } },
        { ItemName = selected },
        { ItemName = "NarcissusThree" },
    } }
    local priorEligibility = _G.IsGameStateEligible
    _G.IsGameStateEligible = function() return false end
    runMenu(callbacks, "NarcissusBenefitChoice", source, args, selected, function(nativeSource)
        lu.assertEquals(nativeSource.UpgradeOptions, args.UpgradeOptions)
    end)
    _G.IsGameStateEligible = priorEligibility
    finish()
    lu.assertEquals(#completions, 0)
    lu.assertEquals(mismatches[1].checkpoint, "npc-trait-offer")
end
