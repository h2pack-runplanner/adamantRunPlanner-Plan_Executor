-- luacheck: globals TestNpcAcquisitions
local lu = require("luaunit")
local npc = require("mods.room.timeline.acquisitions.npc.hooks")
local traitSeaStar = require("mods.room.timeline.acquisitions.sea_star").create()
local traits = require("mods.room.timeline.acquisitions.traits.hooks")
local circe = require("mods.room.timeline.acquisitions.npc.circe")
local icarus = require("mods.room.timeline.acquisitions.npc.icarus")
local echo = require("mods.room.timeline.acquisitions.npc.echo")
local nativeGame = require("tests.harness.native_game")

TestNpcAcquisitions = {}

function TestNpcAcquisitions:setUp()
    self.restoreNative = nativeGame.install({
        TraitData = nativeGame.anyTraitDeclarations(),
        IsGameStateEligible = nativeGame.alwaysEligible,
    })
end

function TestNpcAcquisitions:tearDown()
    self.restoreNative()
end

local function capture()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback)
        local inner = callbacks[name]
        if inner == nil then
            callbacks[name] = callback
        else
            callbacks[name] = function(host, runtime, base, ...)
                return callback(host, runtime, function(...)
                    return inner(host, runtime, base, ...)
                end, ...)
            end
        end
    end } }
    return module, callbacks
end

local function offer(giver, selected, circeResolution, icarusHammerTarget)
    local value = {
        kind = "traits", giver = giver, selected = "option2",
        options = {
            { key = giver .. "One" }, { key = selected }, { key = giver .. "Three" },
        },
    }
    if circeResolution ~= nil then value.options[2].circeResolution = circeResolution end
    if icarusHammerTarget ~= nil then
        value.options[2].icarusHammerTarget = icarusHammerTarget
    end
    return value
end

local function harness(giver, _, options)
    local module, callbacks = capture()
    local state = { state = "synchronized" }
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
        bound = function(_, _, _, native)
            return native and bound[native] or nil
        end,
        begin = function(_, currentHandle) return payloads[currentHandle] end,
        peek = function(_, currentHandle) return payloads[currentHandle] end,
    }
    local npcScope = npc.attach(module, session, function() return state end, function() end, room)
    circe.attach(module, session, function() end, npcScope)
    icarus.attach(module, session, function() end, npcScope)
    local traitScopes
    if options.realTraitScopes then
        traitScopes = traits.attach(module, session, function() return state end,
            function() end, room, traitSeaStar)
    else
        traitScopes = {
            runExternalSelection = function(_, _, _, currentHandle, _, callback)
                local result = callback()
                session.complete(state, currentHandle)
                return result
            end,
        }
    end
    echo.attach(module, session, function() end, npcScope, traitScopes)
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

function TestNpcAcquisitions.testCirceActivationUsesExactPublishedArcanaThroughNativeMutation()
    local selected = "RandomArcanaTrait"
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Circe", selected, { offer = offer("Circe", selected,
            { kind = "activateArcana", arcanaKeys = { "ChanneledCast" } }) })
    local args = { UpgradeOptions = {
        { ItemName = "CirceOne" }, { ItemName = selected }, { ItemName = "CirceThree" },
    } }
    local activated = {}
    local nativeChanceCalls = 0
    runMenu(callbacks, "CirceBlessingChoice", source, args, selected, nil, function()
        callbacks.CirceRandomMetaUpgrade(nil, {}, function(acquireArgs)
            return callbacks.AddRandomMetaUpgrades(nil, {}, function()
                lu.assertFalse(callbacks.RandomChance(nil, {}, function()
                    nativeChanceCalls = nativeChanceCalls + 1
                    return false
                end, 0.1))
                local candidates = { "CardDraw", "ChanneledCast" }
                local target = callbacks.RemoveRandomValue(nil, {}, function(values)
                    return table.remove(values, 1)
                end, candidates)
                activated[target] = true
            end, acquireArgs.Count, {})
        end, { Count = 1 })
    end)
    finish()
    lu.assertEquals(activated, { ChanneledCast = true })
    lu.assertEquals(nativeChanceCalls, 1)
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testCirceCastCountActivationAdmitsTheNativePositiveChanceBranch()
    local selected = "RandomArcanaTrait"
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Circe", selected, { offer = offer("Circe", selected,
            { kind = "activateArcana", arcanaKeys = { "CastCount" } }) })
    local args = { UpgradeOptions = {
        { ItemName = "CirceOne" }, { ItemName = selected }, { ItemName = "CirceThree" },
    } }
    local activated
    local nativeChanceCalls = 0
    runMenu(callbacks, "CirceBlessingChoice", source, args, selected, nil, function()
        callbacks.CirceRandomMetaUpgrade(nil, {}, function(acquireArgs)
            return callbacks.AddRandomMetaUpgrades(nil, {}, function()
                local primary = { "ChanneledCast" }
                if callbacks.RandomChance(nil, {}, function()
                    nativeChanceCalls = nativeChanceCalls + 1
                    return false
                end, 0.1) then
                    primary[#primary + 1] = "CastCount"
                end
                activated = callbacks.RemoveRandomValue(nil, {}, function(values)
                    return table.remove(values, 1)
                end, primary)
            end, acquireArgs.Count, {})
        end, { Count = 1 })
    end)
    finish()
    lu.assertEquals(activated, "CastCount")
    lu.assertEquals(nativeChanceCalls, 0)
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testUnavailableCirceTargetReportsMismatchAndLeavesNativeMutationRunning()
    local selected = "RandomArcanaTrait"
    local callbacks, source, _, _, _, _, _, _, mismatches, _, finish = harness(
        "Circe", selected, { offer = offer("Circe", selected,
            { kind = "activateArcana", arcanaKeys = { "ChanneledCast" } }) })
    local args = { UpgradeOptions = {
        { ItemName = "CirceOne" }, { ItemName = selected }, { ItemName = "CirceThree" },
    } }
    local nativeTarget
    runMenu(callbacks, "CirceBlessingChoice", source, args, selected, nil, function()
        callbacks.CirceRandomMetaUpgrade(nil, {}, function(acquireArgs)
            callbacks.AddRandomMetaUpgrades(nil, {}, function()
                nativeTarget = callbacks.RemoveRandomValue(nil, {}, function(values)
                    return table.remove(values, 1)
                end, { "CardDraw" })
            end, acquireArgs.Count, {})
        end, { Count = 1 })
    end)
    finish()
    lu.assertEquals(nativeTarget, "CardDraw")
    lu.assertEquals(mismatches[1], {
        checkpoint = "circe-consequence-selection",
        expected = "ChanneledCast",
        observed = "missing native candidate",
    })
end

function TestNpcAcquisitions.testCircePromotionUsesExactPublishedArcanaThroughNativeMutation()
    local selected = "ArcanaRarityTrait"
    local callbacks, source, _, _, _, _, _, _, mismatches, _, finish = harness(
        "Circe", selected, { offer = offer("Circe", selected,
            { kind = "promoteArcana", arcanaKeys = { "CastCount", "CardDraw" } }) })
    local args = { UpgradeOptions = {
        { ItemName = "CirceOne" }, { ItemName = selected }, { ItemName = "CirceThree" },
    } }
    local promoted = {}
    runMenu(callbacks, "CirceBlessingChoice", source, args, selected, nil, function()
        callbacks.CirceMetaUpgradeRarity(nil, {}, function()
            local candidates = {
                { MetaUpgradeName = "CardDraw" },
                { MetaUpgradeName = "CastCount" },
                { MetaUpgradeName = "ChanneledCast" },
            }
            for _ = 1, 2 do
                local target = callbacks.RemoveRandomValue(nil, {}, function(values)
                    return table.remove(values, 1)
                end, candidates)
                promoted[#promoted + 1] = target.MetaUpgradeName
            end
        end, { Count = 2 })
    end)
    finish()
    lu.assertEquals(promoted, { "CastCount", "CardDraw" })
    lu.assertEquals(#mismatches, 0)
end

function TestNpcAcquisitions.testCirceFearRemovalUsesExactPublishedVowThroughNativeMutation()
    local selected = "RemoveShrineTrait"
    local callbacks, source, _, _, _, _, _, _, mismatches, _, finish = harness(
        "Circe", selected, { offer = offer("Circe", selected,
            { kind = "disableFear", vowKey = "EnemyDamageShrineUpgrade" }) })
    local args = { UpgradeOptions = {
        { ItemName = "CirceOne" }, { ItemName = selected }, { ItemName = "CirceThree" },
    } }
    local disabled = {}
    runMenu(callbacks, "CirceBlessingChoice", source, args, selected, nil, function()
        callbacks.CirceRemoveShrineUpgrades(nil, {}, function()
            local candidates = {
                EnemyHealthShrineUpgrade = true,
                EnemyDamageShrineUpgrade = true,
            }
            local target = callbacks.GetRandomKey(nil, {}, function()
                return "EnemyHealthShrineUpgrade"
            end, candidates)
            disabled[target] = true
        end, { Count = 1 })
    end)
    finish()
    lu.assertEquals(disabled, { EnemyDamageShrineUpgrade = true })
    lu.assertEquals(#mismatches, 0)
end

function TestNpcAcquisitions.testOrdinaryCirceChoiceRunsNoConsequenceActuator()
    local selected = "CirceShrinkTrait"
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Circe", selected, { offer = offer("Circe", selected) })
    local args = { UpgradeOptions = {
        { ItemName = "CirceOne" }, { ItemName = selected }, { ItemName = "CirceThree" },
    } }
    local nativeTarget
    runMenu(callbacks, "CirceBlessingChoice", source, args, selected, nil, function()
        callbacks.CirceMetaUpgradeRarity(nil, {}, function()
            nativeTarget = callbacks.RemoveRandomValue(nil, {}, function(values)
                return table.remove(values, 1)
            end, { { MetaUpgradeName = "CardDraw" } }).MetaUpgradeName
        end, { Count = 1 })
    end)
    finish()
    lu.assertEquals(nativeTarget, "CardDraw")
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testIcarusLatestModelUsesExactPublishedHammerThroughNativeMutation()
    local selected = "UpgradeHammerBoon"
    local target = "StaffDoubleAttackTrait"
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Icarus", selected, { offer = offer("Icarus", selected, nil, target) })
    local args = { UpgradeOptions = {
        { ItemName = "IcarusOne" }, { ItemName = selected }, { ItemName = "IcarusThree" },
    } }
    local upgraded
    runMenu(callbacks, "IcarusBenefitChoice", source, args, selected, nil, function()
        callbacks.UpgradeHammers(nil, {}, function()
            local candidates = {
                { Name = "AxeSpinSpeedTrait" }, { Name = target },
            }
            upgraded = callbacks.RemoveRandomValue(nil, {}, function(values)
                return table.remove(values, 1)
            end, candidates).Name
        end, { NumTraits = 1 })
    end)
    finish()
    lu.assertEquals(upgraded, target)
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testUnavailableIcarusHammerReportsMismatchAndLeavesNativeMutationRunning()
    local selected = "UpgradeHammerBoon"
    local callbacks, source, _, _, _, _, _, _, mismatches, _, finish = harness(
        "Icarus", selected, {
            offer = offer("Icarus", selected, nil, "StaffDoubleAttackTrait"),
        })
    local args = { UpgradeOptions = {
        { ItemName = "IcarusOne" }, { ItemName = selected }, { ItemName = "IcarusThree" },
    } }
    local upgraded
    runMenu(callbacks, "IcarusBenefitChoice", source, args, selected, nil, function()
        callbacks.UpgradeHammers(nil, {}, function()
            upgraded = callbacks.RemoveRandomValue(nil, {}, function(values)
                return table.remove(values, 1)
            end, { { Name = "AxeSpinSpeedTrait" } }).Name
        end, { NumTraits = 1 })
    end)
    finish()
    lu.assertEquals(upgraded, "AxeSpinSpeedTrait")
    lu.assertEquals(mismatches[1], {
        checkpoint = "icarus-hammer-selection",
        expected = "StaffDoubleAttackTrait",
        observed = "missing native candidate",
    })
end

function TestNpcAcquisitions.testOrdinaryIcarusTraitKeepsItsNativeSelectedEffect()
    local selected = "IcarusUpgradeBoon"
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Icarus", selected, { offer = offer("Icarus", selected) })
    local args = { UpgradeOptions = {
        { ItemName = "IcarusOne" }, { ItemName = selected }, { ItemName = "IcarusThree" },
    } }
    local nativeEffect = false
    runMenu(callbacks, "IcarusBenefitChoice", source, args, selected, nil, function()
        nativeEffect = true
    end)
    finish()
    lu.assertTrue(nativeEffect)
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testEchoBoonReplayInstallsMixedProviderRowsAndSelectsExactTrait()
    local selected = "EchoLastRunBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoLastRunBoon = {
        options = {
            { giver = "Hera", key = "HeraWeaponBoon", rarity = "Rare" },
            { giver = "Zeus", key = "ZeusSpecialBoon", rarity = "Epic" },
            { giver = "Hermes", key = "SprintBoon", rarity = "Common" },
        },
        selected = "option2",
    }
    local callbacks, source, _, _, _, _, _, _, _, completions, finish = harness(
        "Echo", selected, { offer = outer })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local nestedRows
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        callbacks.EchoLastRunBoon(nil, {}, function()
            local nestedSource = { UpgradeOptions = {} }
            return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(openSource)
                nestedRows = openSource.UpgradeOptions
                return callbacks.SelectEchoBoon(nil, {}, function() return true end,
                    { Source = openSource }, { Data = { Name = "ZeusSpecialBoon" } }, {})
            end, nestedSource, {})
        end, {}, {})
    end)
    finish()
    lu.assertEquals(nestedRows, {
        { Type = "Trait", ItemName = "HeraWeaponBoon", Rarity = "Rare" },
        { Type = "Trait", ItemName = "ZeusSpecialBoon", Rarity = "Epic" },
        { Type = "Trait", ItemName = "SprintBoon", Rarity = "Common" },
    })
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testEchoBoonReplayKeepsNaturalSelectionScopedUntilItsAsyncAcquireTerminal()
    local selected = "EchoLastRunBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoLastRunBoon = {
        options = {
            {
                giver = "Demeter", key = "GoodStuffBoon", rarity = "Duo",
                naturalSelectionTargets = { "Attack", "Special" },
            },
        },
        selected = "option1",
    }
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Echo", selected, { offer = outer, realTraitScopes = true })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local queued, shuffled, applied
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        callbacks.EchoLastRunBoon(nil, {}, function()
            local nestedSource = { UpgradeOptions = {} }
            return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(openSource)
                return callbacks.SelectEchoBoon(nil, {}, function()
                    queued = function()
                        callbacks.DistributeLevels(nil, {}, function()
                            shuffled = callbacks.FYShuffle(nil, {}, function(values) return values end,
                                { "Special", "Attack", "Cast" })
                            applied = {}
                            for _, key in ipairs({ "Attack", "Special" }) do
                                callbacks.IncreaseTraitLevel(nil, {}, function(trait)
                                    applied[#applied + 1] = trait.Name
                                end, { Name = key })
                            end
                        end, { Slots = {} }, { Name = "GoodStuffBoon" })
                    end
                    return true
                end, { Source = openSource }, { Data = { Name = "GoodStuffBoon" } }, {})
            end, nestedSource, {})
        end, {}, {})
    end)
    lu.assertNotNil(queued)
    lu.assertEquals(#completions, 0)
    queued()
    finish()
    lu.assertEquals(shuffled, { "Attack", "Special", "Cast" })
    lu.assertEquals(applied, { "Attack", "Special" })
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testEchoBoonReplayKeepsAllTogetherScopedUntilItsNativeGrantTerminal()
    local selected = "EchoLastRunBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoLastRunBoon = {
        options = {
            { giver = "Hera", key = "AllElementalBoon", rarity = "Legendary",
                allTogetherResult = {
                    earth = "Earth", fire = "Fire", air = "Air", water = "Water",
                },
            },
        },
        selected = "option1",
    }
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Echo", selected, { offer = outer, realTraitScopes = true })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local queued, granted
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        callbacks.EchoLastRunBoon(nil, {}, function()
            local nestedSource = { UpgradeOptions = {} }
            return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(openSource)
                return callbacks.SelectEchoBoon(nil, {}, function()
                    queued = function()
                        granted = {}
                        callbacks.GrantBoons(nil, {}, function(grantArgs)
                            for _, candidates in ipairs(grantArgs.BoonSets) do
                                granted[#granted + 1] = callbacks.GetRandomValue(nil, {},
                                    function(values) return values[1] end, candidates)
                            end
                        end, { BoonSets = {
                            { "OtherEarth", "Earth" }, { "OtherFire", "Fire" },
                            { "OtherAir", "Air" }, { "OtherWater", "Water" },
                        } }, { Name = "AllElementalBoon" })
                    end
                    return true
                end, { Source = openSource }, { Data = { Name = "AllElementalBoon" } }, {})
            end, nestedSource, {})
        end, {}, {})
    end)
    lu.assertNotNil(queued)
    lu.assertEquals(#completions, 0)
    queued()
    finish()
    lu.assertEquals(granted, { "Earth", "Fire", "Air", "Water" })
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testEchoBoonReplayKeepsBridalGlowTargetScopedUntilItsAsyncAcquireTerminal()
    local selected = "EchoLastRunBoon"
    local target = "ZeusWeaponBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoLastRunBoon = {
        options = {
            { giver = "Hera", key = "HeraSuperchargeBoon", rarity = "Rare", targetTraitKey = target },
        },
        selected = "option1",
    }
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Echo", selected, { offer = outer, realTraitScopes = true })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local bridalGlow = { Name = "HeraSuperchargeBoon" }
    local queued, upgraded
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        callbacks.EchoLastRunBoon(nil, {}, function()
            local nestedSource = { UpgradeOptions = {} }
            return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(openSource)
                return callbacks.SelectEchoBoon(nil, {}, function()
                    queued = function()
                        callbacks.HeraSuperchargeBoon(nil, {}, function()
                            callbacks.AddRarityToTraits(nil, {}, function(_, rarityArgs)
                                upgraded = rarityArgs.ForceUpgrade[1].Name
                                return rarityArgs.ForceUpgrade[1]
                            end, bridalGlow, {})
                        end, {}, bridalGlow, {})
                    end
                    return true
                end, { Source = openSource }, { Data = { Name = "HeraSuperchargeBoon" } }, {})
            end, nestedSource, {})
        end, {}, {})
    end)
    lu.assertNotNil(queued)
    lu.assertEquals(#completions, 0)
    _G.CurrentRun.Hero.Traits = { { Name = target } }
    queued()
    finish()
    lu.assertEquals(upgraded, target)
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testBridalGlowTerminalWaitsForItsOuterSelectionToReturn()
    local selected = "EchoLastRunBoon"
    local target = "ZeusWeaponBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoLastRunBoon = {
        options = {
            { giver = "Hera", key = "HeraSuperchargeBoon", rarity = "Rare", targetTraitKey = target },
        },
        selected = "option1",
    }
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Echo", selected, { offer = outer, realTraitScopes = true })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local bridalGlow = { Name = "HeraSuperchargeBoon" }
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        callbacks.EchoLastRunBoon(nil, {}, function()
            local nestedSource = { UpgradeOptions = {} }
            return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(openSource)
                return callbacks.SelectEchoBoon(nil, {}, function()
                    _G.CurrentRun.Hero.Traits = { { Name = target } }
                    callbacks.HeraSuperchargeBoon(nil, {}, function()
                        callbacks.AddRarityToTraits(nil, {}, function(_, rarityArgs)
                            return rarityArgs.ForceUpgrade[1]
                        end, bridalGlow, {})
                    end, {}, bridalGlow, {})
                    -- A scheduler may run the acquire terminal before this
                    -- selected native callback returns.
                    lu.assertEquals(#completions, 0)
                    return true
                end, { Source = openSource }, { Data = { Name = "HeraSuperchargeBoon" } }, {})
            end, nestedSource, {})
        end, {}, {})
    end)
    finish()
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testEchoBoonReplayUsesPublishedProviderForNativeLootHistory()
    local selected = "EchoLastRunBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoLastRunBoon = {
        options = {
            {
                giver = "Aphrodite", key = "SprintEchoBoon", rarity = "Duo",
                lootHistorySource = "AphroditeUpgrade",
            },
            { giver = "Artemis", key = "SupportingFireBoon", rarity = "Rare" },
        },
        selected = "option1",
    }
    local callbacks, source, _, _, _, _, _, _, mismatches, _, finish = harness(
        "Echo", selected, { offer = outer })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local published, native
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        callbacks.EchoLastRunBoon(nil, {}, function()
            local nestedSource = { UpgradeOptions = {} }
            return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(openSource)
                return callbacks.SelectEchoBoon(nil, {}, function()
                    published = callbacks.GetLootSourceName(nil, {}, function() return "NativeSource" end,
                        "SprintEchoBoon", {})
                    native = callbacks.GetLootSourceName(nil, {}, function() return "NativeSource" end,
                        "SupportingFireBoon", {})
                    return true
                end, { Source = openSource }, { Data = { Name = "SprintEchoBoon" } }, {})
            end, nestedSource, {})
        end, {}, {})
    end)
    finish()
    lu.assertEquals(published, "AphroditeUpgrade")
    lu.assertEquals(native, "NativeSource")
    lu.assertEquals(#mismatches, 0)
end

function TestNpcAcquisitions.testEchoBoonReplayLeavesNativeLootHistoryLookupWhenSourceIsAbsent()
    local selected = "EchoLastRunBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoLastRunBoon = {
        options = {
            { giver = "Artemis", key = "SupportingFireBoon", rarity = "Rare" },
        },
        selected = "option1",
    }
    local callbacks, source, _, _, _, _, _, _, mismatches, _, finish = harness(
        "Echo", selected, { offer = outer })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local observed
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        callbacks.EchoLastRunBoon(nil, {}, function()
            local nestedSource = { UpgradeOptions = {} }
            return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(openSource)
                return callbacks.SelectEchoBoon(nil, {}, function()
                    observed = callbacks.GetLootSourceName(nil, {}, function() return "NativeArtemis" end,
                        "SupportingFireBoon", {})
                    return true
                end, { Source = openSource }, { Data = { Name = "SupportingFireBoon" } }, {})
            end, nestedSource, {})
        end, {}, {})
    end)
    finish()
    lu.assertEquals(observed, "NativeArtemis")
    lu.assertEquals(#mismatches, 0)
end

function TestNpcAcquisitions.testEchoPomSteersNativeGreatestLevelSelection()
    local selected = "EchoDoubleLevelBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoPomTarget = "ZeusWeaponBoon"
    local callbacks, source, _, _, _, _, _, _, _, completions, finish = harness(
        "Echo", selected, { offer = outer })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local observed
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        callbacks.EchoDoubleLevelBoon(nil, {}, function()
            observed = callbacks.GetRandomKey(nil, {}, function() return "ApolloWeaponBoon" end,
                { ZeusWeaponBoon = true, ApolloWeaponBoon = true })
        end)
    end)
    finish()
    lu.assertEquals(observed, "ZeusWeaponBoon")
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testEchoPomJsonNullCompletesWithoutSteeringNativeSelection()
    local selected = "EchoDoubleLevelBoon"
    local outer = offer("Echo", selected)
    outer.options[2].echoPomTarget = require("mods/protocol/json").null
    local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
        "Echo", selected, { offer = outer })
    local args = { UpgradeOptions = {
        { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
    } }
    local queued, observed
    runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
        queued = function()
            callbacks.EchoDoubleLevelBoon(nil, {}, function()
                observed = callbacks.GetRandomKey(nil, {}, function() return "ApolloWeaponBoon" end,
                    { ZeusWeaponBoon = true, ApolloWeaponBoon = true })
            end)
        end
    end)
    lu.assertNotNil(queued)
    lu.assertEquals(#completions, 0)
    queued()
    finish()
    lu.assertEquals(observed, "ApolloWeaponBoon")
    lu.assertEquals(#mismatches, 0)
    lu.assertEquals(#completions, 1)
end

function TestNpcAcquisitions.testOtherEchoChoicesRemainNativeAuthoritative()
    for _, selected in ipairs({
        "EchoLastReward", "EchoDeathDefianceRefill", "DiminishingDodgeBoon",
        "DiminishingHealthAndManaBoon", "EchoDoubleShop", "EchoRepeatKeepsakeBoon",
    }) do
        local callbacks, source, _, _, _, _, _, _, mismatches, completions, finish = harness(
            "Echo", selected, { offer = offer("Echo", selected) })
        local args = { UpgradeOptions = {
            { ItemName = "EchoOne" }, { ItemName = selected }, { ItemName = "EchoThree" },
        } }
        local nativeEffect = false
        runMenu(callbacks, "EchoChoice", source, args, selected, nil, function()
            nativeEffect = true
        end)
        finish()
        lu.assertTrue(nativeEffect, selected)
        lu.assertEquals(#mismatches, 0, selected)
        lu.assertEquals(#completions, 1, selected)
    end
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
