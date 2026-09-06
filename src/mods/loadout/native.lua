-- Bounded native readers and tree contact. They observe player configuration;
-- loadout policy lives in session.lua, never in these game-facing reads.
local native = {}

function native.readLoadout()
    local gameState = _G.GameState or {}
    local weaponKey = _G.GetEquippedWeapon()
    local aspectKey = weaponKey and type(gameState.LastWeaponUpgradeName) == "table"
        and gameState.LastWeaponUpgradeName[weaponKey] or nil
    return {
        weaponKey = weaponKey,
        aspectKey = aspectKey,
        arcana = gameState.MetaUpgradeState or {},
        fear = gameState.ShrineUpgrades or gameState.ShrineUpgradeState or {},
    }
end

function native.activeArcana()
    local order = _G.TraitRarityData and _G.TraitRarityData.RarityUpgradeOrder or {}
    local active = {}
    local cards = (_G.MetaUpgradeCardData or {})
    for key, state in pairs((_G.GameState and _G.GameState.MetaUpgradeState) or {}) do
        if type(state) == "table" and state.Equipped == true then
            local card = cards[key] or {}
            active[#active + 1] = {
                key = key,
                origin = type(card.AutoEquipRequirements) == "table" and "automatic" or "manual",
                rarity = order[state.Level or 1] or "Common",
            }
        end
    end
    return active
end

function native.configuredFearRanks(expected)
    local configured, source = {}, (_G.GameState or {}).ShrineUpgrades or {}
    for key in pairs(expected or {}) do configured[key] = tonumber(source[key]) or 0 end
    return configured
end

function native.fearRanks(expected)
    local ranks = {}
    for key in pairs(expected or {}) do
        ranks[key] = _G.GetNumShrineUpgrades(key)
    end
    return ranks
end

function native.hasTrait(key)
    local traits = _G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.TraitDictionary or {}
    return traits[key] ~= nil
end

function native.treeTalentKeys()
    local talents = _G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.SlottedSpell
        and _G.CurrentRun.Hero.SlottedSpell.Talents or {}
    local keys = {}
    for _, depth in pairs(talents) do
        if type(depth) == "table" then
            for _, node in pairs(depth) do
                if type(node) == "table" and node.Name then keys[#keys + 1] = node.Name end
            end
        end
    end
    return keys
end

function native.treeLayoutKey()
    local spell = _G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.SlottedSpell
    return spell and spell.Talents and spell.Talents.Name or nil
end

function native.treeSpecialTalentKeys()
    local spell = _G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.SlottedSpell
    local data = spell and _G.SpellData and _G.SpellData[spell.Name] or {}
    local talents, traits = data.Talents or {}, _G.TraitData or {}
    local rare, epic, godSent = {}, {}, {}
    local unique, legendary = {}, {}
    for _, key in pairs(talents.Unique or {}) do unique[key] = true end
    for _, key in pairs(talents.Legendary or {}) do legendary[key] = true end
    for _, key in ipairs(native.treeTalentKeys()) do
        if unique[key] then rare[#rare + 1] = key
        elseif legendary[key] and traits[key] and traits[key].IsDuoBoon then godSent[#godSent + 1] = key
        elseif legendary[key] then epic[#epic + 1] = key
        elseif key == "OlympianSpellCountTalent" then godSent[#godSent + 1] = key end
    end
    return { rare = rare, epic = epic, godSent = godSent }
end

return native
