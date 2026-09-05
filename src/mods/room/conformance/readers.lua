-- Source-backed F/G room-exit readers. These functions project native run
-- ownership into the already-decoded expected shape; they do not reconstruct
-- planner chronology or action provenance.
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods/chaos")
local nativeFacts = type(import) == "function" and import("mods/native_fact_bindings.lua")
    or require("mods/native_fact_bindings")
local conformanceBindings = nativeFacts.conformance
local keepsakeConformance = type(import) == "function" and import("mods/keepsakes/conformance.lua")
    or require("mods.keepsakes.conformance")
local readers = {}
local supported = {
    steadyGrowth = true, chaos = true, keepsakeEffects = true,
    rewardPriorities = true, pathOfStars = true, forfeit = true, stygianWell = true,
}

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

local function pathOfStars(run, expected)
    local hero = type(run) == "table" and run.Hero or nil
    local spell = type(hero) == "table" and hero.SlottedSpell or nil
    local talents = type(spell) == "table" and spell.Talents or nil
    local nativeTalentKeys = {}
    local expectedKeys = type(expected) == "table" and expected.talentKeys or nil
    local expectedSet = {}
    for _, key in ipairs(expectedKeys or {}) do expectedSet[key] = true end
    local function collect(node)
        if type(node) ~= "table" then return end
        if type(node.Name) == "string" and node.Name ~= talents.Name
            and (expectedSet[node.Name] or node.Rarity == "Rare" or node.Rarity == "Epic"
                or node.Rarity == "Duo") then
            nativeTalentKeys[node.Name] = true
        end
        for _, child in ipairs(node) do collect(child) end
    end
    collect(talents)
    -- The planner intentionally projects only frozen Rare/Epic/God Sent
    -- identities. Reconstruct that canonical published order from native
    -- presence, then retain unexpected high-value nodes as evidence instead
    -- of leaking unmodeled common/repeatable talents into conformance.
    local talentKeys, emitted = {}, {}
    for _, key in ipairs(expectedKeys or {}) do
        if nativeTalentKeys[key] then
            talentKeys[#talentKeys + 1] = key
            emitted[key] = true
        end
    end
    local unexpected = {}
    for key in pairs(nativeTalentKeys) do
        if not emitted[key] and not expectedSet[key] then unexpected[#unexpected + 1] = key end
    end
    table.sort(unexpected)
    for _, key in ipairs(unexpected) do talentKeys[#talentKeys + 1] = key end
    return {
        -- SpellData.Name is the native spell-table key; planner conformance
        -- publishes the installed trait identity carried by TraitName.
        spellTraitKey = type(spell) == "table" and spell.TraitName or nil,
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

function readers.read(kind, run, gameState, expected)
    if kind == "steadyGrowth" then return steadyGrowth(run, expected) end
    if kind == "chaos" then return activeChaos(run) end
    if kind == "keepsakeEffects" then return keepsakeConformance.read(run, expected) end
    if kind == "rewardPriorities" then return type(run) == "table" and run.RewardPriorities or nil end
    if kind == "pathOfStars" then return pathOfStars(run, expected) end
    if kind == "forfeit" then return forfeit(run) end
    if kind == "stygianWell" then return stygianWell(run) end
    return nil
end

function readers.supports(kind)
    return supported[kind] == true
end

function readers.diagnostic(run)
    return {
        rewardPriorities = type(run) == "table" and run.RewardPriorities or nil,
        bannedTraits = type(run) == "table" and enabledKeys(run.BannedTraits) or {},
        chaos = activeChaos(run), pathOfStars = pathOfStars(run),
    }
end

return readers
