-- luacheck: globals TestRuntimeComposition
local lu = require("luaunit")
local navigation = require("mods.navigation.hooks")
local roomHooks = require("mods.room.hooks")
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local roomFeatureHooks = require("mods.room.features.hooks")
local transformations = require("mods.room.timeline.transformations.hooks")
local acquisitions = require("mods.room.timeline.acquisitions.hooks")
local seaStarDefinition = require("mods.room.timeline.acquisitions.sea_star")
local traitAcquisitions = require("mods.room.timeline.acquisitions.traits.hooks")
local hexTreeDefinition = require("mods.spells.hex_tree")
local loadoutHooks = require("mods.loadout.hooks")
local support = require("tests.harness.hook_composition")
local capture, stub = support.capture, support.stub
local attachFeatureHooks = support.attachFeatureHooks
local navigationEntryStub = support.navigationEntryStub
local unusedLoadoutScope = {
    synchronizeStartingRoom = function()
        error("starting-room loadout synchronization is outside this test")
    end,
}
local function shipCombatStub()
    return {
        rewardContext = function() end,
        preparePhases = function() return function() end end,
        attach = function() end,
    }
end

TestRuntimeComposition = {}

function TestRuntimeComposition.testAcquisitionCompositionSharesOneSeaStarAcrossEveryCarrier()
    local priorImport = _G.import
    local module, _, callbacks = capture()
    local carrierActions = {}
    local carrierPaths = {
        ["mods/room/timeline/acquisitions/traits/hooks.lua"] = true,
        ["mods/room/timeline/acquisitions/levels/hooks.lua"] = true,
        ["mods/room/timeline/acquisitions/path/hooks.lua"] = true,
        ["mods/room/timeline/acquisitions/pickups/hooks.lua"] = true,
    }
    local function freshImport(path)
        if path == "mods/room/timeline/acquisitions/sea_star.lua" then
            return assert(loadfile("src/" .. path))()
        end
        if carrierPaths[path] then
            return {
                attach = function(_, _, _, _, _, carrierSeaStar)
                    carrierActions[path] = function()
                        local mismatch
                        local scope = carrierSeaStar.scope({}, {
                            detail = { seaStarResult = { kind = "proc" } },
                        })
                        local result = carrierSeaStar.call(scope, function()
                            local chance = callbacks.GetTotalHeroTraitValue(nil, {}, function() return 0 end,
                                "DoubleRewardChance", {})
                            local proc = callbacks.RandomChance(nil, {}, function() return false end, 0.25, {})
                            return { chance = chance, proc = proc }
                        end, function(_, checkpoint) mismatch = checkpoint end)
                        return result, mismatch
                    end
                    return path:find("traits", 1, true) and {} or nil
                end,
            }
        end
        if path == "mods/room/timeline/acquisitions/hooks.lua" then
            return assert(loadfile("src/" .. path))()
        end
        return { attach = function()
            if path:find("npc/hooks", 1, true) then return {} end
            return nil
        end }
    end
    _G.import = freshImport

    local acquisitionComposition = freshImport("mods/room/timeline/acquisitions/hooks.lua")
    acquisitionComposition.attach(module, {}, function() end, function() end, {}, {})
    for _, path in ipairs({
        "mods/room/timeline/acquisitions/traits/hooks.lua",
        "mods/room/timeline/acquisitions/levels/hooks.lua",
        "mods/room/timeline/acquisitions/path/hooks.lua",
        "mods/room/timeline/acquisitions/pickups/hooks.lua",
    }) do
        local result, mismatch = carrierActions[path]()
        lu.assertEquals(result, { chance = 1, proc = true }, path)
        lu.assertNil(mismatch, path)
    end

    _G.import = priorImport
end

function TestRuntimeComposition.testRuntimeCompositionSharesOneHexTreeAcrossLoadoutAndSpellAcquisition()
    local priorImport = _G.import
    local module, _, callbacks = capture()
    module.cache = { define = function() end }
    local loadoutTree, acquisitionTree
    local function freshImport(path)
        if path == "mods/protocol/json.lua" or path == "mods/protocol/decoder.lua" then
            return { decode = function(value) return value end }
        end
        if path == "mods/host/inbox.lua" then
            return { create = function()
                return {
                    activeSlot = function() return 1 end,
                    select = function() end,
                    load = function() end,
                    status = function() return {} end,
                }
            end }
        end
        if path == "mods/route/session.lua" or path == "mods/room/coordinator.lua"
            or path == "mods/room/conformance/readers.lua" or path == "mods/loadout/session.lua" then
            return {}
        end
        if path == "mods/runtime/session.lua" then
            return {
                defineCache = function() end,
                get = function() end,
                status = function() return { state = "inactive", reason = "test" } end,
            }
        end
        if path == "mods/spells/hex_tree.lua" then return assert(loadfile("src/" .. path))() end
        if path == "mods/room/timeline/encounters/thessaly.lua" then
            return { create = shipCombatStub }
        end
        if path == "mods/loadout/hooks.lua" then
            return { attach = function(_, _, _, _, _, sharedTree)
                loadoutTree = sharedTree
                return {}
            end }
        end
        if path == "mods/room/timeline/acquisitions/hooks.lua" then
            return { attach = function(_, _, _, _, _, sharedTree) acquisitionTree = sharedTree end }
        end
        return { attach = function() return {} end }
    end
    _G.import = freshImport
    local priorRom = _G.rom
    _G.rom = { path = {} }

    local runtime = assert(loadfile("src/mods/runtime/composition.lua"))().bind("/tmp/run-planner-test")
    runtime.attach(module)
    local expected = {
        layoutKey = "ExpectedLayout", rareTalentKeys = {}, epicTalentKeys = {},
    }
    local mismatches = {}
    local function mismatch(checkpoint) mismatches[#mismatches + 1] = checkpoint end
    local startup = loadoutTree.prepare(expected, mismatch)
    callbacks.CreateTalentTree(nil, {}, function() return "startup-tree" end, {})
    loadoutTree.clear(startup)
    local acquired = acquisitionTree.realize(expected, mismatch, function()
        return callbacks.CreateTalentTree(nil, {}, function() return "acquired-tree" end, {})
    end)
    lu.assertEquals(acquired, "acquired-tree")
    lu.assertEquals(mismatches, {})

    _G.import, _G.rom = priorImport, priorRom
end

function TestRuntimeComposition.testCompositionPassesRouteAndRoomAuthoritiesToHooks()
    local priorImport, priorRom = _G.import, _G.rom
    local route, room, conformance = {}, {}, {}
    local attached
    local function freshImport(path)
        if path == "mods/runtime/composition.lua" then
            return assert(loadfile("src/" .. path))()
        end
        if path == "mods/protocol/json.lua" or path == "mods/protocol/decoder.lua" then
            return { decode = function(value) return value end }
        end
        if path == "mods/host/inbox.lua" then
            return { create = function()
                return {
                    activeSlot = function() return 1 end,
                    select = function() end,
                    load = function() end,
                    status = function() return {} end,
                }
            end }
        end
        if path == "mods/route/session.lua" then return route end
        if path == "mods/room/coordinator.lua" then return room end
        if path == "mods/room/conformance/readers.lua" then return conformance end
        if path == "mods/runtime/session.lua" then
            return {
                defineCache = function() end,
                get = function() end,
                status = function() return { state = "inactive", reason = "test" } end,
            }
        end
        if path == "mods/loadout/session.lua" then return {} end
        if path == "mods/spells/hex_tree.lua" then
            return { create = function() return { attach = function() end } end }
        end
        if path == "mods/room/timeline/encounters/thessaly.lua" then
            return { create = shipCombatStub }
        end
        if path == "mods/loadout/hooks.lua" or path == "mods/room/timeline/acquisitions/hooks.lua" then
            return { attach = function() return {} end }
        end
        if path == "mods/room/hooks.lua" then
            return { attach = function(_, sessionValue, _, _, routeValue, roomValue)
                attached = { session = sessionValue, route = routeValue, room = roomValue }
            end }
        end
        return { attach = function() return {} end }
    end
    _G.import = freshImport
    _G.rom = { path = {} }

    local runtime = freshImport("mods/runtime/composition.lua").bind("/tmp/run-planner-test")
    lu.assertEquals(type(runtime.attach), "function")
    lu.assertEquals(type(runtime.inboxInspection.load), "function")
    lu.assertEquals(type(runtime.inboxInspection.status), "function")
    lu.assertEquals(type(runtime.inboxInspection.activeSlot), "function")
    lu.assertEquals(type(runtime.inboxInspection.select), "function")
    runtime.attach({})
    lu.assertTrue(rawequal(attached.route, route))
    lu.assertTrue(rawequal(attached.room, room))

    _G.import, _G.rom = priorImport, priorRom
end

function TestRuntimeComposition.testRuntimeCompositionInstallsSupportedHookGroups()
    local module, names = capture()
    local hexTree = hexTreeDefinition.create()
    local session = stub()
    local getState, report = function() end, function() end
    local route = { expected = function() end, current = function() end }
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    loadoutHooks.attach(module, { inbox = {}, session = session, loadout = {}, activePlanSlot = function() return 1 end },
        getState, report, session, hexTree)
    _G.import = priorImport
    acquisitions.attach(module, session, getState, report, session, hexTree)
    local transformationScope = transformations.attach(module, session, getState, report, session)
    local featureScope = roomFeatureHooks.attach(module, session, getState, report, session)
    local navigationEntry = navigation.attach(module, session, getState, report, route, session, transformationScope)
    roomHooks.attach(module, session, getState, report, route, session, featureScope, navigationEntry,
        unusedLoadoutScope)
    encounterHooks.attach(module, session, getState, report, session)
    attachFeatureHooks(module, session, getState, report, session, route)
    for _, name in ipairs({
        "ChooseStartingRoom", "StartRoom", "DoUnlockRoomExits", "LeaveRoom",
        "StartEncounter", "EndEncounterEffects", "SetupRoomMultipleEncountersData",
        "ShipsEncounterSetup", "ChooseNextRewardStore", "CreateDoorRewardPreview", "UseShipWheel",
        "UseLoot", "UseConsumableItem", "AddStackToTraits", "HandleLootPickup",
        "ConvertMetaRewardPresentation", "CreateLoot", "UnwrapRandomLoot",
        "ArachneCostumeChoice", "NarcissusBenefitChoice", "MedeaCurseChoice", "CirceBlessingChoice",
        "IcarusBenefitChoice", "EchoChoice", "SpawnNemesisForRandomEvents", "CheckAvailableTextLines",
        "NemesisTradeChoice", "NPCRewardDropPreProcess", "NPCRewardDropPreProcessArgs", "NemesisDamageContestTimer",
        "CirceRandomMetaUpgrade", "AddRandomMetaUpgrades", "CirceMetaUpgradeRarity",
        "CirceRemoveShrineUpgrades", "RandomChance", "GetRandomKey",
        "FillInShopOptions", "CreateStoreButtons", "RestockWorldItem", "CreateConsumableItem",
        "ChaosHammerUpgrade",
        "SpawnStoreItemInWorld", "RemoveStoreItem", "HandleStorePurchase", "AwardRandomStoreItem",
    }) do
        lu.assertNotNil(names[name], name)
    end
    lu.assertNil(names.GoldifyPresentation)
    lu.assertNil(names.SetTransformingTraitsOnLoot)
end

function TestRuntimeComposition.testKeepsakeAdaptersAreInstalledOnceAtTheirCarrierBoundaries()
    local module, names = capture()
    local hexTree = hexTreeDefinition.create()
    local seaStar = seaStarDefinition.create()
    local session = stub()
    local priorImport = _G.import
    _G.import = function(path)
        return require((path:gsub("%.lua$", ""):gsub("/", ".")))
    end
    loadoutHooks.attach(module, { inbox = {}, session = session, loadout = {}, activePlanSlot = function() return 1 end },
        function() end, function() end, session, hexTree)
    _G.import = priorImport
    encounterHooks.attach(module, session, function() end, function() end, session)
    traitAcquisitions.attach(module, session, function() end, function() end, session, seaStar)

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
    local route = { expected = function() end, current = function() end }
    local featureScope = roomFeatureHooks.attach(module, session, getState, function() end, session)
    local navigationEntry = navigation.attach(module, session, getState, function() end, route, session)
    roomHooks.attach(module, session, getState, function() end,
        route, session, featureScope, navigationEntry, unusedLoadoutScope)

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
        route, room, { currentAdditional = function() return nil end }, navigationEntryStub,
        unusedLoadoutScope)

    local result = callbacks.StartRoom(nil, {}, function()
        return "native-entry"
    end, {}, { Name = "H_Opening01" })

    lu.assertEquals(result, "native-entry")
    lu.assertFalse(enteredRoom)
    lu.assertEquals(state.state, "inactive")
    lu.assertEquals(state.reason, "configured-prefix-complete")
end
