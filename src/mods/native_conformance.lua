-- Source-backed F/G room-exit readers.  These functions project native run
-- ownership into the already-decoded expected shape; they do not reconstruct
-- planner chronology or action provenance.
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods/chaos")
local json = type(import) == "function" and import("mods/json.lua") or require("mods/json")
local nativeFacts = type(import) == "function" and import("mods/native_fact_bindings.lua")
    or require("mods/native_fact_bindings")
local conformanceBindings = nativeFacts.conformance
local readers = {}

local function traitKey(value)
    return type(value) == "table" and (value.Name or value.TraitName) or value
end

local function traits(run)
    local hero = type(run) == "table" and run.Hero or nil
    return type(hero) == "table" and hero.Traits or nil
end

local function findTrait(run, key)
    for _, trait in pairs(traits(run) or {}) do
        if traitKey(trait) == key then return trait end
    end
    return nil
end

local function enabledKeys(values)
    local result = {}
    for key, enabled in pairs(values or {}) do if enabled then result[#result + 1] = key end end
    table.sort(result)
    return result
end

local function activeChaos(run)
    local active, matured = {}, {}
    for _, trait in pairs(traits(run) or {}) do
        if type(trait) == "table" and type(trait.Name) == "string" then
            if trait.Name:match("^Chaos.*Curse$") then
                local blessing = trait.OnExpire and trait.OnExpire.TraitData
                if type(blessing) == "table" then
                    active[#active + 1] = {
                        curseKey = trait.Name, blessingKey = blessing.Name,
                        rarity = blessing.Rarity, clock = chaos.clock(trait),
                        remaining = trait.RemainingUses,
                    }
                end
            elseif trait.Name:match("^Chaos.*Blessing$") then
                matured[#matured + 1] = { blessingKey = trait.Name, rarity = trait.Rarity }
            end
        end
    end
    return { active = active, matured = matured }
end

local function forfeit(run)
    local rank = type(_G.GetNumShrineUpgrades) == "function"
        and _G.GetNumShrineUpgrades(conformanceBindings.shrineUpgrades.forfeit) or 0
    if type(rank) ~= "number" or rank <= 0 then return "inactive" end
    local count = type(run) == "table" and run.BiomeBoonSkipCount or nil
    if type(count) ~= "number" then return nil end
    return count >= rank and "consumed" or "available"
end

local function pathOfStars(run)
    local hero = type(run) == "table" and run.Hero or nil
    local spell = type(hero) == "table" and hero.SlottedSpell or nil
    local talentKeys = {}
    local talents = type(spell) == "table" and spell.Talents or nil
    local function collect(node)
        if type(node) ~= "table" then return end
        if type(node.Name) == "string" and node.Name ~= talents.Name then talentKeys[#talentKeys + 1] = node.Name end
        for _, child in ipairs(node) do collect(child) end
    end
    collect(talents)
    return {
        spellTraitKey = type(spell) == "table" and spell.Name or nil,
        layoutKey = type(talents) == "table" and talents.Name or nil,
        talentKeys = talentKeys,
        closed = type(run) == "table" and run.AllSpellInvestedCache or false,
        bankedPathPoints = type(run) == "table" and (run.NumTalentPoints or 0) or 0,
        investedPathPoints = type(run) == "table" and (run.InvestedTalentPoints or 0) or 0,
    }
end

local function steadyGrowth(run, expected)
    local result = {}
    for _, row in ipairs(expected or {}) do
        local trait = findTrait(run, row.traitKey)
        result[#result + 1] = {
            traitKey = row.traitKey,
            progress = type(trait) == "table" and (trait.SteadyGrowthProgress or 0) or 0,
            interval = row.interval,
        }
    end
    return result
end

local function remaining(run, key)
    local trait = findTrait(run, key)
    return type(trait) == "table" and (trait.RemainingUses or trait.Uses or 1) or 0
end

local function durationList(run, key)
    local result = {}
    for _, trait in pairs(traits(run) or {}) do
        if traitKey(trait) == key then result[#result + 1] = trait.RemainingUses or 0 end
    end
    table.sort(result)
    return result
end

local function stygianWell(run)
    local keys = conformanceBindings.stygianWellTraits
    return {
        sparkUses = remaining(run, keys.sparkUses),
        yarnUses = remaining(run, keys.yarnUses),
        hymnUses = remaining(run, keys.hymnUses),
        discountUses = durationList(run, keys.discountUses),
        emptySlotUses = durationList(run, keys.emptySlotUses),
        extendedUses = remaining(run, keys.extendedUses),
    }
end

local function keepsakeEffects(run, _gameState, expected)
    -- The wire shape contains static provenance as well as mutable native
    -- state. Build it explicitly: only immutable origin/identity fields use
    -- the decoded declaration, while every charge/status comes from game data.
    expected = expected or {}
    local result = {
        olympianSources = {}, jeweledPom = json.null, experimentalHammers = {},
        callingCard = json.null, timePiece = json.null, figLeaf = json.null,
        gorgon = json.null, phial = json.null, figurine = json.null,
        stone = json.null, transcendentEmbryo = json.null,
    }
    if expected.timePiece ~= nil and not json.isNull(expected.timePiece) then
        local trait = findTrait(run, conformanceBindings.keepsakeTraits.timePiece)
        result.timePiece = {
            remainingCharges = type(trait) == "table" and (trait.BoonConversionUses or 0) or 0,
        }
    end
    if expected.callingCard ~= nil and not json.isNull(expected.callingCard) then
        local trait = findTrait(run, conformanceBindings.keepsakeTraits.callingCard)
        local upgrade = type(trait) == "table" and trait.RarityUpgradeData or nil
        result.callingCard = {
            remainingCharges = type(upgrade) == "table" and (upgrade.Uses or 0) or 0,
        }
    end
    if expected.figurine ~= nil and not json.isNull(expected.figurine) then
        local trait = findTrait(run, conformanceBindings.keepsakeTraits.figurine)
        local temporary = type(run) == "table" and next(run.TemporaryMetaUpgrades or {}) ~= nil
        result.figurine = {
            origin = expected.figurine.origin,
            status = (temporary or (trait and (trait.RemainingUses or 0) == 0))
                and "consumed" or "pending",
            rarity = trait and trait.Rarity or expected.figurine.rarity,
        }
    end
    return result
end

function readers.read(kind, run, gameState, expected)
    if kind == "steadyGrowth" then return steadyGrowth(run, expected) end
    if kind == "chaos" then return activeChaos(run) end
    if kind == "keepsakeEffects" then return keepsakeEffects(run, gameState, expected) end
    if kind == "rewardPriorities" then return type(run) == "table" and run.RewardPriorities or nil end
    if kind == "pathOfStars" then return pathOfStars(run) end
    if kind == "forfeit" then return forfeit(run) end
    if kind == "stygianWell" then return stygianWell(run) end
    return nil
end

function readers.diagnostic(run)
    return {
        rewardPriorities = type(run) == "table" and run.RewardPriorities or nil,
        bannedTraits = type(run) == "table" and enabledKeys(run.BannedTraits) or {},
        chaos = activeChaos(run), pathOfStars = pathOfStars(run),
    }
end

return readers
