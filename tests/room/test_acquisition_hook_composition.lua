-- luacheck: globals TestAcquisitionHookComposition
local lu = require("luaunit")
local roomCoordinatorModule = require("mods.room.coordinator")
local encounterHooks = require("mods.room.timeline.encounters.hooks")
local acquisitions = require("mods.room.timeline.acquisitions.hooks")
local seaStar = require("mods.room.timeline.acquisitions.sea_star").create()
local directPickups = require("mods.room.timeline.acquisitions.pickups.hooks")
local chaosAcquisitions = require("mods.room.timeline.acquisitions.traits.chaos_offer")
local traitAcquisitions = require("mods.room.timeline.acquisitions.traits.hooks")
local npcAcquisitions = require("mods.room.timeline.acquisitions.npc.hooks")
local mysteryAcquisitions = require("mods.room.timeline.acquisitions.mystery.hooks")
local support = require("tests.harness.hook_composition")
local nativeGame = require("tests.harness.native_game")
local capture, stub, opaque = support.capture, support.stub, support.opaque
local fakePayload = support.fakePayload

TestAcquisitionHookComposition = {}

function TestAcquisitionHookComposition:setUp()
    self.restoreNative = nativeGame.install({
        TraitData = nativeGame.anyTraitDeclarations(),
        IsTraitEligible = nativeGame.alwaysEligible,
        GetAllUpgradeableGodTraits = nativeGame.currentUpgradeableTraits,
    })
end

function TestAcquisitionHookComposition:tearDown()
    self.restoreNative()
end

function TestAcquisitionHookComposition.testChaosChoiceCompletesItsBoundOwner()
    local module, _, callbacks = capture()
    local completed = {}
    local chaos = {
        transaction = {
            owner = "chaos",
            resolution = {
                kind = "traitOffer",
                offer = {
                    kind = "chaos", blessingKey = "ChaosSpeedBlessing", rarity = "Rare",
                    blessingValues = {}, selectedCurseValues = {}, selected = "option1",
                    curseOptions = {
                        { curseKey = "ChaosNoMoneyCurse", requirementCount = 1 },
                        { curseKey = "ChaosHealthCurse", requirementCount = 2 },
                        { curseKey = "ChaosDamageCurse", requirementCount = 3 },
                    },
                },
            },
        },
    }
    local active = opaque({}, function() return nil end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        completed[#completed + 1] = { row = row }
        return true
    end
    local chaosLoot = {
        Name = "TrialUpgrade",
        UpgradeOptions = {
            { ItemName = "ChaosPeerA", Rarity = "Common" },
            { ItemName = "ChaosPeerB", Rarity = "Common" },
            { ItemName = "ChaosSpeedBlessing", Rarity = "Common" },
        },
    }
    active.bind(chaos, chaosLoot)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    chaosAcquisitions.attach(module, session, function() return {} end, function() end, session)
    callbacks.HandleLootPickup(nil, {}, function()
        local selectedButton
        callbacks.CreateBoonLootButtons(nil, {}, function()
            for index, itemData in ipairs(chaosLoot.UpgradeOptions) do
                local button = callbacks.CreateUpgradeChoiceButton(nil, {}, function(_, _, _, item)
                    return {
                        Data = {
                            Name = item.SecondaryItemName, RemainingUses = ({ 1, 2, 3 })[index],
                            OnExpire = { TraitData = { Name = item.ItemName, Rarity = item.Rarity } },
                        }, LootData = chaosLoot,
                    }
                end, nil, chaosLoot, index, itemData, {})
                selectedButton = index == 1 and button or selectedButton
            end
        end, nil, chaosLoot, false, {})
        _G.CurrentRun.Hero.Traits = { {
            Name = "ChaosNoMoneyCurse", RemainingUses = 1,
            OnExpire = { TraitData = { Name = "ChaosSpeedBlessing", Rarity = "Rare" } },
        } }
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
            nil, selectedButton, {})
    end, {}, chaosLoot, {})
    _G.CurrentRun = priorRun
    lu.assertEquals(fakePayload(completed[1].row).transaction.owner, "chaos")
end

function TestAcquisitionHookComposition.testMysteryBoonBindsItsUnwrappedSourceTraitOffer()
    local module, _, callbacks = capture()
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    local node = {
        owner = "mystery-boon",
        kind = "acquisition",
        window = { kind = "standard", phase = "beforeCombat" },
        roles = {
            {
                role = "box", lifecyclePoint = "roomRewardPickup", kind = "consumable",
                disposition = "normal", gameName = "BlindBoxLoot",
            },
            {
                role = "hiddenSource", lifecyclePoint = "afterUnwrap", kind = "trait",
                disposition = "normal", gameName = "HeraUpgrade",
                traitOffer = {
                    kind = "traits", giver = "Hera", selected = "option1",
                    options = {
                        { key = "HeraCastBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraSprintBoon", rarity = "Common", effectiveLevel = 4 },
                        { key = "HeraManaBoon", rarity = "Common", effectiveLevel = 4 },
                    },
                },
            },
        },
    }
    local occurrence = {
        id = "mystery-room", overview = {}, transactionsByOwner = { [node.owner] = node },
        timeline = { transactions = { node }, dependencies = {}, obligations = {} },
    }
    local plan = { occurrencesById = { [occurrence.id] = occurrence } }
    local mismatches = {}
    local room = roomCoordinatorModule.new(plan, function(errorValue, expected, observed)
        mismatches[#mismatches + 1] = { error = errorValue, expected = expected, observed = observed }
    end)
    local state = { state = "synchronized", plan = plan, room = room }
    local active = assert(roomCoordinatorModule.enter(state, occurrence))
    local box = { Name = "BlindBoxLoot" }
    local loot = { Name = "HeraUpgrade", GodLoot = true }
    local completions = {}
    local session = {
        current = roomCoordinatorModule.current,
        peek = roomCoordinatorModule.peek,
        bind = roomCoordinatorModule.bind,
        bound = roomCoordinatorModule.bound,
        begin = roomCoordinatorModule.begin,
        resolve = roomCoordinatorModule.resolve,
        claimReady = roomCoordinatorModule.claimReady,
        mismatch = function() end,
    }
    session.complete = function(runtimeState, handle)
        completions[#completions + 1] = { handle = handle }
        return roomCoordinatorModule.complete(runtimeState, handle)
    end
    mysteryAcquisitions.attach(module, session, function() return state end, function() end, roomCoordinatorModule)
    local mysteryCallbacks = {
        CreateLoot = callbacks.CreateLoot,
        UseConsumableItem = callbacks.UseConsumableItem,
        ConsumableUsedPresentation = callbacks.ConsumableUsedPresentation,
        UnwrapRandomLoot = callbacks.UnwrapRandomLoot,
        GiveLoot = callbacks.GiveLoot,
    }
    for name, callback in pairs(mysteryCallbacks) do callbacks[name] = callback end
    traitAcquisitions.attach(module, session, function() return state end,
        function() end, roomCoordinatorModule, seaStar)

    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        lu.assertTrue(callbacks.ConsumableUsedPresentation(nil, {}, function() return true end,
            _G.CurrentRun, nativeItem, {}))
        callbacks.UnwrapRandomLoot(nil, {}, function()
            callbacks.GiveLoot(nil, {}, function(args)
                lu.assertEquals(args.ForceLootName, "HeraUpgrade")
                return callbacks.CreateLoot(nil, {}, function() return loot end, { Name = args.ForceLootName })
            end, {})
        end, nativeItem)
    end, box, {}, {})
    lu.assertEquals(#completions, 0)
    local boxHandle = roomCoordinatorModule.bound(state, active, box)
    lu.assertNotNil(boxHandle)
    lu.assertEquals(roomCoordinatorModule.peek(state, boxHandle).detail, node.roles[2])
    lu.assertTrue(rawequal(roomCoordinatorModule.bound(state, active, loot), boxHandle))
    callbacks.HandleLootPickup(nil, {}, function(_, nativeLoot)
        return callbacks.CreateBoonLootButtons(nil, {}, function()
            lu.assertEquals(nativeLoot.UpgradeOptions, {
                { Type = "Trait", ItemName = "HeraCastBoon", Rarity = "Common", StackNum = 4 },
                { Type = "Trait", ItemName = "HeraSprintBoon", Rarity = "Common", StackNum = 4 },
                { Type = "Trait", ItemName = "HeraManaBoon", Rarity = "Common", StackNum = 4 },
            })
        end, {}, nativeLoot, false, {})
    end, _G.CurrentRun, loot, {})
    lu.assertEquals(#completions, 0)
    _G.CurrentRun.Hero.Traits = { { Name = "HeraCastBoon", Rarity = "Common", StackNum = 4 } }
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
        {}, { LootData = loot, Data = { Name = "HeraCastBoon" } }, {})
    lu.assertEquals(#completions, 1)
    lu.assertEquals(mismatches, {})
    _G.CurrentRun = priorRun
end

function TestAcquisitionHookComposition.testEachNativeNpcChoiceFunctionBindsItsPublishedTraitOffer()
    local contacts = {
        ArachneCostumeChoice = "Arachne",
        NarcissusBenefitChoice = "Narcissus",
        MedeaCurseChoice = "Medea",
        CirceBlessingChoice = "Circe",
        IcarusBenefitChoice = "Icarus",
        EchoChoice = "Echo",
    }
    local priorEligibility = _G.IsGameStateEligible
    _G.IsGameStateEligible = function() return true end
    for functionName, giver in pairs(contacts) do
        local module, _, callbacks = capture()
        local state = {}
        local selected = giver .. "Selected"
        local source = { Name = giver }
        local node = {
            owner = giver .. "-offer", kind = "encounterInteraction",
            resolution = {
                kind = "traitOffer",
                offer = {
                    kind = "traits", giver = giver, selected = "option2",
                    options = {
                        { key = giver .. "First" }, { key = selected }, { key = giver .. "Third" },
                    },
                },
            },
        }
        local row = { transaction = node }
        local active = opaque({
            occurrence = { overview = { encounterPhases = {
                { slotKey = "Encounter", encounterKey = giver .. "Encounter" },
            } } },
        }, function(contact)
            if contact.kind == "encounterInteraction" and contact.phaseKey == "Encounter" then return row end
        end)
        local completed
        local session = stub()
        session.current = function() return active end
        session.encounterHandle = function()
            return active.resolve({ kind = "encounterInteraction", phaseKey = "Encounter" })
        end
        session.complete = function(_, actualRow)
            completed = { row = actualRow }
            return true
        end
        npcAcquisitions.attach(module, session, function() return state end, function() end, session)
        local priorRun = _G.CurrentRun
        _G.CurrentRun = {
            CurrentRoom = { Encounter = { Name = giver .. "Encounter" } },
            Hero = { Traits = {} },
        }
        local args = { UpgradeOptions = {
            { ItemName = giver .. "Third", Marker = 3 },
            { ItemName = giver .. "First", Marker = 1, GameStateRequirements = { "ignored" } },
            { ItemName = selected, Marker = 2, PriorityRequirements = { "ignored" } },
        } }
        callbacks[functionName](nil, {}, function(nativeSource, prepared)
            local function select()
                _G.CurrentRun.Hero.Traits = { { Name = selected } }
                callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
                    { Source = source }, { Data = { Name = selected } }, {})
                return true
            end
            lu.assertEquals(prepared.UpgradeOptions, {
                { ItemName = giver .. "First", Marker = 1, GameStateRequirements = { "ignored" } },
                { ItemName = selected, Marker = 2, PriorityRequirements = { "ignored" } },
                { ItemName = giver .. "Third", Marker = 3 },
            })
            nativeSource.UpgradeOptions = prepared.UpgradeOptions
            return callbacks.OpenUpgradeChoiceMenu(nil, {}, function(nativeNpc)
                lu.assertEquals(nativeNpc.UpgradeOptions, {
                    { ItemName = giver .. "First", Marker = 1, GameStateRequirements = { "ignored" } },
                    { ItemName = selected, Marker = 2, PriorityRequirements = { "ignored" } },
                    { ItemName = giver .. "Third", Marker = 3 },
                })
                return select()
            end, nativeSource, prepared)
        end, source, args, { Source = source })
        _G.CurrentRun = priorRun
        lu.assertEquals(fakePayload(completed.row), row, functionName)
    end
    _G.IsGameStateEligible = priorEligibility
end

function TestAcquisitionHookComposition.testIncidentalConsumableDoesNotClaimTheIncomingRewardTransaction()
    local module, _, callbacks = capture()
    local completed = {}
    local node = {
        owner = "hammer",
        producerLifecycleKey = "RoomReward",
        reward = { rewardType = "WeaponUpgrade" },
        roles = {
            { role = "self", lifecyclePoint = "roomRewardPickup", gameName = "WeaponUpgrade" },
        },
    }
    local active = opaque({
        occurrence = {
            overview = {
                incomingReward = { producerLifecycleKey = "RoomReward", rewardType = "WeaponUpgrade" },
            },
        },
    }, function(contact)
        if contact.kind == "producer" and contact.producerLifecycleKey == "RoomReward"
            and contact.rewardType == "WeaponUpgrade" then return { transaction = node } end
    end)
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, row)
        completed[#completed + 1] = { row = row }
    end
    directPickups.attach(module, session, function() return {} end, function() end, session, seaStar)

    local consolation = { Name = "RoomRewardConsolationPrize" }
    callbacks.UseConsumableItem(nil, {}, function() return true end, consolation, {}, {})
    callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, consolation, {})

    lu.assertEquals(completed, {})
    lu.assertNil(active.bindingFor(consolation))
end

function TestAcquisitionHookComposition.testBossWindowUsesTheRoomCoordinator()
    local module, _, callbacks = capture()
    local state = { state = "synchronized" }
    local active = {
        occurrence = {
            overview = {
                encounterPhases = { { slotKey = "Encounter", encounterKey = "Boss" } },
            },
        },
    }
    local opened
    local roomCoordinator = {
        current = function() return active end,
        window = function(_, value) opened = value; return true end,
        encounterPhase = function() return active.occurrence.overview.encounterPhases[1] end,
    }

    encounterHooks.attach(module, {}, function() return state end, function() end, roomCoordinator)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { CurrentRoom = { Encounter = {} } }
    local result = callbacks.Kill(nil, {}, function() return "native-result" end, { IsBoss = true }, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(result, "native-result")
    lu.assertEquals(opened, "bossDefeated:Encounter")
end

function TestAcquisitionHookComposition.testDirectConsumableLevelResolutionForcesAndCompletesThePublishedTarget()
    local module, _, callbacks = capture()
    local target = { Name = "ZeusWeaponBoon", StackNum = 2 }
    local other = { Name = "ApolloSpecialBoon", StackNum = 4 }
    local row = {
        transaction = {
            owner = "room-nectar", kind = "acquisition", producerLifecycleKey = "RoomReward",
            reward = { rewardType = "GiftDrop" }, roles = {},
        },
        detail = {
            gameName = "GiftDrop", disposition = "normal",
            levelResolution = {
                offeredTargets = {}, selectedTarget = target.Name, levelCount = 1,
            },
        },
    }
    row.transaction.roles = { row.detail }
    local item = {
        Name = "GiftDrop",
        UseFunctionArgs = { Thread = true, NumTraits = 1, NumStacks = 9 },
    }
    local active = opaque({
        occurrence = { overview = {} },
    }, function(contact)
        if contact.kind == "offer" and contact.offerKey == "Minor" then return row end
        if contact.kind == "materialized" and contact.source and contact.source.transaction == row.transaction
            and contact.gameName == item.Name then return row end
    end, { [item] = row })
    local completions = {}
    local session = stub()
    session.current = function() return active end
    session.complete = function(_, completedRow)
        completions[#completions + 1] = { row = completedRow }
    end
    acquisitions.attach(module, session, function() return {} end,
        function() end, session, require("mods.spells.hex_tree").create())

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { target, other } } }
    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        local threadedArgs = nativeItem.UseFunctionArgs
        callbacks.UseStoreRewardRandomStack(nil, {}, function(directArgs)
            callbacks.AddStackToTraits(nil, {}, function(firstSource, firstArgs)
                firstArgs = firstArgs or firstSource
                lu.assertEquals(firstArgs.TraitName, target.Name)
                lu.assertEquals(firstArgs.NumStacks, 1)
                local realizedArgs = {}
                for key, value in pairs(firstArgs) do realizedArgs[key] = value end
                realizedArgs.Thread = false
                callbacks.AddStackToTraits(nil, {}, function(terminalSource, terminalArgs)
                    terminalArgs = terminalArgs or terminalSource
                    lu.assertEquals(terminalArgs.TraitName, target.Name)
                    lu.assertEquals(terminalArgs.NumStacks, 1)
                    target.StackNum = target.StackNum + terminalArgs.NumStacks
                end, realizedArgs)
            end, directArgs)
        end, threadedArgs, nativeItem)
    end, item, {}, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(item.UseFunctionArgs, { Thread = true, NumTraits = 1, NumStacks = 9 })
    lu.assertEquals(target.StackNum, 3)
    lu.assertEquals(other.StackNum, 4)
    lu.assertEquals(#completions, 1)
    lu.assertEquals(fakePayload(completions[1].row).transaction, row.transaction)
    lu.assertEquals(fakePayload(completions[1].row).detail, row.detail)
end
