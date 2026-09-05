-- Native projection of planner-published keepsake state. Static provenance is
-- copied from the expected row; mutable status and charges are read from the
-- current game run. The room conformance reader owns when this is requested.
local json = type(import) == "function" and import("mods/json.lua") or require("mods/json")
local nativeFacts = type(import) == "function" and import("mods/native_fact_bindings.lua")
    or require("mods/native_fact_bindings")
local conformanceBindings = nativeFacts.conformance

local conformance = {}

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

function conformance.read(run, expected)
    expected = expected or {}
    local result = {
        olympianSources = {}, jeweledPom = json.null, experimentalHammers = {},
        callingCard = json.null, timePiece = json.null, figLeaf = json.null,
        gorgon = json.null, phial = json.null, figurine = json.null,
        stone = json.null, transcendentEmbryo = json.null,
    }
    for _, source in ipairs(expected.olympianSources or {}) do
        local trait = findTrait(run, source.keepsakeKey)
        local rarityUpgrade = type(trait) == "table" and trait.RarityUpgradeData or nil
        result.olympianSources[#result.olympianSources + 1] = {
            keepsakeKey = source.keepsakeKey,
            providerKey = source.providerKey,
            origin = source.origin,
            acquisitionOrder = source.acquisitionOrder,
            remainingForceUses = type(trait) == "table" and (trait.Uses or 0) > 0 and 1 or 0,
            remainingRarificationUses = type(rarityUpgrade) == "table"
                and (rarityUpgrade.Uses or 0) > 0 and 1 or 0,
            maximumSourceRarityLevel = source.maximumSourceRarityLevel,
        }
    end
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
    if expected.figLeaf ~= nil and not json.isNull(expected.figLeaf) then
        local figLeafKey = conformanceBindings.keepsakeTraits.figLeaf
        local remainingUses, activatedThisBiome = 0, false
        for _, trait in pairs(traits(run) or {}) do
            if traitKey(trait) == figLeafKey and type(trait) == "table" then
                local uses = type(trait.RemainingUses) == "number" and trait.RemainingUses or 0
                remainingUses = math.max(remainingUses, uses)
                activatedThisBiome = activatedThisBiome or trait.ActivatedThisBiome == true
            end
        end
        local currentRoom = type(run) == "table" and run.CurrentRoom or nil
        local roomTraitUses = type(currentRoom) == "table" and currentRoom.TraitUses or nil
        if type(roomTraitUses) == "table" and type(roomTraitUses[figLeafKey]) == "number"
            and roomTraitUses[figLeafKey] > 0 then
            activatedThisBiome = true
        end
        result.figLeaf = {
            remainingUses = remainingUses,
            activatedThisBiome = activatedThisBiome,
        }
    end
    if expected.gorgon ~= nil and not json.isNull(expected.gorgon) then
        local trait = findTrait(run, conformanceBindings.keepsakeTraits.gorgon)
        local expiredKeepsakes = type(run) == "table" and run.ExpiredKeepsakes or nil
        local consumed = type(expiredKeepsakes) == "table"
            and expiredKeepsakes[conformanceBindings.keepsakeTraits.gorgon] == true
        if type(trait) == "table" and type(trait.RemainingUses) == "number"
            and trait.RemainingUses <= 0 then
            consumed = true
        end
        if consumed then
            result.gorgon = { status = "consumed" }
        elseif type(trait) == "table" and trait.Slot == "Keepsake"
            and type(trait.RemainingUses) == "number" and trait.RemainingUses > 0 then
            result.gorgon = { status = "pending", rarity = trait.Rarity }
        else
            result.gorgon = { status = "expired" }
        end
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

return conformance
