local lu = require("luaunit")
local tree = require("mods.spells.hex_tree").create()
local spell = require("mods.room.timeline.acquisitions.spell.hooks")

TestSpellAcquisitions = {}

function TestSpellAcquisitions.testCreatedHexTreesDoNotSharePendingScopes()
    local definition = require("mods.spells.hex_tree")
    local first, second = definition.create(), definition.create()
    local firstCallbacks, secondCallbacks = {}, {}
    first.attach({ hooks = { wrap = function(name, _, callback) firstCallbacks[name] = callback end } })
    second.attach({ hooks = { wrap = function(name, _, callback) secondCallbacks[name] = callback end } })
    local mismatches = {}
    local scope = first.prepare({
        layoutKey = "FirstLayout", rareTalentKeys = {}, epicTalentKeys = {},
    }, function(checkpoint) mismatches[#mismatches + 1] = checkpoint end)
    lu.assertEquals(secondCallbacks.CreateTalentTree(nil, {}, function() return "native" end, {}), "native")
    first.clear(scope)
    lu.assertEquals(mismatches, { "hex-tree-contact" })
    lu.assertNotNil(firstCallbacks.CreateTalentTree)
end

local function capture(state, payload, treeAdapter, spellAdapter)
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback)
        local prior = callbacks[name]
        callbacks[name] = function(_, runtime, base, ...)
            return callback(nil, runtime, function(...)
                if prior then return prior(nil, runtime, base, ...) end
                return base(...)
            end, ...)
        end
    end } }
    local completed, mismatches = {}, {}
    local handle = {}
    local room = {
        current = function() return { id = "room" } end,
        bound = function(_, _, item) return item and handle or nil end,
        peek = function() return payload end,
        begin = function() return true end,
        claimReady = function() return nil end,
    }
    local session = {
        complete = function(_, value) completed[#completed + 1] = value end,
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = { checkpoint, expected, observed }
        end,
    }
    treeAdapter = treeAdapter or tree
    spellAdapter = spellAdapter or spell
    treeAdapter.attach(module)
    spellAdapter.attach(module, session, function() return state end, function() end, room, treeAdapter)
    return callbacks, completed, mismatches
end

function TestSpellAcquisitions.testFreshImportedSpellAdapterUsesTheProvidedHexTree()
    local prior = _G.SpellData
    _G.SpellData = {
        SpellOne = { TraitName = "SpellOneTrait" }, SpellTwo = { TraitName = "SpellTwoTrait" },
        SpellThree = { TraitName = "SpellThreeTrait" }, Other = { TraitName = "OtherTrait" },
    }
    for selected = 1, 3 do
        local state = { state = "synchronized" }
        local payload = { detail = { traitOffer = {
            kind = "traits", giver = "SpellDrop", selected = "option-" .. selected,
            options = {
                { key = "SpellOneTrait" }, { key = "SpellTwoTrait" }, { key = "SpellThreeTrait" },
            },
            hexTree = { layoutKey = "Lung", rareTalentKeys = { "Rare" }, epicTalentKeys = { "Epic" } },
        } } }
        local freshTree = assert(loadfile("src/mods/spells/hex_tree.lua"))().create()
        local freshSpell = assert(loadfile("src/mods/room/timeline/acquisitions/spell/hooks.lua"))()
        local callbacks, completed, mismatches = capture(state, payload, freshTree, freshSpell)
        local item, screen = { Name = "SpellDrop" }, nil
        local pregenerated = callbacks.PregenerateSpells(nil, nil, function()
            local values, rows = { "Other", "SpellThree", "SpellOne", "SpellTwo" }, {}
            for index = 1, 3 do
                rows[index] = callbacks.RemoveRandomValue(nil, nil,
                    function(pool) return table.remove(pool, 1) end, values)
            end
            return rows
        end, item)
        lu.assertEquals(pregenerated, { "SpellOne", "SpellTwo", "SpellThree" })
        local installed, bonus
        callbacks.OpenSpellScreen(nil, nil, function(source)
            screen = { Source = source, Components = {} }
            callbacks.CreateSpellButtons(nil, nil, function(value)
                for index = 1, 3 do
                    local name = callbacks.RemoveRandomValue(nil, nil,
                        function(values) return table.remove(values, 1) end,
                        { "Other", "SpellThree", "SpellOne", "SpellTwo" })
                    value.Components[index] = {
                        TraitName = _G.SpellData[name].TraitName, BonusTalentPoints = index - 1,
                    }
                end
            end, screen)
            callbacks.AcceptAndCloseSpellScreen(nil, nil, function(_, button)
                installed, bonus = button.TraitName, button.BonusTalentPoints
                return callbacks.CreateTalentTree(nil, nil, function()
                    local rare = callbacks.RemoveRandomValue(nil, nil,
                        function(values) return table.remove(values, 1) end, { "Rare" })
                    local epic = callbacks.RemoveRandomValue(nil, nil,
                        function(values) return table.remove(values, 1) end, { "Epic" })
                    return { Name = "Lung", { { Name = rare }, { Name = epic } } }
                end, {})
            end, screen, screen.Components[selected])
        end, item, {}, nil)
        lu.assertEquals(installed, payload.detail.traitOffer.options[selected].key)
        lu.assertEquals(bonus, selected - 1)
        lu.assertEquals(#completed, 1)
        lu.assertEquals(mismatches, {})
    end
    _G.SpellData = prior
end

function TestSpellAcquisitions.testOpenReturnWithoutSelectionReportsAndClearsTheScope()
    local prior = _G.SpellData
    _G.SpellData = { SpellOne = { TraitName = "SpellOneTrait" } }
    local payload = { detail = { traitOffer = {
        kind = "traits", giver = "SpellDrop", selected = "option1",
        options = { { key = "SpellOneTrait" }, { key = "SpellTwoTrait" }, { key = "SpellThreeTrait" } },
        hexTree = { layoutKey = "Lung", rareTalentKeys = {}, epicTalentKeys = {} },
    } } }
    local callbacks, completed, mismatches = capture({ state = "synchronized" }, payload)
    local item = { Name = "SpellDrop" }
    callbacks.OpenSpellScreen(nil, nil, function() return "native-return" end, item, {}, nil)
    lu.assertEquals(completed, {})
    lu.assertEquals(mismatches, { { "spell-selection-terminal", "AcceptAndCloseSpellScreen", "missing" } })
    local delegated = false
    callbacks.OpenSpellScreen(nil, nil, function() delegated = true end, item, {}, nil)
    lu.assertTrue(delegated)
    _G.SpellData = prior
end

function TestSpellAcquisitions.testAspectRoutedSpellDropPassesThroughWithoutAnOffer()
    local callbacks, completed = capture({ state = "synchronized" }, { detail = {} })
    local called = false
    callbacks.OpenSpellScreen(nil, nil, function() called = true end, { Name = "SpellDrop" }, {}, nil)
    lu.assertTrue(called)
    lu.assertEquals(completed, {})
end
