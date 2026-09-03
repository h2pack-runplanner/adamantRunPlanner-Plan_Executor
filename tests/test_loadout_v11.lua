local lu = require("luaunit")
local native = require("mods/loadout/native")
local session = require("mods/loadout/session")
local roomHooks = require("mods.room.hooks")
local loadoutHooks = require("mods/loadout/hooks")
local loadoutProtocol = require("mods/loadout/protocol")
local json = require("mods/json")

TestLoadoutV11 = {}

local function expected(hex)
    return {
        startingLoadout = {
            weaponKey = "WeaponStaffSwing", aspectKey = "BaseStaffAspect",
            arcana = { { key = "CardDraw", origin = "manual", rarity = "Epic" } },
            fear = { configuredRanks = { EnemyHealthShrineUpgrade = 1 }, effectiveRanks = { EnemyHealthShrineUpgrade = 1 } },
            startingHex = hex,
        },
        startingKeepsake = { keepsakeKey = "ManaOverTimeRefundKeepsake" },
    }
end

local function captureLoadoutHooks(state)
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local sessionAdapter = {
        start = function(target, _, phase)
            target.initialized = true
            target.state, target.reason = phase == "starting" and "starting" or "synchronized", "ready"
        end,
        current = function() end,
        mismatch = function(target, checkpoint, wanted, actual)
            target.state, target.firstMismatch = "mismatch", { checkpoint = checkpoint, expected = wanted, observed = actual }
            return nil
        end,
    }
    local getState = type(state) == "function" and state or function() return state end
    loadoutHooks.attach(module, { session = sessionAdapter, loadout = session, inbox = {} }, getState,
        function() end, sessionAdapter)
    _G.import = priorImport
    return callbacks
end

function TestLoadoutV11.testStartHookNeverReadsCacheBeforeCurrentRunExists()
    local priorGame, priorRun, priorWeapon, priorRarity, priorCards = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.TraitRarityData, _G.MetaUpgradeCardData
    _G.GameState = { LastWeaponUpgradeName = { WeaponStaffSwing = "WrongAspect" }, LastAwardTrait = "ManaOverTimeRefundKeepsake", ShrineUpgrades = { BossDifficultyShrineUpgrade = 1 }, MetaUpgradeState = {} }
    _G.GetEquippedWeapon = function() return "WeaponStaffSwing" end
    _G.TraitRarityData, _G.MetaUpgradeCardData = { RarityUpgradeOrder = { "Common", "Rare", "Epic" } }, {}
    local state = { plan = expected(nil), initialized = false, state = "inactive" }
    state.plan.startingLoadout.arcana = { { key = "CardDraw", origin = "manual", rarity = "Rare" } }
    state.plan.startingLoadout.fear = { configuredRanks = { BossDifficultyShrineUpgrade = 1 }, effectiveRanks = { BossDifficultyShrineUpgrade = 1 } }
    _G.CurrentRun = nil
    local callbacks, called = captureLoadoutHooks(function() return _G.CurrentRun and state or nil end), false
    local result = callbacks.StartNewRun(nil, {}, function()
        called = true
        _G.CurrentRun = { Hero = { TraitDictionary = { BaseStaffAspect = true } } }
        callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
        callbacks.EquipKeepsake(nil, {}, function() return true end, {}, "ManaOverTimeRefundKeepsake", {})
        return {}
    end, nil, {})
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.TraitRarityData, _G.MetaUpgradeCardData = priorGame, priorRun, priorWeapon, priorRarity, priorCards
    lu.assertNotNil(result)
    lu.assertTrue(called)
    lu.assertEquals(state.firstMismatch.checkpoint, "starting-aspect")
end

function TestLoadoutV11.testCreateNewHeroInitializesCurrentRunSession()
    local priorGame, priorRun, priorWeapon, priorRarity, priorCards = _G.GameState, _G.CurrentRun,
        _G.GetEquippedWeapon, _G.TraitRarityData, _G.MetaUpgradeCardData
    _G.GameState = {
        LastWeaponUpgradeName = { WeaponStaffSwing = "BaseStaffAspect" },
        LastAwardTrait = "ManaOverTimeRefundKeepsake", ShrineUpgrades = {}, MetaUpgradeState = {},
    }
    _G.CurrentRun = nil
    _G.GetEquippedWeapon = function() return "WeaponStaffSwing" end
    _G.TraitRarityData, _G.MetaUpgradeCardData = { RarityUpgradeOrder = { "Common", "Rare", "Epic" } }, {}
    local state = { plan = expected(nil), initialized = false, state = "inactive" }
    state.plan.startingLoadout.arcana = {}
    state.plan.startingLoadout.fear = { configuredRanks = {}, effectiveRanks = {} }
    local callbacks = captureLoadoutHooks(state)
    local result = callbacks.StartNewRun(nil, {}, function()
        _G.CurrentRun = { Hero = { TraitDictionary = { BaseStaffAspect = true } } }
        callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
        callbacks.EquipKeepsake(nil, {}, function() return true end, {}, "ManaOverTimeRefundKeepsake", {})
        return { started = true }
    end, nil, {})
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.TraitRarityData, _G.MetaUpgradeCardData =
        priorGame, priorRun, priorWeapon, priorRarity, priorCards
    lu.assertEquals(result, { started = true })
    lu.assertEquals(state.state, "synchronized")
end

function TestLoadoutV11.testStrictProtocolRejectsDuplicateArcanaAndMissingSeleneHex()
    local duplicate = json.decode('{"weaponKey":"WeaponStaffSwing","aspectKey":"BaseStaffAspect","arcana":[{"key":"CardDraw","origin":"manual","rarity":"Common"},{"key":"CardDraw","origin":"manual","rarity":"Common"}],"fear":{"configuredRanks":{},"effectiveRanks":{}}}')
    local value, errorMessage = loadoutProtocol.decode(duplicate)
    lu.assertNil(value)
    lu.assertStrContains(errorMessage, "Arcana")
    value, errorMessage = loadoutProtocol.decode(json.decode('{"weaponKey":"WeaponSuit","aspectKey":"SuitHexAspect","arcana":[],"fear":{"configuredRanks":{},"effectiveRanks":{}}}'))
    lu.assertNil(value)
    lu.assertStrContains(errorMessage, "startingHex")
end

function TestLoadoutV11.testPostInstallMismatchReturnsTheNativeRun()
    local priorGame, priorRun, priorWeapon, priorRarity, priorCards = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.TraitRarityData, _G.MetaUpgradeCardData
    _G.GameState = { LastWeaponUpgradeName = { WeaponStaffSwing = "BaseStaffAspect" }, LastAwardTrait = "ManaOverTimeRefundKeepsake", ShrineUpgrades = { BossDifficultyShrineUpgrade = 1 }, MetaUpgradeState = { CardDraw = { Equipped = true, Level = 2 } } }
    _G.CurrentRun = { Hero = { TraitDictionary = { BaseStaffAspect = true } } }
    _G.GetEquippedWeapon, _G.TraitRarityData, _G.MetaUpgradeCardData = function() return "WeaponStaffSwing" end, { RarityUpgradeOrder = { "Common", "Rare", "Epic" } }, { CardDraw = {} }
    local state = { plan = expected(nil), initialized = false, state = "inactive" }
    state.plan.startingLoadout.arcana = { { key = "CardDraw", origin = "manual", rarity = "Rare" } }
    state.plan.startingLoadout.fear = { configuredRanks = { BossDifficultyShrineUpgrade = 1 }, effectiveRanks = { BossDifficultyShrineUpgrade = 1 } }
    local callbacks, started = captureLoadoutHooks(state), false
    local result = callbacks.StartNewRun(nil, {}, function()
        _G.GameState.MetaUpgradeState.Extra = { Equipped = true, Level = 1 }
        callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
        callbacks.EquipKeepsake(nil, {}, function() return true end, {}, "ManaOverTimeRefundKeepsake", {})
        started = true
        return { partial = true }
    end, nil, {})
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.TraitRarityData, _G.MetaUpgradeCardData = priorGame, priorRun, priorWeapon, priorRarity, priorCards
    lu.assertTrue(started)
    lu.assertNotNil(result)
    lu.assertEquals(state.firstMismatch.checkpoint, "starting-arcana")
end

local function startState(keepsake, results, hex)
    local value = { plan = expected(hex), initialized = false, state = "inactive" }
    value.plan.startingLoadout.arcana, value.plan.startingLoadout.fear = {}, { configuredRanks = {}, effectiveRanks = {} }
    value.plan.startingKeepsake = { keepsakeKey = keepsake, equipResults = results }
    return value
end

function TestLoadoutV11.testWrongStartingKeepsakeIsAdjudicatedAfterNativeStartup()
    local priorGame, priorRun, priorWeapon = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon
    _G.GameState = {
        LastWeaponUpgradeName = { WeaponStaffSwing = "BaseStaffAspect" },
        LastAwardTrait = "WrongKeepsake", ShrineUpgrades = {}, MetaUpgradeState = {},
    }
    _G.GetEquippedWeapon = function() return "WeaponStaffSwing" end
    _G.CurrentRun = { Hero = { TraitDictionary = { BaseStaffAspect = true } } }
    local state, callbacks = startState("ManaOverTimeRefundKeepsake"), nil
    callbacks = captureLoadoutHooks(state)
    local stateDuringStartup
    local result = callbacks.StartNewRun(nil, {}, function()
        callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
        callbacks.EquipKeepsake(nil, {}, function() return true end, {}, "WrongKeepsake", {})
        stateDuringStartup = state.state
        return { started = true }
    end, nil, {})
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon = priorGame, priorRun, priorWeapon
    lu.assertEquals(result, { started = true })
    lu.assertEquals(stateDuringStartup, "starting")
    lu.assertEquals(state.firstMismatch.checkpoint, "starting-keepsake")
end

function TestLoadoutV11.testNativeStartErrorClearsTheBoundedStartupScope()
    local priorGame, priorRun, priorWeapon = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon
    _G.GameState = {
        LastWeaponUpgradeName = { WeaponStaffSwing = "BaseStaffAspect" },
        LastAwardTrait = "ManaOverTimeRefundKeepsake", ShrineUpgrades = {}, MetaUpgradeState = {},
    }
    _G.CurrentRun = { Hero = { TraitDictionary = { BaseStaffAspect = true } } }
    _G.GetEquippedWeapon = function() return "WeaponStaffSwing" end
    local state = startState("ManaOverTimeRefundKeepsake")
    local callbacks = captureLoadoutHooks(state)
    local ok = pcall(function()
        callbacks.StartNewRun(nil, {}, function()
            callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
            error("native-start-failed")
        end, nil, {})
    end)
    local delegated = false
    callbacks.CreateNewHero(nil, {}, function() delegated = true; return {} end, nil, {})
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon = priorGame, priorRun, priorWeapon
    lu.assertFalse(ok)
    lu.assertTrue(delegated)
end

function TestLoadoutV11.testAttachedKeepsakeContactsRecordHammerAndEmbryoResults()
    local priorGame, priorRun, priorWeapon = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon
    for _, case in ipairs({
        { key = "TempHammerKeepsake", result = { experimentalHammer = { kind = "selected", traitKey = "HammerTrait" } }, contact = "GiveDurationHammer", nested = "AddRandomHammer", value = { Name = "HammerTrait" } },
        { key = "TempHammerKeepsake", result = { experimentalHammer = { kind = "exhausted" } }, contact = "GiveDurationHammer", nested = "AddRandomHammer", value = nil },
        { key = "RandomBlessingKeepsake", result = { transcendentEmbryo = { blessingKey = "ChaosWeaponBlessing", blessingValues = { damageBonus = 0.35 } } }, contact = "ChaosBlessingBonus", nested = "AddRandomChaosBlessing", value = { Name = "ChaosWeaponBlessing", AddOutgoingDamageModifiers = { ValidWeaponMultiplier = 1.35 } }, processed = true },
        { key = "RandomBlessingKeepsake", result = { transcendentEmbryo = { blessingKey = "ChaosExSpeedBlessing", blessingValues = { propertySpeed = 0.72, weaponSpeed = 0.83 } } }, contact = "ChaosBlessingBonus", nested = "AddRandomChaosBlessing", value = { Name = "ChaosExSpeedBlessing", PropertyChanges = { {} }, WeaponSpeedMultiplier = {} }, processed = true, processedData = { Name = "ChaosExSpeedBlessing", PropertyChanges = { { ChangeValue = 0.91 } }, WeaponSpeedMultiplier = { Value = 0.97 } }, processedExpect = { propertySpeed = 0.72, weaponSpeed = 0.83 } },
    }) do
        _G.GameState = { LastWeaponUpgradeName = { WeaponStaffSwing = "BaseStaffAspect" }, LastAwardTrait = case.key, ShrineUpgrades = {}, MetaUpgradeState = {} }
        _G.CurrentRun = { Hero = { TraitDictionary = { BaseStaffAspect = true } } }
        _G.GetEquippedWeapon = function() return "WeaponStaffSwing" end
        local state, callbacks, processedResult = startState(case.key, case.result), nil, nil
        callbacks = captureLoadoutHooks(state)
        local result = callbacks.StartNewRun(nil, {}, function()
            callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
            callbacks.EquipKeepsake(nil, {}, function()
                callbacks[case.contact](nil, {}, function()
                    return callbacks[case.nested](nil, {}, function()
                        if case.value == nil then return nil end
                        local selected = callbacks.GetRandomArrayValue(nil, {}, function(values) return values[1] end,
                            { { Name = "Wrong" }, case.value })
                        if not case.processed then return selected end
                        processedResult = callbacks.GetProcessedTraitData(nil, {}, function()
                            if case.processedData ~= nil then return case.processedData end
                            return {
                                Name = selected.Name,
                                AddOutgoingDamageModifiers = { ValidWeaponMultiplier = 1.1 },
                            }
                        end, { TraitName = selected.Name })
                        return processedResult
                    end)
                end)
            end, {}, case.key, {})
            return { started = true }
        end, nil, {})
        lu.assertNotNil(result)
        lu.assertEquals(state.state, "synchronized")
        if case.processedExpect ~= nil then
            lu.assertEquals(processedResult.PropertyChanges[1].ChangeValue, case.processedExpect.propertySpeed)
            lu.assertEquals(processedResult.WeaponSpeedMultiplier.Value, case.processedExpect.weaponSpeed)
        end
    end
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon = priorGame, priorRun, priorWeapon
end

function TestLoadoutV11.testAttachedJeweledPomSelectsFallbackAndDelegatesWhenNeitherIsEligible()
    local priorGame, priorRun, priorWeapon, priorTraits, priorEligible = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.TraitData, _G.IsTraitEligible
    local function run(preferredEligible, fallbackEligible)
        _G.GameState = { LastWeaponUpgradeName = { WeaponStaffSwing = "BaseStaffAspect" }, LastAwardTrait = "HadesAndPersephoneKeepsake", ShrineUpgrades = {}, MetaUpgradeState = {} }
        _G.CurrentRun = { Hero = { TraitDictionary = { BaseStaffAspect = true }, Traits = { { Name = "Preferred", Rarity = "Rare" }, { Name = "Fallback", Rarity = "Rare" } } } }
        _G.GetEquippedWeapon = function() return "WeaponStaffSwing" end
        _G.TraitData = { Preferred = { Name = "Preferred" }, Fallback = { Name = "Fallback" } }
        _G.IsTraitEligible = function(data) return data.Name == "Preferred" and preferredEligible or data.Name == "Fallback" and fallbackEligible end
        local row = { traitKey = "Preferred", rarity = "Rare", runtimeFallbacks = { { preferredKey = "Preferred", fallbackKey = "Fallback" } } }
        local state, callbacks = startState("HadesAndPersephoneKeepsake", { jeweledPom = row }), nil
        callbacks = captureLoadoutHooks(state)
        local selected, nativeRandom = nil, false
        callbacks.StartNewRun(nil, {}, function()
            callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
            callbacks.EquipKeepsake(nil, {}, function()
                callbacks.GiveRandomHadesBoonAndBoostBoons(nil, {}, function()
                    selected = callbacks.GetRandomArrayValue(nil, {}, function() nativeRandom = true; return { Name = "Native" } end, { _G.TraitData.Preferred, _G.TraitData.Fallback })
                end)
            end, {}, "HadesAndPersephoneKeepsake", {})
            return true
        end, nil, {})
        return state, selected, nativeRandom
    end
    local state, selected, nativeRandom = run(true, true)
    lu.assertEquals(selected.Name, "Preferred")
    lu.assertFalse(nativeRandom)
    lu.assertEquals(state.state, "synchronized")
    state, selected, nativeRandom = run(false, true)
    lu.assertEquals(selected.Name, "Fallback")
    lu.assertFalse(nativeRandom)
    lu.assertEquals(state.state, "synchronized")
    state, selected, nativeRandom = run(false, false)
    lu.assertEquals(selected.Name, "Native")
    lu.assertTrue(nativeRandom)
    lu.assertEquals(state.state, "mismatch")
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.TraitData, _G.IsTraitEligible = priorGame, priorRun, priorWeapon, priorTraits, priorEligible
end

function TestLoadoutV11.testAttachedSeleneTreeForcesOnlySpecialPools()
    local priorGame, priorRun, priorWeapon, priorSpell, priorTrait = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.SpellData, _G.TraitData
    _G.GameState = { LastWeaponUpgradeName = { WeaponSuit = "SuitHexAspect" }, LastAwardTrait = "ManaOverTimeRefundKeepsake", ShrineUpgrades = {}, MetaUpgradeState = {} }
    _G.GetEquippedWeapon = function() return "WeaponSuit" end
    _G.SpellData = { MoonBeam = { Talents = { Unique = { "RareExpected", "RareOther" }, Legendary = { "EpicExpected", "DuoExpected" } } } }
    _G.TraitData = { EpicExpected = {}, DuoExpected = { IsDuoBoon = true } }
    _G.CurrentRun = { Hero = { TraitDictionary = { SuitHexAspect = true, SpellMoonBeamTrait = true } } }
    local hex = { spellTraitKey = "SpellMoonBeamTrait", layoutKey = "ExpectedLayout", rareTalentKeys = { "RareExpected" }, epicTalentKeys = { "EpicExpected" }, godSent = { olympianTalentKey = "DuoExpected", lineageTalentKey = "OlympianSpellCountTalent" } }
    local state, callbacks = startState("ManaOverTimeRefundKeepsake", nil, hex), nil
    state.plan.startingLoadout.weaponKey, state.plan.startingLoadout.aspectKey = "WeaponSuit", "SuitHexAspect"
    callbacks = captureLoadoutHooks(state)
    local result = callbacks.StartNewRun(nil, {}, function()
        callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
        callbacks.EquipKeepsake(nil, {}, function() end, {}, "ManaOverTimeRefundKeepsake", {})
        local tree = callbacks.CreateTalentTree(nil, {}, function()
            local layout = callbacks.GetRandomValue(nil, {}, function(values) return values[1] end, { { Name = "OtherLayout" }, { Name = "ExpectedLayout" } })
            local rare = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end, { "RareOther", "RareExpected" })
            local epic = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end, { "EpicExpected" })
            local duo = callbacks.RemoveRandomValue(nil, {}, function(values) return table.remove(values, 1) end, { "DuoExpected" })
            return { Name = layout.Name, { { Name = rare, Rarity = "Rare" }, { Name = epic, Rarity = "Epic" }, { Name = duo }, { Name = "OlympianSpellCountTalent" }, { Name = "RepeatRare", Rarity = "Rare" } } }
        end, _G.SpellData.MoonBeam)
        _G.CurrentRun.Hero.SlottedSpell = { Name = "MoonBeam", Talents = tree }
        return true
    end, nil, {})
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.SpellData, _G.TraitData = priorGame, priorRun, priorWeapon, priorSpell, priorTrait
    lu.assertTrue(result)
    lu.assertEquals(state.state, "synchronized")
end

function TestLoadoutV11.testAttachedSeleneRejectsUnexpectedGodSentPair()
    local priorGame, priorRun, priorWeapon, priorSpell, priorTrait = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.SpellData, _G.TraitData
    _G.GameState = { LastWeaponUpgradeName = { WeaponSuit = "SuitHexAspect" }, LastAwardTrait = "ManaOverTimeRefundKeepsake", ShrineUpgrades = {}, MetaUpgradeState = {} }
    _G.GetEquippedWeapon = function() return "WeaponSuit" end
    _G.SpellData = { MoonBeam = { Talents = { Unique = { "RareExpected" }, Legendary = { "EpicExpected", "UnexpectedDuo" } } } }
    _G.TraitData = { EpicExpected = {}, UnexpectedDuo = { IsDuoBoon = true } }
    _G.CurrentRun = { Hero = { TraitDictionary = { SuitHexAspect = true, SpellMoonBeamTrait = true } } }
    local hex = { spellTraitKey = "SpellMoonBeamTrait", layoutKey = "ExpectedLayout", rareTalentKeys = { "RareExpected" }, epicTalentKeys = { "EpicExpected" } }
    local state, callbacks = startState("ManaOverTimeRefundKeepsake", nil, hex), nil
    state.plan.startingLoadout.weaponKey, state.plan.startingLoadout.aspectKey = "WeaponSuit", "SuitHexAspect"
    callbacks = captureLoadoutHooks(state)
    local result = callbacks.StartNewRun(nil, {}, function()
        callbacks.CreateNewHero(nil, {}, function() return {} end, nil, {})
        callbacks.EquipKeepsake(nil, {}, function() end, {}, "ManaOverTimeRefundKeepsake", {})
        local tree = callbacks.CreateTalentTree(nil, {}, function()
            return { Name = "ExpectedLayout", { { Name = "RareExpected" }, { Name = "EpicExpected" }, { Name = "UnexpectedDuo" }, { Name = "OlympianSpellCountTalent" } } }
        end, _G.SpellData.MoonBeam)
        _G.CurrentRun.Hero.SlottedSpell = { Name = "MoonBeam", Talents = tree }
        return true
    end, nil, {})
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.SpellData, _G.TraitData = priorGame, priorRun, priorWeapon, priorSpell, priorTrait
    lu.assertNotNil(result)
    lu.assertEquals(state.firstMismatch.checkpoint, "starting-hex-god-sent")
end

function TestLoadoutV11.testReadsEquippedArcanaLevelAndSkipsTreeNameScalar()
    local priorGame, priorRarity, priorRun, priorCards = _G.GameState, _G.TraitRarityData, _G.CurrentRun, _G.MetaUpgradeCardData
    _G.GameState = { MetaUpgradeState = { CardDraw = { Equipped = true, Level = 2 } } }
    _G.TraitRarityData = { RarityUpgradeOrder = { "Common", "Rare", "Epic" } }
    _G.CurrentRun = { Hero = { SlottedSpell = { Talents = { Name = "Lung", { { Name = "RareA" } } } } } }
    _G.MetaUpgradeCardData = { CardDraw = {} }
    lu.assertEquals(native.activeArcana(), { { key = "CardDraw", origin = "manual", rarity = "Rare" } })
    lu.assertEquals(native.treeTalentKeys(), { "RareA" })
    lu.assertEquals(native.treeLayoutKey(), "Lung")
    _G.GameState, _G.TraitRarityData, _G.CurrentRun, _G.MetaUpgradeCardData = priorGame, priorRarity, priorRun, priorCards
end

function TestLoadoutV11.testReadsExactManualAndAutomaticArcanaOrigins()
    local priorGame, priorCards, priorRarity = _G.GameState, _G.MetaUpgradeCardData, _G.TraitRarityData
    _G.GameState = { MetaUpgradeState = {
        Manual = { Equipped = true, Level = 1 }, Automatic = { Equipped = true, Level = 3 }, Inactive = { Equipped = false, Level = 3 },
    } }
    _G.MetaUpgradeCardData = { Manual = {}, Automatic = { AutoEquipRequirements = { { Path = { "x" } } } }, Inactive = {} }
    _G.TraitRarityData = { RarityUpgradeOrder = { "Common", "Rare", "Epic" } }
    local observed = {}
    for _, row in ipairs(native.activeArcana()) do observed[row.key] = row end
    lu.assertEquals(observed.Manual, { key = "Manual", origin = "manual", rarity = "Common" })
    lu.assertEquals(observed.Automatic, { key = "Automatic", origin = "automatic", rarity = "Epic" })
    _G.GameState, _G.MetaUpgradeCardData, _G.TraitRarityData = priorGame, priorCards, priorRarity
end

function TestLoadoutV11.testSpecialTreeReaderIgnoresOrdinaryRareRepeatableNode()
    local priorRun, priorSpell, priorTrait = _G.CurrentRun, _G.SpellData, _G.TraitData
    _G.CurrentRun = { Hero = { SlottedSpell = { Name = "MoonBeam", Talents = { Name = "Lung", {
        { Name = "RareA", Rarity = "Rare" }, { Name = "EpicA", Rarity = "Epic" }, { Name = "RepeatRare", Rarity = "Rare" },
    } } } } }
    _G.SpellData = { MoonBeam = { Talents = { Unique = { "RareA" }, Legendary = { "EpicA" } } } }
    _G.TraitData = { EpicA = {} }
    lu.assertEquals(native.treeSpecialTalentKeys(), { rare = { "RareA" }, epic = { "EpicA" }, godSent = {} })
    _G.CurrentRun, _G.SpellData, _G.TraitData = priorRun, priorSpell, priorTrait
end

function TestLoadoutV11.testVerifiesExactLoadoutAndModeledSeleneTree()
    local priorGame, priorRun, priorWeapon, priorShrine, priorCards, priorSpell, priorTrait, priorRarity = _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.GetNumShrineUpgrades, _G.MetaUpgradeCardData, _G.SpellData, _G.TraitData, _G.TraitRarityData
    _G.GameState = {
        LastWeaponUpgradeName = { WeaponStaffSwing = "BaseStaffAspect" },
        LastAwardTrait = "ManaOverTimeRefundKeepsake", ShrineUpgrades = { EnemyHealthShrineUpgrade = 1 },
        MetaUpgradeState = { CardDraw = { Equipped = true, Level = 3 } },
    }
    _G.MetaUpgradeCardData = { CardDraw = {} }
    _G.TraitRarityData = { RarityUpgradeOrder = { "Common", "Rare", "Epic" } }
    _G.SpellData = { MoonBeam = { Talents = { Unique = { "RareA" }, Legendary = { "EpicA" } } } }
    _G.TraitData = { EpicA = {} }
    _G.CurrentRun = { Hero = { TraitDictionary = { BaseStaffAspect = true, SpellMoonBeamTrait = true }, SlottedSpell = { Name = "MoonBeam",
        Talents = { Name = "Lung", { { Name = "RareA" }, { Name = "EpicA" } } },
    } } }
    _G.GetEquippedWeapon = function() return "WeaponStaffSwing" end
    _G.GetNumShrineUpgrades = function() return 1 end
    local state, mismatch = { plan = expected({ spellTraitKey = "SpellMoonBeamTrait", layoutKey = "Lung", rareTalentKeys = { "RareA" }, epicTalentKeys = { "EpicA" } }) }, nil
    local fail = function(_, checkpoint) mismatch = checkpoint; return nil end
    state.initialized, state.state = true, "starting"
    session.beginKeepsake(state, "ManaOverTimeRefundKeepsake")
    local post = session.verifyCompleted(state, fail)
    _G.GameState, _G.CurrentRun, _G.GetEquippedWeapon, _G.GetNumShrineUpgrades, _G.MetaUpgradeCardData, _G.SpellData, _G.TraitData, _G.TraitRarityData = priorGame, priorRun, priorWeapon, priorShrine, priorCards, priorSpell, priorTrait, priorRarity
    lu.assertTrue(post, tostring(mismatch))
    lu.assertNil(mismatch)
end

function TestLoadoutV11.testMissingStartingEquipContactIsAMismatch()
    local state, mismatch = { startingLoadout = {} }, nil
    session.finishKeepsake(state, function(_, checkpoint) mismatch = checkpoint; return nil end)
    lu.assertEquals(mismatch, "starting-keepsake")
end

function TestLoadoutV11.testStartingRoomIsOptimisticallyRealizedDuringLoadout()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local realized, nativeStarted = false, false
    local priorGame = _G.game
    _G.game = { CreateRoom = function(data) return data end }
    local state = { state = "starting" }
    local occurrence = { id = "opening", gameName = "F_Opening01" }
    local route = { expected = function() return occurrence end }
    local roomSession = {
        realize = function(_, value)
            lu.assertEquals(value, occurrence)
            realized = true
            return { Name = "F_Opening01" }
        end,
    }
    roomHooks.attach(module, roomSession, function() return state end, function() end,
        route, roomSession, nil, {
            realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
            proveIncomingReward = function() return true end,
        })
    local result = callbacks.ChooseStartingRoom(nil, {}, function() nativeStarted = true; return { Name = "Native" } end, {}, {})
    lu.assertEquals(result, { Name = "F_Opening01" })
    lu.assertTrue(realized)
    lu.assertFalse(nativeStarted)
    _G.game = priorGame
end
