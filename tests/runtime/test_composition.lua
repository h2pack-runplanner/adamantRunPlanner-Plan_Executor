-- luacheck: globals TestRuntimeComposition
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local roomHooks = require("mods.room.hooks")
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local roomFeatureHooks = require("mods.room.features.hooks")
local transformations = require("mods.room.timeline.transformations.hooks")
local acquisitions = require("mods.room.timeline.acquisitions.hooks")
local traitAcquisitions = require("mods.room.timeline.acquisitions.traits.hooks")
local loadoutHooks = require("mods.loadout.hooks")
local support = require("tests.harness.hook_composition")
local capture, stub = support.capture, support.stub
local attachFeatureHooks = support.attachFeatureHooks
local navigationEntryStub = support.navigationEntryStub

TestRuntimeComposition = {}

function TestRuntimeComposition.testExplicitGateBHookGroupsStayInstalled()
    local module, names = capture()
    local session = stub()
    local getState, report = function() end, function() end
    local route = { expected = function() end, reportDestination = function() return true end }
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    loadoutHooks.attach(module, { session = session, loadout = {} }, getState, report, session)
    _G.import = priorImport
    acquisitions.attach(module, session, getState, report, session)
    local transformationScope = transformations.attach(module, session, getState, report, session)
    local featureScope = roomFeatureHooks.attach(module, session, getState, report, session)
    local navigationEntry = navigation.attach(module, session, getState, report, route, session, transformationScope)
    roomHooks.attach(module, session, getState, report, route, session, featureScope, navigationEntry)
    encounterHooks.attach(module, session, getState, report, session)
    attachFeatureHooks(module, session, getState, report, session, route)
    for _, name in ipairs({
        "ChooseStartingRoom", "StartRoom", "DoUnlockRoomExits", "LeaveRoom",
        "StartEncounter", "EndEncounterEffects",
        "UseLoot", "UseConsumableItem", "AddStackToTraits", "HandleLootPickup",
        "ConvertMetaRewardPresentation", "CreateLoot", "UnwrapRandomLoot",
        "ArachneCostumeChoice", "NarcissusBenefitChoice", "MedeaCurseChoice", "CirceBlessingChoice",
        "IcarusBenefitChoice", "EchoChoice", "SpawnNemesisForRandomEvents", "CheckAvailableTextLines",
        "NemesisTradeChoice", "NPCRewardDropPreProcess", "NPCRewardDropPreProcessArgs", "NemesisDamageContestTimer",
        "CirceRandomMetaUpgrade", "AddRandomMetaUpgrades", "CirceMetaUpgradeRarity",
        "CirceRemoveShrineUpgrades", "RandomChance", "GetRandomKey",
        "FillInShopOptions", "CreateStoreButtons", "RestockWorldItem", "CreateConsumableItem",
        "ChaosHammerUpgrade",
        "SpawnStoreItemInWorld", "RemoveStoreItem", "HandleStorePurchase",
    }) do
        lu.assertNotNil(names[name], name)
    end
    lu.assertNil(names.GoldifyPresentation)
    lu.assertNil(names.SetTransformingTraitsOnLoot)
end

function TestRuntimeComposition.testKeepsakeAdaptersAreInstalledOnceAtTheirCarrierBoundaries()
    local module, names = capture()
    local session = stub()
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    loadoutHooks.attach(module, { session = session, loadout = {} }, function() end, function() end, session)
    _G.import = priorImport
    encounterHooks.attach(module, session, function() end, function() end, session)
    traitAcquisitions.attach(module, session, function() end, function() end, session)

    local expected = {
        { "GiveDurationHammer", "run-planner-equip-hammer" },
        { "AddRandomMetaUpgrades", "run-planner-boss-arcana" },
        { "AddRandomChaosBlessing", "run-planner-equip-embryo-result" },
        { "AddRandomChaosBlessing", "run-planner-embryo" },
        { "GetProcessedTraitData", "run-planner-equip-embryo-values" },
        { "GetProcessedTraitData", "run-planner-embryo-values" },
        { "AthenaUse", "run-planner-gorgon-athena-use" },
        { "HandleEncounterPreSpawns", "run-planner-fig-leaf-pre-spawns" },
        { "HandleEnemySpawns", "run-planner-fig-leaf-enemy-spawns" },
        { "HasHeroTraitValue", "run-planner-scope-concave-stone-roll" },
        { "RandomChance", "run-planner-steer-concave-stone-roll" },
    }
    for _, item in ipairs(expected) do
        lu.assertEquals(names[item[1]][item[2]], true, item[1] .. ":" .. item[2])
    end
end

function TestRuntimeComposition.testMismatchStopsEnforcementWithoutBlockingNativeRoomFlow()
    local module, _, callbacks = capture()
    local session = stub()
    local getState = function()
        return { state = "desynchronized" }
    end
    local route = { expected = function() end, reportDestination = function() return true end }
    local featureScope = roomFeatureHooks.attach(module, session, getState, function() end, session)
    local navigationEntry = navigation.attach(module, session, getState, function() end, route, session)
    roomHooks.attach(module, session, getState, function() end,
        route, session, featureScope, navigationEntry)

    local starting = callbacks.ChooseStartingRoom(nil, {}, function()
        return { Name = "NativeOpening" }
    end, {}, {})
    local entered = callbacks.StartRoom(nil, {}, function()
        return "native-entry"
    end, {}, { Name = "NativeOpening" })
    local used = callbacks.UseExitDoor(nil, {}, function(door)
        return door.Name
    end, { Name = "NativeDoor" }, {})
    local left = callbacks.LeaveRoom(nil, {}, function()
        return "native-exit"
    end, {}, {})

    lu.assertEquals(starting, { Name = "NativeOpening" })
    lu.assertEquals(entered, "native-entry")
    lu.assertEquals(used, "NativeDoor")
    lu.assertEquals(left, "native-exit")
end

function TestRuntimeComposition.testRoomAfterConfiguredPrefixHandsControlBackToNativeGame()
    local module, _, callbacks = capture()
    local state = { state = "synchronized", route = {}, room = {} }
    local session = stub()
    local enteredRoom = false
    local route = {
        expected = function() return nil end,
        enter = function() return true end,
    }
    local room = {
        enter = function() enteredRoom = true end,
        realize = function() return nil end,
    }
    roomHooks.attach(module, session, function() return state end, function() end,
        route, room, { currentAdditional = function() return nil end }, navigationEntryStub)

    local result = callbacks.StartRoom(nil, {}, function()
        return "native-entry"
    end, {}, { Name = "H_Opening01" })

    lu.assertEquals(result, "native-entry")
    lu.assertFalse(enteredRoom)
    lu.assertEquals(state.state, "inactive")
    lu.assertEquals(state.reason, "configured-prefix-complete")
end
