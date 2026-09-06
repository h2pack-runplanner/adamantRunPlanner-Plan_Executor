-- Residual automatic and resource native-contact witnesses.
-- luacheck: globals TestResidualNativeContacts
local lu = require("luaunit")
local coordinator = require("mods.room.coordinator")
local runtimeSession = require("mods.runtime.session")
local automatic = require("mods.room.timeline.encounters.automatic")
local boss = require("mods.room.timeline.encounters.boss")
local resources = require("mods.room.features.resources")

TestResidualNativeContacts = {}

local function capture()
    local callbacks = {}
    return {
        hooks = {
            wrap = function(name, _, callback) callbacks[name] = callback end,
        },
    }, callbacks
end

local function transaction(effect, windowKind, values)
    local result = {
        owner = "automatic:" .. effect,
        kind = "automatic",
        effect = effect,
        phaseKey = "phase",
        window = {
            kind = windowKind,
            phaseKey = "phase",
        },
    }
    for key, value in pairs(values or {}) do result[key] = value end
    return result
end

local function harness(transactions, resourceRows)
    local phase = { slotKey = "phase", encounterKey = "TestEncounter" }
    local byOwner = {}
    local obligations = {}
    for _, row in ipairs(transactions or {}) do
        byOwner[row.owner] = row
        obligations[#obligations + 1] = { owner = row.owner, checkpoint = "roomExit" }
    end
    local occurrence = {
        id = "room", gameName = "F_Test",
        overview = {
            encounterPhases = { phase }, requiredObjects = {}, additional = {},
            resources = resourceRows or {},
        },
        transactionsByOwner = byOwner,
        timeline = { transactions = transactions or {}, dependencies = {}, obligations = obligations },
        roomExitConformance = { facts = {} }, conformanceExpected = {},
    }
    local plan = { occurrencesById = { room = occurrence } }
    local state = { state = "synchronized", plan = plan }
    state.room = coordinator.new(plan, function(errorValue, expected, observed)
        return runtimeSession.mismatch(state, errorValue, expected, observed)
    end)
    local active = assert(coordinator.enter(state, occurrence))
    local nativeEncounter = { Name = "TestEncounter" }
    assert(coordinator.bindEncounter(state, nativeEncounter, "phase"))
    local module, callbacks = capture()
    local reports = 0
    local function report() reports = reports + 1 end
    return {
        active = active,
        callbacks = callbacks,
        close = function()
            return coordinator.close(state, _G.CurrentRun or {}, {})
        end,
        encounterEnd = function()
            assert(coordinator.window(state, "encounterEnd:phase"))
        end,
        module = module,
        nativeEncounter = nativeEncounter,
        report = report,
        reports = function() return reports end,
        state = state,
    }
end

local function withCurrentRun(value, callback)
    local prior = _G.CurrentRun
    _G.CurrentRun = value
    local ok, result = pcall(callback)
    _G.CurrentRun = prior
    if not ok then error(result, 0) end
    return result
end

function TestResidualNativeContacts.testSuccessfulResourcePointKeepsNativeGrantAuthoritative()
    local fixture = harness({})
    fixture.state.plan.resources = { occurrences = { {
        occurrenceId = "resource-room",
        pointDispositions = {
            Pickaxe = "force", Exorcism = "native", Shovel = "native", Fishing = "native",
        },
    } } }
    resources.attach(fixture.module, function() return fixture.state end, fixture.report)
    local args = { SkipDelay = true, SkipActivatedTraitUpdate = true }
    local nativeCalls = 0
    local addedTrait
    local result = withCurrentRun({
        CurrentRoom = { __runPlannerExecutionRoomId = "resource-room" },
    }, function()
        return fixture.callbacks.GrantElementFromTool(nil, {}, function(toolName, receivedArgs)
            nativeCalls = nativeCalls + 1
            lu.assertEquals(toolName, "ToolPickaxe2")
            lu.assertEquals(receivedArgs, args)
            lu.assertTrue(fixture.callbacks.RandomChance(nil, {}, function() return false end, 0.25, {}))
            addedTrait = {
                TraitName = "FireEssence",
                SkipActivatedTraitUpdate = receivedArgs.SkipActivatedTraitUpdate,
            }
            return addedTrait.TraitName
        end, "ToolPickaxe2", args)
    end)

    lu.assertEquals(result, "FireEssence")
    lu.assertEquals(addedTrait, { TraitName = "FireEssence", SkipActivatedTraitUpdate = true })
    lu.assertEquals(nativeCalls, 1)
    lu.assertEquals(fixture.reports(), 1)
    lu.assertEquals(fixture.state.state, "synchronized")
    lu.assertTrue(fixture.close())
end

function TestResidualNativeContacts.testSteadyGrowthSteersOnceAndCompletedOwnerCannotReplay()
    local growth = transaction("steadyGrowth", "encounterEnd", {
        source = "BoonGrowthBoon", target = "ApolloWeaponBoon",
    })
    local fixture = harness({ growth })
    automatic.attach(fixture.module, runtimeSession, function() return fixture.state end,
        fixture.report, coordinator)
    local target = { Name = "ApolloWeaponBoon", Rarity = "Common" }
    local nativeFallback = { Name = "ZeusWeaponBoon", Rarity = "Rare" }
    local nativeForceUpgrade = { nativeFallback }
    local args = {
        NumTraits = 1,
        LowPriorityTraitName = "BoonGrowthBoon",
        ForceUpgrade = nativeForceUpgrade,
    }
    local forced = {}
    local function nativeRarity(_, receivedArgs)
        local selected = receivedArgs.ForceUpgrade and receivedArgs.ForceUpgrade[1] or nativeFallback
        forced[#forced + 1] = receivedArgs.ForceUpgrade and selected.Name or "native"
        return { Name = selected.Name, Rarity = "Rare" }
    end

    withCurrentRun({ Hero = { Traits = { target, nativeFallback } } }, function()
        fixture.encounterEnd()
        local incidental = fixture.callbacks.AddRarityToTraits(nil, {}, nativeRarity,
            { Name = "OtherRaritySource" }, args)
        lu.assertEquals(incidental.Name, "ZeusWeaponBoon")
        lu.assertTrue(rawequal(args.ForceUpgrade, nativeForceUpgrade))
        local first = fixture.callbacks.AddRarityToTraits(nil, {}, nativeRarity,
            { Name = "BoonGrowthBoon" }, args)
        lu.assertEquals(first.Name, "ApolloWeaponBoon")
        lu.assertTrue(rawequal(args.ForceUpgrade, nativeForceUpgrade))
        local repeated = fixture.callbacks.AddRarityToTraits(nil, {}, nativeRarity,
            { Name = "BoonGrowthBoon" }, args)
        lu.assertEquals(repeated.Name, "ZeusWeaponBoon")
    end)

    lu.assertEquals(forced, { "ZeusWeaponBoon", "ApolloWeaponBoon", "ZeusWeaponBoon" })
    lu.assertTrue(rawequal(args.ForceUpgrade, nativeForceUpgrade))
    lu.assertEquals(fixture.state.state, "synchronized")
    lu.assertTrue(fixture.close())
end

function TestResidualNativeContacts.testSteadyGrowthRestoresNativeForceUpgradeBeforeRethrow()
    local growth = transaction("steadyGrowth", "encounterEnd", {
        source = "BoonGrowthBoon", target = "ApolloWeaponBoon",
    })
    local fixture = harness({ growth })
    automatic.attach(fixture.module, runtimeSession, function() return fixture.state end,
        fixture.report, coordinator)
    local target = { Name = "ApolloWeaponBoon", Rarity = "Common" }
    local nativeTarget = { Name = "NativeTarget", Rarity = "Common" }
    local nativeForceUpgrade = { nativeTarget }
    local args = { ForceUpgrade = nativeForceUpgrade }

    withCurrentRun({ Hero = { Traits = { target, nativeTarget } } }, function()
        fixture.encounterEnd()
        local ok, errorValue = pcall(fixture.callbacks.AddRarityToTraits,
            nil, {}, function(_, receivedArgs)
                lu.assertEquals(receivedArgs.ForceUpgrade, { target })
                error("native rarity failure")
            end, { Name = "BoonGrowthBoon" }, args)
        lu.assertFalse(ok)
        lu.assertStrContains(errorValue, "native rarity failure")
        lu.assertTrue(rawequal(args.ForceUpgrade, nativeForceUpgrade))

        local result = fixture.callbacks.AddRarityToTraits(nil, {}, function(_, receivedArgs)
            lu.assertEquals(receivedArgs.ForceUpgrade, { target })
            return { Name = receivedArgs.ForceUpgrade[1].Name, Rarity = "Rare" }
        end, { Name = "BoonGrowthBoon" }, args)
        lu.assertEquals(result.Name, "ApolloWeaponBoon")
    end)

    lu.assertTrue(rawequal(args.ForceUpgrade, nativeForceUpgrade))
    lu.assertEquals(fixture.state.state, "synchronized")
    lu.assertTrue(fixture.close())
end

function TestResidualNativeContacts.testTranscendentEmbryoSteersIdentityRarityAndProcessedValues()
    local embryo = transaction("transcendentEmbryo", "encounterEnd", {
        source = "RandomBlessingKeepsake",
        target = "ChaosExSpeedBlessing",
        rarity = "Heroic",
        blessingValues = { propertySpeed = 0.72, weaponSpeed = 0.83 },
    })
    local fixture = harness({ embryo })
    automatic.attach(fixture.module, runtimeSession, function() return fixture.state end,
        fixture.report, coordinator)
    local selected
    local granted
    local receivedRarity

    withCurrentRun({ Hero = { Traits = {} } }, function()
        fixture.encounterEnd()
        local result = fixture.callbacks.AddRandomChaosBlessing(nil, {}, function(rarity)
            receivedRarity = rarity
            selected = fixture.callbacks.GetRandomArrayValue(nil, {}, function(values)
                return values[1]
            end, { "ChaosWeaponBlessing", "ChaosExSpeedBlessing" })
            granted = fixture.callbacks.GetProcessedTraitData(nil, {}, function(args)
                return {
                    Name = args.TraitName,
                    Rarity = args.Rarity,
                    PropertyChanges = { { ChangeValue = 1.1 } },
                    WeaponSpeedMultiplier = { Value = 1.2 },
                }
            end, { TraitName = selected, Rarity = rarity })
            return granted
        end, "Common")
        lu.assertEquals(result, granted)
    end)

    lu.assertEquals(receivedRarity, "Heroic")
    lu.assertEquals(selected, "ChaosExSpeedBlessing")
    lu.assertEquals(granted, {
        Name = "ChaosExSpeedBlessing", Rarity = "Heroic",
        PropertyChanges = { { ChangeValue = 0.72 } },
        WeaponSpeedMultiplier = { Value = 0.83 },
    })
    lu.assertEquals(fixture.state.state, "synchronized")
    lu.assertTrue(fixture.close())
end

function TestResidualNativeContacts.testBossContactSteersOrderedJudgmentAndCrystalFigurineSets()
    local judgment = transaction("judgment", "bossDefeated", {
        arcanaKeys = { "TheChampions", "TheFates" }, rarity = "Rare",
    })
    local figurine = transaction("crystalFigurine", "bossDefeated", {
        arcanaKeys = { "TheSorceress", "TheMoon" }, rarity = "Epic",
    })
    local fixture = harness({ judgment, figurine })
    boss.attach(fixture.module, runtimeSession, function() return fixture.state end,
        fixture.report, coordinator)
    local selected = { judgment = {}, crystalFigurine = {} }
    local nativeReturns = {}

    local function nativeArcana(effect, count, args, candidates)
        lu.assertEquals(count, 2)
        if effect == "crystalFigurine" then
            lu.assertEquals(args.RarityLevel, 3)
        else
            lu.assertNil(args.RarityLevel)
        end
        for _ = 1, count do
            selected[effect][#selected[effect] + 1] = fixture.callbacks.RemoveRandomValue(
                nil, {}, function(values) return table.remove(values, 1) end, candidates)
        end
        nativeReturns[effect] = effect .. ":native-return"
        return nativeReturns[effect]
    end

    withCurrentRun({ Hero = { Traits = {} }, CurrentRoom = { Encounter = fixture.nativeEncounter } }, function()
        local killResult = fixture.callbacks.Kill(nil, {}, function()
            lu.assertEquals(fixture.callbacks.AddRandomMetaUpgrades(nil, {}, function(count, args)
                return nativeArcana("judgment", count, args,
                    { "Distractor", "TheFates", "TheChampions" })
            end, 2, {}), "judgment:native-return")
            lu.assertEquals(fixture.callbacks.AddRandomMetaUpgrades(nil, {}, function(count, args)
                return nativeArcana("crystalFigurine", count, args,
                    { "TheMoon", "Distractor", "TheSorceress" })
            end, 2, { RarityLevel = 3 }), "crystalFigurine:native-return")
            return "kill:native-return"
        end, { IsBoss = true }, {})
        lu.assertEquals(killResult, "kill:native-return")
    end)

    lu.assertEquals(selected.judgment, { "TheChampions", "TheFates" })
    lu.assertEquals(selected.crystalFigurine, { "TheSorceress", "TheMoon" })
    lu.assertEquals(nativeReturns, {
        judgment = "judgment:native-return",
        crystalFigurine = "crystalFigurine:native-return",
    })
    lu.assertEquals(fixture.state.state, "synchronized")
    lu.assertTrue(fixture.close())
end

function TestResidualNativeContacts.testBossArcanaExcessCountReturnsNativelyAndMismatchesCardinality()
    local judgment = transaction("judgment", "bossDefeated", {
        arcanaKeys = { "TheChampions", "TheFates" }, rarity = "Rare",
    })
    local fixture = harness({ judgment })
    local completions = 0
    local observedSession = {
        mismatch = runtimeSession.mismatch,
        complete = function(state, handle)
            completions = completions + 1
            return runtimeSession.complete(state, handle)
        end,
    }
    boss.attach(fixture.module, observedSession, function() return fixture.state end,
        fixture.report, coordinator)
    local selected = {}

    withCurrentRun({ Hero = { Traits = {} }, CurrentRoom = { Encounter = fixture.nativeEncounter } }, function()
        local killResult = fixture.callbacks.Kill(nil, {}, function()
            local result = fixture.callbacks.AddRandomMetaUpgrades(nil, {}, function(count)
                local candidates = { "NativeCard", "TheFates", "TheChampions" }
                for _ = 1, count do
                    selected[#selected + 1] = fixture.callbacks.RemoveRandomValue(
                        nil, {}, function(values) return table.remove(values, 1) end, candidates)
                end
                return "arcana:native-return"
            end, 3, {})
            lu.assertEquals(result, "arcana:native-return")
            return "kill:native-return"
        end, { IsBoss = true }, {})
        lu.assertEquals(killResult, "kill:native-return")
    end)

    lu.assertEquals(selected, { "TheChampions", "TheFates", "NativeCard" })
    lu.assertEquals(completions, 0)
    lu.assertEquals(fixture.state.state, "desynchronized")
    lu.assertEquals(fixture.state.firstMismatch, {
        checkpoint = "boss-arcana-cardinality", expected = 2, observed = 3,
    })
end

function TestResidualNativeContacts.testUnavailableAutomaticTargetRecordsFirstMismatchAfterNativeReturn()
    local growth = transaction("steadyGrowth", "encounterEnd", {
        source = "BoonGrowthBoon", target = "UnavailableBoon",
    })
    local fixture = harness({ growth })
    automatic.attach(fixture.module, runtimeSession, function() return fixture.state end,
        fixture.report, coordinator)
    local args = { NumTraits = 1 }
    local nativeCalls = 0
    local nativeResult = { Name = "NativeEligibleBoon", Rarity = "Rare" }

    withCurrentRun({ Hero = { Traits = { { Name = "NativeEligibleBoon", Rarity = "Common" } } } }, function()
        fixture.encounterEnd()
        local result = fixture.callbacks.AddRarityToTraits(nil, {}, function(_, receivedArgs)
            nativeCalls = nativeCalls + 1
            lu.assertNil(receivedArgs.ForceUpgrade)
            return nativeResult
        end, { Name = "BoonGrowthBoon" }, args)
        lu.assertEquals(result, nativeResult)
        local passThrough = fixture.callbacks.AddRarityToTraits(nil, {}, function()
            nativeCalls = nativeCalls + 1
            return "desynchronized-native-return"
        end, { Name = "BoonGrowthBoon" }, args)
        lu.assertEquals(passThrough, "desynchronized-native-return")
    end)

    lu.assertEquals(nativeCalls, 2)
    lu.assertEquals(fixture.state.state, "desynchronized")
    lu.assertEquals(fixture.state.firstMismatch, {
        checkpoint = "steady-growth-target",
        expected = "UnavailableBoon",
        observed = "NativeEligibleBoon",
    })
    runtimeSession.mismatch(fixture.state, "later-mismatch", "later", "ignored")
    lu.assertEquals(fixture.state.firstMismatch.checkpoint, "steady-growth-target")
end
