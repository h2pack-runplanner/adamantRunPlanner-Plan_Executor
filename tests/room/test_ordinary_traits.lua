-- luacheck: globals TestOrdinaryTraits
local lu = require("luaunit")
local ordinary = require("mods.room.timeline.traits.ordinary")
local hooks = require("mods.room.timeline.traits.hooks")

TestOrdinaryTraits = {}

local function payload(offer)
    return { detail = { traitOffer = offer }, transaction = {} }
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

function TestOrdinaryTraits.testReplacementProofRequiresOldTraitAbsence()
    local row = payload({
        kind = "traits", selected = "option1", options = {
            { key = "ApolloAttack", rarity = "Rare", replacement = {
                replacedTraitKey = "OldAttack",
            } },
        },
    })
    lu.assertTrue(ordinary.verify(row, "ApolloAttack", { { Name = "ApolloAttack", Rarity = "Rare" } }))
    lu.assertFalse(ordinary.verify(row, "ApolloAttack", {
        { Name = "ApolloAttack", Rarity = "Rare" }, { Name = "OldAttack" },
    }))
end

function TestOrdinaryTraits.testFallbackGoldHasItsOwnHiddenTraitTerminal()
    local row = payload({ kind = "fallbackGold", giver = "Hermes" })
    lu.assertTrue(ordinary.verify(row, "FallbackGold", { { Name = "FallbackGold" } }))
    lu.assertFalse(ordinary.verify(row, "FallbackGold", {}))
    lu.assertFalse(ordinary.verify(row, "Other", {}))
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

local function attached(offer)
    local callbacks, bound, begins, completed = {}, setmetatable({}, { __mode = "k" }), 0, 0
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
        begin = function(_, value)
            if state.state ~= "synchronized" then return nil end
            if value ~= materialized then return nil end
            begins = begins + 1
            if activePayload == nil then activePayload = payload(offer or { kind = "traits", selected = "option1", options = {
                { key = "ApolloAttack", rarity = "Rare" },
            } }) end
            return activePayload
        end,
    }
    local session = {
        complete = function() completed = completed + 1 end,
        resolveFallback = function(_, value, row, _, fallback, available)
            if available(fallback.preferredKey) then return fallback.preferredKey, value, row end
            if fallback.fallbackKey and available(fallback.fallbackKey) then
                row.realizedKey = fallback.fallbackKey
                return fallback.fallbackKey, value, row
            end
            state.state = "desynchronized"
            return nil
        end,
    }
    hooks.attach(module, session, function() return state end, function() end, room)
    return callbacks, function() return begins end, function() return completed end
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

function TestOrdinaryTraits.testRerollDoesNotReinstallFrozenOffer()
    local callbacks = attached()
    local loot = { GodLoot = true, Name = "ApolloUpgrade", UpgradeOptions = { { ItemName = "Native" } } }
    callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateLoot(nil, {}, function() return loot end, {})
    end, {}, {})
    callbacks.CreateBoonLootButtons(nil, {}, function() return true end, {}, loot, true, {})
    lu.assertEquals(loot.UpgradeOptions[1].ItemName, "Native")
end

function TestOrdinaryTraits.testBoundRoleResolvesPreferredFallbackOrNeither()
    local originalTraitData, originalEligible = _G.TraitData, _G.IsTraitEligible
    _G.TraitData = { Preferred = {}, Fallback = {} }
    local offer = {
        kind = "traits", selected = "option1", options = { { key = "Preferred", rarity = "Rare" } },
        runtimeFallbacks = { { availabilityContact = "traitEligibility", preferredKey = "Preferred", fallbackKey = "Fallback" } },
    }
    local function materialize(eligible)
        _G.IsTraitEligible = function(data) return eligible[data == _G.TraitData.Preferred and "Preferred" or "Fallback"] end
        local callbacks = attached(offer)
        local loot = { GodLoot = true, Name = "ApolloUpgrade", UpgradeOptions = {} }
        callbacks.SpawnRoomReward(nil, {}, function()
            local created = callbacks.CreateLoot(nil, {}, function() return loot end, {})
            callbacks.HandleLootPickup(nil, {}, function() return true end, {}, created, {})
            return created
        end, {}, {})
        callbacks.CreateBoonLootButtons(nil, {}, function() return true end, {}, loot, false, {})
        return loot.UpgradeOptions[1] and loot.UpgradeOptions[1].ItemName or nil
    end
    lu.assertEquals(materialize({ Preferred = true, Fallback = true }), "Preferred")
    lu.assertEquals(materialize({ Preferred = false, Fallback = true }), "Fallback")
    lu.assertNil(materialize({ Preferred = false, Fallback = false }))
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
