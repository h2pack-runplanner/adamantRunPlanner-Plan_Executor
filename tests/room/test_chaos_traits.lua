-- Focused witnesses for the TrialUpgrade acquisition boundary.
-- luacheck: globals TestChaosTraits
local lu = require("luaunit")
local chaos = require("mods.room.timeline.acquisitions.traits.chaos")
local binding = require("mods.room.timeline.acquisitions.binding")
local legacyTimeline = require("mods/hooks_timeline")

TestChaosTraits = {}

local function capture()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    return module, callbacks
end

local function offer()
    return {
        kind = "chaos", selected = "option1",
        curseOptions = {
            { curseKey = "ChaosNoMoneyCurse", requirementCount = 1 },
            { curseKey = "ChaosHealthCurse", requirementCount = 2 },
            { curseKey = "ChaosNoMoneyCurse", requirementCount = 3 },
        },
        selectedCurseValues = {}, blessingKey = "ChaosElementalBlessing", rarity = "Rare",
        blessingValues = {},
    }
end

local function harness(loot, authoredOffer)
    local state = { state = "synchronized" }
    local occurrence = { occurrence = {} }
    local handle = {}
    local payload = {
        transaction = { owner = "chaos", kind = "acquisition" },
        detail = { disposition = "normal", gameName = "TrialUpgrade", traitOffer = authoredOffer or offer() },
    }
    local bound = { [loot] = handle }
    local mismatches, completed, begins = {}, {}, 0
    local room = {
        current = function() return occurrence end,
        bound = function(_, _, native) return bound[native] end,
        peek = function(_, value) return value == handle and payload or nil end,
        begin = function(_, value)
            if value ~= handle then return nil end
            begins = begins + 1
            return payload
        end,
        claimReady = function() return nil end,
    }
    local session = {
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = { checkpoint = checkpoint, expected = expected, observed = observed }
        end,
        complete = function(_, value)
            completed[#completed + 1] = { handle = value }
        end,
    }
    local module, callbacks = capture()
    chaos.attach(module, session, function() return state end, function() end, room)
    return callbacks, state, room, payload, mismatches, completed, function() return begins end, session
end

function TestChaosTraits.testInitialRowsAreSteeredAfterNativeSortAndSelectedPairCompletes()
    local loot = {
        Name = "TrialUpgrade",
        UpgradeOptions = {
            { ItemName = "ChaosPeerA", Rarity = "Common" },
            { ItemName = "ChaosPeerB", Rarity = "Common" },
            { ItemName = "ChaosElementalBlessing", Rarity = "Common" },
        },
    }
    local callbacks, state, _, _, mismatches, completed, begins = harness(loot)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    local seen, buttons, screen = {}, {}, {}

    callbacks.HandleLootPickup(nil, {}, function()
        callbacks.CreateBoonLootButtons(nil, {}, function()
            for index, item in ipairs(loot.UpgradeOptions) do
                buttons[index] = callbacks.CreateUpgradeChoiceButton(nil, {}, function(_, _, _, row)
                    local curse = callbacks.GetProcessedTraitData(nil, {}, function(args)
                        return { Name = args.TraitName, Rarity = args.Rarity }
                    end, { TraitName = row.SecondaryItemName, Rarity = row.Rarity })
                    local blessing = callbacks.GetProcessedTraitData(nil, {}, function(args)
                        return { Name = args.TraitName, Rarity = args.Rarity }
                    end, { TraitName = row.ItemName, Rarity = row.Rarity })
                    curse.OnExpire = { TraitData = blessing }
                    seen[index] = {
                        blessing = row.ItemName, curse = row.SecondaryItemName,
                        rarity = row.Rarity, remaining = curse.RemainingUses,
                    }
                    return { Data = curse, LootData = loot }
                end, screen, loot, index, item, {})
            end
        end, screen, loot, false, {})
        _G.CurrentRun.Hero.Traits = { buttons[1].Data }
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
            screen, buttons[1], {})
    end, {}, loot, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(seen, {
        { blessing = "ChaosElementalBlessing", curse = "ChaosNoMoneyCurse", rarity = "Rare", remaining = 1 },
        { blessing = "ChaosPeerB", curse = "ChaosHealthCurse", rarity = "Common", remaining = 2 },
        { blessing = "ChaosPeerA", curse = "ChaosNoMoneyCurse", rarity = "Common", remaining = 3 },
    })
    lu.assertEquals(mismatches, {})
    lu.assertEquals(#completed, 1)
    lu.assertEquals(begins(), 1)
    lu.assertEquals(state.state, "synchronized")
end

function TestChaosTraits.testFailedUseLootDoesNotBeginChaosAcquisition()
    local loot = { Name = "TrialUpgrade" }
    local _, state, room, _, _, _, begins, session = harness(loot)
    local module, callbacks = capture()
    legacyTimeline.attach(module, session, function() return state end, function() end, room)
    local nativeCalled = false
    callbacks.UseLoot(nil, {}, function()
        nativeCalled = true
        return true
    end, loot, {}, {})
    lu.assertTrue(nativeCalled)
    lu.assertEquals(begins(), 0)
end

function TestChaosTraits.testSelectedCurseAndRevelationValuesAreScopedToTheirRows()
    local authored = offer()
    authored.selected = "option2"
    authored.selectedCurseValues = { healthPenalty = -23 }
    authored.blessingKey = "ChaosExSpeedBlessing"
    authored.rarity = "Epic"
    authored.blessingValues = { propertySpeed = 0.72, weaponSpeed = 0.83 }
    local loot = {
        Name = "TrialUpgrade",
        UpgradeOptions = {
            { ItemName = "ChaosExSpeedBlessing", Rarity = "Common" },
            { ItemName = "ChaosPeerB", Rarity = "Common" },
            { ItemName = "ChaosPeerC", Rarity = "Common" },
        },
    }
    local callbacks, _, _, _, mismatches, completed = harness(loot, authored)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    local buttons, screen, seen = {}, {}, {}
    callbacks.HandleLootPickup(nil, {}, function()
        callbacks.CreateBoonLootButtons(nil, {}, function()
            for index, item in ipairs(loot.UpgradeOptions) do
                buttons[index] = callbacks.CreateUpgradeChoiceButton(nil, {}, function(_, _, _, row)
                    local curseArgs = { TraitName = row.SecondaryItemName, Rarity = row.Rarity }
                    local blessingArgs = { TraitName = row.ItemName, Rarity = row.Rarity }
                    local curse = callbacks.GetProcessedTraitData(nil, {}, function(args)
                        local result = { Name = args.TraitName, Rarity = args.Rarity }
                        if args.TraitName == "ChaosHealthCurse" then result.PropertyChanges = { {} } end
                        return result
                    end, curseArgs)
                    local blessing = callbacks.GetProcessedTraitData(nil, {}, function(args)
                        local result = { Name = args.TraitName, Rarity = args.Rarity }
                        if args.TraitName == "ChaosExSpeedBlessing" then
                            result.PropertyChanges = { {} }
                            result.WeaponSpeedMultiplier = {}
                        end
                        return result
                    end, blessingArgs)
                    curse.OnExpire = { TraitData = blessing }
                    seen[index] = {
                        curse = curse.PropertyChanges and curse.PropertyChanges[1].ChangeValue,
                        propertySpeed = blessing.PropertyChanges and blessing.PropertyChanges[1].ChangeValue,
                        weaponSpeed = blessing.WeaponSpeedMultiplier and blessing.WeaponSpeedMultiplier.Value,
                    }
                    return { Data = curse, LootData = loot }
                end, screen, loot, index, item, {})
            end
        end, screen, loot, false, {})
        _G.CurrentRun.Hero.Traits = { buttons[2].Data }
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
            screen, buttons[2], {})
    end, {}, loot, {})
    _G.CurrentRun = priorRun

    lu.assertEquals(seen[2], { curse = -23, propertySpeed = 0.72, weaponSpeed = 0.83 })
    lu.assertNil(seen[1].curse)
    lu.assertNil(seen[1].propertySpeed)
    lu.assertNil(seen[1].weaponSpeed)
    lu.assertNil(seen[3].curse)
    lu.assertEquals(mismatches, {})
end

function TestChaosTraits.testSelectedBlessingIsPlacedAtEveryAuthoredPhysicalPosition()
    for selectedIndex = 1, 3 do
        local authored = offer()
        authored.selected = "option" .. selectedIndex
        local loot = {
            Name = "TrialUpgrade",
            UpgradeOptions = {
                { ItemName = "ChaosPeerA" },
                { ItemName = "ChaosPeerB" },
                { ItemName = "ChaosElementalBlessing" },
            },
        }
        local callbacks = harness(loot, authored)
        callbacks.HandleLootPickup(nil, {}, function()
            callbacks.CreateBoonLootButtons(nil, {}, function()
                for index, item in ipairs(loot.UpgradeOptions) do
                    callbacks.CreateUpgradeChoiceButton(nil, {}, function() return true end,
                        {}, loot, index, item, {})
                end
            end, {}, loot, false, {})
        end, {}, loot, {})
        lu.assertEquals(loot.UpgradeOptions[selectedIndex].ItemName, authored.blessingKey)
    end
end

function TestChaosTraits.testRerollLeavesNativeChaosRowsUntouched()
    local loot = {
        Name = "TrialUpgrade",
        UpgradeOptions = {
            { ItemName = "ChaosPeerA" }, { ItemName = "ChaosPeerB" }, { ItemName = "ChaosElementalBlessing" },
        },
    }
    local callbacks = harness(loot)
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local called = false
    callbacks.CreateBoonLootButtons(nil, {}, function()
        called = true
        return true
    end, {}, loot, true, {})
    lu.assertTrue(called)
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "ChaosPeerA")
    lu.assertEquals(loot.UpgradeOptions[3].ItemName, "ChaosElementalBlessing")
end

function TestChaosTraits.testMissingTransformingRowsMismatchWithoutFabricatingPeers()
    local loot = {
        Name = "TrialUpgrade",
        UpgradeOptions = { { ItemName = "ChaosPeerA" }, { ItemName = "ChaosPeerB" } },
    }
    local callbacks, _, _, _, mismatches = harness(loot)
    local original = {}
    for index, row in ipairs(loot.UpgradeOptions) do original[index] = row.ItemName end
    callbacks.HandleLootPickup(nil, {}, function()
        callbacks.CreateBoonLootButtons(nil, {}, function()
            for index, item in ipairs(loot.UpgradeOptions) do
                callbacks.CreateUpgradeChoiceButton(nil, {}, function() return true end,
                    {}, loot, index, item, {})
            end
        end, {}, loot, false, {})
    end, {}, loot, {})
    lu.assertEquals(mismatches[1].expected, "three Chaos transforming rows")
    lu.assertEquals({ loot.UpgradeOptions[1].ItemName, loot.UpgradeOptions[2].ItemName }, original)
end

function TestChaosTraits.testMissingTransformingRowsReportsWithoutThrowing()
    local loot = { Name = "TrialUpgrade" }
    local callbacks, _, _, _, mismatches = harness(loot)
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    callbacks.CreateBoonLootButtons(nil, {}, function()
        callbacks.CreateUpgradeChoiceButton(nil, {}, function() return true end,
            {}, loot, 1, {}, {})
    end, {}, loot, false, {})
    lu.assertEquals(mismatches[1].expected, "three Chaos transforming rows")
    lu.assertEquals(mismatches[1].observed, "nil")
end

function TestChaosTraits.testNativeSelectionErrorRetiresStaleChaosScope()
    local loot = {
        Name = "TrialUpgrade",
        UpgradeOptions = {
            { ItemName = "ChaosPeerA" }, { ItemName = "ChaosPeerB" }, { ItemName = "ChaosElementalBlessing" },
        },
    }
    local callbacks, _, _, _, _, completed = harness(loot)
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local button = { LootData = loot, Data = { Name = "ChaosNoMoneyCurse" } }
    lu.assertError(function()
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function() error("native selection failed") end,
            {}, button, {})
    end)

    local nativeCalled = false
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function()
        nativeCalled = true
        return true
    end, {}, button, {})
    lu.assertTrue(nativeCalled)
    lu.assertEquals(completed, {})
end

function TestChaosTraits.testNativeDenialSeesOnlyAuthoredCurseNames()
    local authored = offer()
    authored.curseOptions = {
        { curseKey = "ChaosNoMoneyCurse", requirementCount = 1 },
        { curseKey = "ChaosHealthCurse", requirementCount = 2 },
        { curseKey = "ChaosDamageCurse", requirementCount = 3 },
    }
    local loot = {
        Name = "TrialUpgrade",
        UpgradeOptions = {
            { ItemName = "ChaosHealthBlessing", Rarity = "Common" },
            { ItemName = "ChaosManaBlessing", Rarity = "Common" },
            { ItemName = "ChaosElementalBlessing", Rarity = "Common" },
        },
    }
    local callbacks = harness(loot, authored)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} }, BannedTraits = {} }
    local screen = { UpgradeButtons = {} }
    callbacks.HandleLootPickup(nil, {}, function()
        callbacks.CreateBoonLootButtons(nil, {}, function()
            for index, item in ipairs(loot.UpgradeOptions) do
                local button = callbacks.CreateUpgradeChoiceButton(nil, {}, function(_, _, _, row)
                    local curse = callbacks.GetProcessedTraitData(nil, {}, function(args)
                        return { Name = args.TraitName, Rarity = args.Rarity }
                    end, { TraitName = row.SecondaryItemName, Rarity = row.Rarity })
                    local blessing = callbacks.GetProcessedTraitData(nil, {}, function(args)
                        return { Name = args.TraitName, Rarity = args.Rarity }
                    end, { TraitName = row.ItemName, Rarity = row.Rarity })
                    curse.OnExpire = { TraitData = blessing }
                    return { Data = curse, LootData = loot }
                end, screen, loot, index, item, {})
                table.insert(screen.UpgradeButtons, button)
            end
        end, screen, loot, false, {})

    end, {}, loot, {})
    local selectedButton = screen.UpgradeButtons[1]
    _G.CurrentRun.Hero.Traits = { selectedButton.Data }
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function(_, button)
        local selected = button.Data.Name
        for _, otherButton in ipairs(screen.UpgradeButtons) do
            if otherButton.Data.Name ~= selected then
                _G.CurrentRun.BannedTraits[otherButton.Data.Name] = true
            end
        end
        return true
    end, screen, selectedButton, {})
    local bannedTraits = _G.CurrentRun.BannedTraits
    _G.CurrentRun = priorRun

    lu.assertEquals(screen.UpgradeButtons[1].Data.Name, "ChaosNoMoneyCurse")
    lu.assertEquals(screen.UpgradeButtons[2].Data.Name, "ChaosHealthCurse")
    lu.assertEquals(screen.UpgradeButtons[3].Data.Name, "ChaosDamageCurse")
    lu.assertTrue(screen.UpgradeButtons[1].Data.OnExpire.TraitData.Name == "ChaosElementalBlessing")
    lu.assertEquals(screen.UpgradeButtons[2].Data.OnExpire.TraitData.Name, "ChaosManaBlessing")
    lu.assertTrue(screen.UpgradeButtons[3].Data.OnExpire.TraitData.Name == "ChaosHealthBlessing")
    lu.assertTrue(bannedTraits.ChaosHealthCurse)
    lu.assertTrue(bannedTraits.ChaosDamageCurse)
    lu.assertNil(bannedTraits.ChaosElementalBlessing)
    lu.assertNil(bannedTraits.ChaosManaBlessing)
    lu.assertNil(bannedTraits.ChaosHealthBlessing)
end

function TestChaosTraits.testWrongChaosSelectionFailsExactPairTerminal()
    local loot = {
        Name = "TrialUpgrade",
        UpgradeOptions = {
            { ItemName = "ChaosPeerA" }, { ItemName = "ChaosPeerB" }, { ItemName = "ChaosElementalBlessing" },
        },
    }
    local callbacks, _, _, _, _, completed = harness(loot)
    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = {} } }
    local buttons, screen = {}, {}
    callbacks.HandleLootPickup(nil, {}, function()
        callbacks.CreateBoonLootButtons(nil, {}, function()
            for index, item in ipairs(loot.UpgradeOptions) do
                buttons[index] = callbacks.CreateUpgradeChoiceButton(nil, {}, function(_, _, _, row)
                    local curse = callbacks.GetProcessedTraitData(nil, {}, function(args)
                        return { Name = args.TraitName, Rarity = args.Rarity }
                    end, { TraitName = row.SecondaryItemName, Rarity = row.Rarity })
                    local blessing = callbacks.GetProcessedTraitData(nil, {}, function(args)
                        return { Name = args.TraitName, Rarity = args.Rarity }
                    end, { TraitName = row.ItemName, Rarity = row.Rarity })
                    curse.OnExpire = { TraitData = blessing }
                    return { Data = curse, LootData = loot }
                end, screen, loot, index, item, {})
            end
        end, screen, loot, false, {})
        _G.CurrentRun.Hero.Traits = { buttons[2].Data }
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
            screen, buttons[2], {})
    end, {}, loot, {})
    _G.CurrentRun = priorRun
    lu.assertEquals(completed, {})
end

function TestChaosTraits.testMaterializedTrialUpgradeBindsItsExactPublishedRole()
    local module, callbacks = capture()
    local state, occurrence, producer, materialized = { state = "synchronized" }, {
        occurrence = {
            overview = { incomingReward = { producerLifecycleKey = "RoomReward", rewardType = "TrialUpgrade" } },
        },
    }, {}, {}
    local bound = false
    local room = {
        current = function() return occurrence end,
        resolve = function(_, _, contact)
            if contact.kind == "producer" then
                lu.assertEquals(contact.producerLifecycleKey, "RoomReward")
                lu.assertEquals(contact.rewardType, "TrialUpgrade")
                return producer
            end
            lu.assertEquals(contact.kind, "materialized")
            lu.assertTrue(contact.source == producer)
            lu.assertEquals(contact.gameName, "TrialUpgrade")
            return materialized
        end,
        bind = function(_, _, handle, native)
            lu.assertTrue(handle == materialized)
            lu.assertEquals(native.Name, "TrialUpgrade")
            bound = true
            return handle
        end,
    }
    binding.attach(module, {}, function() return state end, function() end, room)
    local result = callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return { Name = "TrialUpgrade" } end, {})
    end, {}, {})
    lu.assertEquals(result.Name, "TrialUpgrade")
    lu.assertTrue(bound)
end

return TestChaosTraits
