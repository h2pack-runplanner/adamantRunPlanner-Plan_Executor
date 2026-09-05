-- luacheck: globals TestOrdinaryTraits
local lu = require("luaunit")
local json = require("mods.json")
local ordinary = require("mods.room.timeline.acquisitions.traits.ordinary")
local hooks = require("mods.room.timeline.acquisitions.traits.hooks")
local binding = require("mods.room.timeline.acquisitions.binding")

TestOrdinaryTraits = {}

local function payload(offer, disposition)
    return { detail = { traitOffer = offer, disposition = disposition or "normal" }, transaction = {} }
end

function TestOrdinaryTraits.testInstallsBaseRarityAndFinalEffectiveLevelOnNativeCarriers()
    local row = payload({
        kind = "traits", selected = "option1", options = {
            { key = "ApolloAttack", baseRarity = "Common", rarity = "Rare", effectiveLevel = 4 },
            { key = "ApolloSpecial", rarity = "Epic" },
        },
    })
    local loot = { GodLoot = true, UpgradeOptions = { { Type = "Trait", Native = true } } }
    lu.assertTrue(ordinary.install(row, loot))
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "ApolloAttack")
    lu.assertEquals(loot.UpgradeOptions[1].Rarity, "Common")
    lu.assertEquals(loot.UpgradeOptions[1].StackNum, 4)
    lu.assertTrue(loot.UpgradeOptions[1].Native)
end

function TestOrdinaryTraits.testRejectedIdentitySurvivesNativeReorder()
    local row = payload({
        kind = "traits", selected = "option1", rejected = "option2", options = {
            { key = "ApolloAttack" }, { key = "ApolloCast" }, { key = "ApolloSpecial" },
        },
    })
    local loot = { UpgradeOptions = { { ItemName = "ApolloCast" }, { ItemName = "ApolloAttack" } } }
    local screen = { BlockedIndexes = {} }
    ordinary.alignRejected(row, screen, loot)
    lu.assertEquals(screen.BlockedIndexes, { 1 })
end

function TestOrdinaryTraits.testFallbackGoldHasItsOwnExactTerminal()
    local row = payload({ kind = "fallbackGold", giver = "Hermes" })
    lu.assertEquals(ordinary.selectedKey(row), "FallbackGold")
end

function TestOrdinaryTraits.testHammerAndHermesAreOrdinaryNativeCarriers()
    lu.assertTrue(ordinary.isCarrier({ Name = "WeaponUpgrade" }, { kind = "traits", options = {} }))
    lu.assertTrue(ordinary.isCarrier({ Name = "HermesUpgrade" }, { kind = "traits", options = {} }))
    lu.assertFalse(ordinary.isCarrier({ Name = "Chaos" }, { kind = "traits", options = {} }))
end

function TestOrdinaryTraits.testOlympianHermesAndHammerShareTheNativeRowContract()
    local row = payload({ kind = "traits", selected = "option1", options = {
        { key = "Chosen", baseRarity = "Common", rarity = "Rare" },
    } })
    for _, loot in ipairs({
        { GodLoot = true, Name = "ApolloUpgrade", UpgradeOptions = {} },
        { Name = "HermesUpgrade", UpgradeOptions = {} },
        { Name = "WeaponUpgrade", UpgradeOptions = {} },
    }) do
        lu.assertTrue(ordinary.isCarrier(loot, ordinary.offer(row)))
        lu.assertTrue(ordinary.install(row, loot))
        lu.assertEquals(loot.UpgradeOptions[1].ItemName, "Chosen")
        lu.assertEquals(loot.UpgradeOptions[1].Rarity, "Common")
    end
end

local function attached(offer, disposition)
    local callbacks, bound, begins, completed, mismatches = {}, setmetatable({}, { __mode = "k" }), 0, 0, {}
    local activePayload
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local producer, materialized = {}, {}
    local active = { occurrence = {
        overview = { incomingReward = { producerLifecycleKey = "incoming", rewardType = "Boon" } },
    } }
    local state = { state = "synchronized" }
    local room = {
        current = function() return active end,
        resolve = function(_, _, contact)
            if contact.kind == "producer" then return producer end
            if contact.kind == "materialized" and contact.source == producer
                and contact.gameName == "ApolloUpgrade" then return materialized end
            return nil
        end,
        bind = function(_, _, value, native) bound[native] = value; return value end,
        bound = function(_, _, native) return bound[native] end,
        peek = function(_, value)
            if value ~= materialized then return nil end
            if activePayload == nil then
                activePayload = payload(offer or { kind = "traits", selected = "option1", options = {
                    { key = "ApolloAttack", rarity = "Rare" },
                } }, disposition)
            end
            return activePayload
        end,
        begin = function(_, value)
            if state.state ~= "synchronized" then return nil end
            if value ~= materialized then return nil end
            begins = begins + 1
            if activePayload == nil then
                activePayload = payload(offer or {
                    kind = "traits", selected = "option1", options = {
                        { key = "ApolloAttack", rarity = "Rare" },
                    },
                }, disposition)
            end
            return activePayload
        end,
    }
    local session = {
        complete = function() completed = completed + 1 end,
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = { checkpoint = checkpoint, expected = expected, observed = observed }
        end,
    }
    binding.attach(module, session, function() return state end, function() end, room)
    hooks.attach(module, session, function() return state end, function() end, room)
    return callbacks, function() return begins end, function() return completed end,
        function() return mismatches end, function(value) active = value end
end

function TestOrdinaryTraits.testFailedUseLootHasNoC1BeginAndPickupBeginsTheBoundOwner()
    local callbacks, begins = attached()
    lu.assertNil(callbacks.UseLoot)
    lu.assertEquals(begins(), 0)
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        local created = callbacks.CreateLoot(nil, {}, function() return loot end, {})
        callbacks.HandleLootPickup(nil, {}, function() return true end, {}, created, {})
        return created
    end, {}, {})
    lu.assertEquals(begins(), 1)
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, { GodLoot = true, Name = "ApolloUpgrade" }, {})
    lu.assertEquals(begins(), 1)
end

function TestOrdinaryTraits.testArtificerDispositionDoesNotEnterTheOrdinaryAdapter()
    local callbacks, begins = attached({
        kind = "traits", selected = "option1", options = { { key = "ApolloAttack", rarity = "Rare" } },
    }, "artificer")
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    lu.assertEquals(begins(), 0)
end

function TestOrdinaryTraits.testMissingDispositionDoesNotEnterTheOrdinaryAdapter()
    local offer = { kind = "traits", selected = "option1", options = { { key = "ApolloAttack" } } }
    lu.assertFalse(ordinary.isNormalPayload({ detail = { traitOffer = offer } }))
    lu.assertNil(ordinary.offer({ detail = { traitOffer = offer } }))
end

function TestOrdinaryTraits.testUnboundHammerCarriersUsePublishedReadyOrderWithoutSourceProvenance()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local state = { state = "synchronized" }
    local active = { occurrence = { overview = {} } }
    local offer = { kind = "traits", selected = "option1", options = { { key = "ApolloAttack" } } }
    local rows, handles = {}, {}
    for index, owner in ipairs({ "child-a", "child-b" }) do
        local detail = {
            role = "self", disposition = "normal", lifecyclePoint = "roomRewardPickup",
            kind = "loot", gameName = "WeaponUpgrade", traitOffer = offer,
        }
        rows[index] = { transaction = { owner = owner, kind = "acquisition", roles = { detail } }, detail = detail }
        handles[index] = {}
    end
    local nativeHandles, claimed, begins, completions = {}, {}, 0, {}
    local room = {
        current = function() return active end,
        bound = function(_, _, native) return nativeHandles[native] end,
        claimReady = function(_, _, contact, native, compatible)
            for index, row in ipairs(rows) do
                if not claimed[index] and compatible(row.transaction, contact) ~= nil then
                    claimed[index] = true
                    nativeHandles[native] = handles[index]
                    return handles[index], row
                end
            end
        end,
        peek = function(_, handle)
            for index, value in ipairs(handles) do if value == handle then return rows[index] end end
        end,
        begin = function(_, handle)
            begins = begins + 1
            for index, value in ipairs(handles) do if value == handle then return rows[index] end end
        end,
    }
    local session = {
        complete = function(_, handle)
            completions[#completions + 1] = { handle = handle }
        end,
    }
    hooks.attach(module, session, function() return state end, function() end, room)

    local priorRun = _G.CurrentRun
    _G.CurrentRun = { Hero = { Traits = { { Name = "ApolloAttack" } } } }
    local firstPhysical = { Name = "WeaponUpgrade", UpgradeOptions = {} }
    local secondPhysical = { Name = "WeaponUpgrade", UpgradeOptions = {} }
    for _, loot in ipairs({ secondPhysical, firstPhysical }) do
        callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
        callbacks.CreateBoonLootButtons(nil, {}, function() return true end, {}, loot, false, {})
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end, {}, {
            LootData = loot, Data = { Name = "ApolloAttack" },
        }, {})
    end
    _G.CurrentRun = priorRun

    lu.assertEquals(nativeHandles[secondPhysical], handles[1])
    lu.assertEquals(nativeHandles[firstPhysical], handles[2])
    lu.assertEquals(completions, {
        { handle = handles[1] }, { handle = handles[2] },
    })
    lu.assertEquals(begins, 6)
end

function TestOrdinaryTraits.testRerollDoesNotReinstallFrozenOffer()
    local callbacks = attached()
    local loot = { GodLoot = true, Name = "ApolloUpgrade", UpgradeOptions = { { ItemName = "Native" } } }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.CreateBoonLootButtons(nil, {}, function() return true end, {}, loot, true, {})
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "Native")
end

function TestOrdinaryTraits.testUnavailableExactRowLeavesNativeMenuIntact()
    local originalTraitData, originalEligible = _G.TraitData, _G.IsTraitEligible
    _G.TraitData = { ApolloAttack = {} }
    _G.IsTraitEligible = function() return false end
    local callbacks, _, _, mismatches = attached({
        kind = "traits", selected = "option1", options = { { key = "ApolloAttack", rarity = "Rare" } },
    })
    local loot = { GodLoot = true, Name = "ApolloUpgrade", UpgradeOptions = {} }
    callbacks.SpawnRoomReward(nil, {}, function()
        local created = callbacks.CreateLoot(nil, {}, function() return loot end, {})
        callbacks.HandleLootPickup(nil, {}, function() return true end, {}, created, {})
        return created
    end, {}, {})
    callbacks.CreateBoonLootButtons(nil, {}, function() return true end, {}, loot, false, {})
    lu.assertEquals(loot.UpgradeOptions, {})
    lu.assertEquals(mismatches()[1].checkpoint, "trait-availability")
    _G.TraitData, _G.IsTraitEligible = originalTraitData, originalEligible
end

function TestOrdinaryTraits.testConcaveNestedSelectionDoesNotCompletePrimary()
    local callbacks, _, completed = attached()
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    local button = { LootData = loot, Data = { Name = "ApolloAttack" } }
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end, {}, button, { DoubleBoonChance = true })
    lu.assertEquals(completed(), 0)
end

local function concaveOffer(result, residual)
    return {
        kind = "traits",
        selected = "option1",
        options = {
            { key = "Primary", concaveStoneResult = result },
            residual or { key = "Residual" },
            { key = "Other" },
        },
    }
end

local function selectConcave(callbacks, loot, candidates, nested)
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function(_, outerButton)
        local stone = callbacks.HasHeroTraitValue(nil, {}, function()
            return { Uses = 1, DoubleBoonChance = 0.75 }
        end, "DoubleBoonChance")
        if callbacks.RandomChance(nil, {}, function() return false end, stone.DoubleBoonChance, {}) then
            local nextButton = callbacks.GetRandomValue(nil, {}, function(values) return values[1] end, candidates)
            callbacks.HandleUpgradeChoiceSelection(nil, {}, nested or function() return true end,
                {}, nextButton, { DoubleBoonChance = true })
        end
        return outerButton
    end, {}, { LootData = loot, Data = { Name = "Primary" } }, {})
end

function TestOrdinaryTraits.testConcaveStoneEpicNoProcConsumesTheNativeRollBeforeTheOuterTerminal()
    local callbacks, _, completed, mismatches = attached(concaveOffer({ kind = "noProc" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    selectConcave(callbacks, loot, {})
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testConcaveStoneEpicProcForcesItsExactResidualButton()
    local callbacks, _, completed, mismatches = attached(concaveOffer({ kind = "proc", optionKey = "option2" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local residual = { LootData = loot, Data = { Name = "Residual" } }
    selectConcave(callbacks, loot, { { LootData = loot, Data = { Name = "Other" } }, residual })
    lu.assertEquals(mismatches(), {})
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testConcaveStoneForcedHeroicProcOverridesOnlyTheNativeRoll()
    local callbacks, _, completed, mismatches = attached(concaveOffer({ kind = "proc", optionKey = "option2" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    selectConcave(callbacks, loot, { { LootData = loot, Data = { Name = "Residual" } } })
    lu.assertEquals(mismatches(), {})
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testConcaveResidualAllTogetherStaysWithinTheOuterC1Scope()
    local callbacks, _, completed, mismatches = attached(concaveOffer(
        { kind = "proc", optionKey = "option2" },
        { key = "AllElementalBoon", allTogetherResult = {
            earth = "Earth", fire = json.null, air = json.null, water = json.null,
        } }
    ))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local residual = { LootData = loot, Data = { Name = "AllElementalBoon" } }
    selectConcave(callbacks, loot, { residual }, function(_, nestedButton)
        callbacks.GrantBoons(nil, {}, function(args)
            lu.assertEquals(callbacks.GetRandomValue(nil, {}, function(values) return values[1] end,
                args.BoonSets[1]), "Earth")
        end, { BoonSets = { { "OtherEarth", "Earth" }, {}, {}, {} } }, nestedButton.Data)
        lu.assertEquals(completed(), 0)
        return true
    end)
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testConcaveMissingOrUnavailableResidualLeavesOuterIncompleteAndCleansScope()
    local callbacks, _, completed, mismatches = attached(concaveOffer({ kind = "proc", optionKey = "option2" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    selectConcave(callbacks, loot, { { LootData = loot, Data = { Name = "Other" } } })
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches()[1].checkpoint, "concave-stone-residual")
    lu.assertFalse(callbacks.RandomChance(nil, {}, function() return false end, 1, {}))
end

function TestOrdinaryTraits.testConcaveMissingNativeRollLeavesOuterIncompleteAndCleansScope()
    local callbacks, _, completed, mismatches = attached(concaveOffer({ kind = "noProc" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end,
        {}, { LootData = loot, Data = { Name = "Primary" } }, {})
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches()[1].checkpoint, "concave-stone-roll")
    lu.assertFalse(callbacks.RandomChance(nil, {}, function() return false end, 1, {}))
end

function TestOrdinaryTraits.testConcaveNativeErrorClearsItsScopeWithoutCompletingC1()
    local callbacks, _, completed = attached(concaveOffer({ kind = "noProc" }))
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    local ok = pcall(function()
        callbacks.HandleUpgradeChoiceSelection(nil, {}, function()
            local stone = callbacks.HasHeroTraitValue(nil, {}, function()
                return { Uses = 1, DoubleBoonChance = 0.75 }
            end, "DoubleBoonChance")
            callbacks.RandomChance(nil, {}, function() return false end, stone.DoubleBoonChance, {})
            error("native selection failure")
        end, {}, { LootData = loot, Data = { Name = "Primary" } }, {})
    end)
    lu.assertFalse(ok)
    lu.assertEquals(completed(), 0)
    lu.assertFalse(callbacks.RandomChance(nil, {}, function() return false end, 1, {}))
end

local function beginAllTogether(callbacks)
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function() return true end, {}, {
        LootData = loot, Data = { Name = "AllElementalBoon" },
    }, {})
end

local function grant(callbacks, sets, eligible)
    local granted = {}
    callbacks.GrantBoons(nil, {}, function(args)
        for index, _ in ipairs(args.BoonSets) do
            local candidates = eligible[index]
            if #candidates > 0 then
                granted[#granted + 1] = callbacks.GetRandomValue(nil, {}, function(values)
                    return values[1]
                end, candidates)
            end
        end
    end, { BoonSets = sets }, { Name = "AllElementalBoon" })
    return granted
end

function TestOrdinaryTraits.testAllTogetherSteersEachEligibleNativePairToItsFourExactGrants()
    local offer = { kind = "traits", selected = "option1", options = {
        { key = "AllElementalBoon", allTogetherResult = {
            earth = "ElementalDamageBoon", fire = "ElementalBaseDamageBoon",
            air = "ElementalDamageFloorBoon", water = "ElementalHealthBoon",
        } },
    } }
    local callbacks, _, completed, mismatches = attached(offer)
    beginAllTogether(callbacks)
    lu.assertEquals(completed(), 0)
    local granted = grant(callbacks, {
        { "ElementalDamageBoon", "ElementalOlympianDamageBoon" },
        { "ElementalBaseDamageBoon", "ElementalRallyBoon" },
        { "ElementalDamageFloorBoon", "ElementalDodgeBoon" },
        { "ElementalHealthBoon", "ElementalDamageCapBoon" },
    }, {
        { "ElementalDamageBoon", "ElementalOlympianDamageBoon" },
        { "ElementalBaseDamageBoon", "ElementalRallyBoon" },
        { "ElementalDamageFloorBoon", "ElementalDodgeBoon" },
        { "ElementalHealthBoon", "ElementalDamageCapBoon" },
    })
    lu.assertEquals(granted, {
        "ElementalDamageBoon", "ElementalBaseDamageBoon",
        "ElementalDamageFloorBoon", "ElementalHealthBoon",
    })
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testAllTogetherAcceptsForcedRemainingMemberAndExplicitExhaustedSet()
    local offer = { kind = "traits", selected = "option1", options = {
        { key = "AllElementalBoon", allTogetherResult = {
            earth = "ElementalOlympianDamageBoon", fire = "ElementalBaseDamageBoon",
            air = "ElementalDamageFloorBoon", water = json.null,
        } },
    } }
    local callbacks, _, completed, mismatches = attached(offer)
    beginAllTogether(callbacks)
    local granted = grant(callbacks, {
        { "ElementalDamageBoon", "ElementalOlympianDamageBoon" },
        { "ElementalBaseDamageBoon", "ElementalRallyBoon" },
        { "ElementalDamageFloorBoon", "ElementalDodgeBoon" },
        { "ElementalHealthBoon", "ElementalDamageCapBoon" },
    }, {
        { "ElementalOlympianDamageBoon" },
        { "ElementalBaseDamageBoon", "ElementalRallyBoon" },
        { "ElementalDamageFloorBoon", "ElementalDodgeBoon" },
        {},
    })
    lu.assertEquals(granted, {
        "ElementalOlympianDamageBoon", "ElementalBaseDamageBoon", "ElementalDamageFloorBoon",
    })
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testAllTogetherUnavailableExactGrantLeavesOuterIncompleteAndRunsNativeChoice()
    local offer = { kind = "traits", selected = "option1", options = {
        { key = "AllElementalBoon", allTogetherResult = {
            earth = "ElementalDamageBoon", fire = json.null, air = json.null, water = json.null,
        } },
    } }
    local callbacks, _, completed, mismatches, setActive = attached(offer)
    beginAllTogether(callbacks)
    local granted = grant(callbacks, {
        { "ElementalDamageBoon", "ElementalOlympianDamageBoon" }, {}, {}, {},
    }, {
        { "ElementalOlympianDamageBoon" }, {}, {}, {},
    })
    lu.assertEquals(granted, { "ElementalOlympianDamageBoon" })
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches()[1].checkpoint, "all-together-grant")

    setActive({ occurrence = { overview = {} } })
    local native = grant(callbacks, {
        { "ElementalOlympianDamageBoon", "ElementalDamageBoon" }, {}, {}, {},
    }, {
        { "ElementalOlympianDamageBoon", "ElementalDamageBoon" }, {}, {}, {},
    })
    lu.assertEquals(native, { "ElementalOlympianDamageBoon" })
    lu.assertEquals(#mismatches(), 1)
end

function TestOrdinaryTraits.testAllTogetherBaseErrorAndLaterRoomCannotReuseStaleGrantScope()
    local offer = { kind = "traits", selected = "option1", options = {
        { key = "AllElementalBoon", allTogetherResult = {
            earth = "ElementalDamageBoon", fire = json.null, air = json.null, water = json.null,
        } },
    } }
    local callbacks, _, completed, mismatches, setActive = attached(offer)
    beginAllTogether(callbacks)
    local ok = pcall(function()
        callbacks.GrantBoons(nil, {}, function() error("native GrantBoons failure") end,
            { BoonSets = { { "ElementalDamageBoon", "ElementalOlympianDamageBoon" }, {}, {}, {} } },
            { Name = "AllElementalBoon" })
    end)
    lu.assertFalse(ok)
    setActive({ occurrence = { overview = {} } })
    local native = grant(callbacks, {
        { "ElementalDamageBoon", "ElementalOlympianDamageBoon" }, {}, {}, {},
    }, {
        { "ElementalOlympianDamageBoon", "ElementalDamageBoon" }, {}, {}, {},
    })
    lu.assertEquals(native, { "ElementalOlympianDamageBoon" })
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches(), {})
end

local function naturalOffer(targets)
    return { kind = "traits", selected = "option1", options = {
        { key = "GoodStuffBoon", naturalSelectionTargets = targets },
    } }
end

local function selectNatural(callbacks, distribute)
    local loot = { GodLoot = true, Name = "ApolloUpgrade" }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.HandleLootPickup(nil, {}, function() return true end, {}, loot, {})
    callbacks.HandleUpgradeChoiceSelection(nil, {}, function()
        distribute()
        return true
    end, {}, { LootData = loot, Data = { Name = "GoodStuffBoon" } }, {})
end

local function distribute(callbacks, candidates, successfulTargets)
    local order, applied = nil, {}
    callbacks.DistributeLevels(nil, {}, function()
        order = callbacks.FYShuffle(nil, {}, function(values) return values end, candidates)
        for _, target in ipairs(successfulTargets) do
            callbacks.IncreaseTraitLevel(nil, {}, function(trait)
                applied[#applied + 1] = trait.Name
            end, { Name = target })
        end
        return true
    end, { Slots = {} }, { Name = "GoodStuffBoon" })
    return order, applied
end

function TestOrdinaryTraits.testNaturalSelectionCompletesFewerThanEightSuccessfulLevelsAfterExhaustion()
    local callbacks, _, completed, mismatches = attached(naturalOffer({ "Attack", "Special" }))
    local order, applied
    selectNatural(callbacks, function()
        order, applied = distribute(callbacks, { "Attack", "Special", "Cast" }, { "Attack", "Special" })
    end)
    lu.assertEquals(order, { "Attack", "Special", "Cast" })
    lu.assertEquals(applied, { "Attack", "Special" })
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testNaturalSelectionRetainsThenLetsNativeCondemnACappedTargetBetweenRounds()
    local targets = { "Attack", "Special", "Cast", "Attack", "Special" }
    local callbacks, _, completed, mismatches = attached(naturalOffer(targets))
    local order, applied
    selectNatural(callbacks, function()
        order, applied = distribute(callbacks, { "Attack", "Special", "Cast", "Mana" }, targets)
    end)
    lu.assertEquals(order, { "Attack", "Special", "Cast", "Mana" })
    lu.assertEquals(applied, targets)
    lu.assertEquals(#applied, 5)
    lu.assertEquals(applied[3], "Cast")
    lu.assertEquals(applied[4], "Attack")
    local castCallbacks = 0
    for _, target in ipairs(applied) do
        if target == "Cast" then castCallbacks = castCallbacks + 1 end
    end
    lu.assertEquals(castCallbacks, 1)
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testNaturalSelectionConsumesEightSuccessfulLevelsAcrossSeveralSlots()
    local targets = { "Attack", "Special", "Cast", "Attack", "Special", "Cast", "Attack", "Special" }
    local callbacks, _, completed, mismatches = attached(naturalOffer(targets))
    local applied
    selectNatural(callbacks, function()
        _, applied = distribute(callbacks, { "Attack", "Special", "Cast" }, targets)
    end)
    lu.assertEquals(applied, targets)
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testNaturalSelectionReportsMissingTargetAndCleansItsScope()
    local callbacks, _, completed, mismatches, setActive = attached(naturalOffer({ "Attack", "Special" }))
    selectNatural(callbacks, function()
        distribute(callbacks, { "Attack", "Special" }, { "Attack" })
    end)
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches()[1].checkpoint, "natural-selection-target")

    setActive({ occurrence = { overview = {} } })
    local order = distribute(callbacks, { "NativeOne", "NativeTwo" }, {})
    lu.assertEquals(order, { "NativeOne", "NativeTwo" })
    lu.assertEquals(#mismatches(), 1)
end

function TestOrdinaryTraits.testNaturalSelectionUnavailableTargetLeavesNativeShuffleAndOuterIncomplete()
    local callbacks, _, completed, mismatches, setActive = attached(naturalOffer({ "Attack" }))
    local order
    selectNatural(callbacks, function()
        order = distribute(callbacks, { "Special" }, { "Special" })
    end)
    lu.assertEquals(order, { "Special" })
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches()[1].checkpoint, "natural-selection-order")

    setActive({ occurrence = { overview = {} } })
    local native = distribute(callbacks, { "NativeOne", "NativeTwo" }, {})
    lu.assertEquals(native, { "NativeOne", "NativeTwo" })
    lu.assertEquals(#mismatches(), 1)
end

function TestOrdinaryTraits.testNaturalSelectionSteersOnlyTheFirstShuffleInItsExactNativeDistribution()
    local targets = { "Special", "Attack" }
    local callbacks, _, completed, mismatches = attached(naturalOffer(targets))
    local firstOrder, laterOrder = nil, nil
    selectNatural(callbacks, function()
        callbacks.DistributeLevels(nil, {}, function()
            firstOrder = callbacks.FYShuffle(nil, {}, function(values) return values end, { "Attack", "Special" })
            laterOrder = callbacks.FYShuffle(nil, {}, function(values) return values end, { "Attack", "Special" })
            callbacks.IncreaseTraitLevel(nil, {}, function() end, { Name = "Special" })
            callbacks.IncreaseTraitLevel(nil, {}, function() end, { Name = "Attack" })
        end, { Slots = {} }, { Name = "GoodStuffBoon" })
    end)
    lu.assertEquals(firstOrder, { "Special", "Attack" })
    lu.assertEquals(laterOrder, { "Attack", "Special" })
    lu.assertEquals(completed(), 1)
    lu.assertEquals(mismatches(), {})
end

function TestOrdinaryTraits.testNaturalSelectionOuterBaseErrorClearsScopeBeforeNativeReentry()
    local callbacks, _, completed, mismatches = attached(naturalOffer({ "Special", "Attack" }))
    local failed = pcall(function()
        selectNatural(callbacks, function() error("native selection failure") end)
    end)
    lu.assertFalse(failed)

    local nativeOrder = distribute(callbacks, { "Attack", "Special" }, {})
    lu.assertEquals(nativeOrder, { "Attack", "Special" })
    lu.assertEquals(completed(), 0)
    lu.assertEquals(mismatches(), {})
end
