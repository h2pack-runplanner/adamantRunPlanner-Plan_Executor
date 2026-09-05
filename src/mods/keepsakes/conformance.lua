-- Native projection of planner-published keepsake state. Static provenance is
-- copied from the expected row; mutable status and charges are read from the
-- current game run. The room conformance reader owns when this is requested.
local json = type(import) == "function" and import("mods/json.lua") or require("mods/json")
local chaos = type(import) == "function" and import("mods/traits/chaos.lua") or require("mods.traits.chaos")
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local conformanceBindings = nativeBindings.conformance

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

local function findGrantedTrait(run)
    for _, trait in pairs(traits(run) or {}) do
        if type(trait) == "table" and trait.GrantedTrait == true then return trait end
    end
    return nil
end

local function activeExperimentalHammers(run, expected)
    local byKey = {}
    for _, trait in pairs(traits(run) or {}) do
        local key = traitKey(trait)
        if type(trait) == "table" and trait.IsHammerTrait == true and trait.UsesAsEncounters
            and type(trait.RemainingUses) == "number" and trait.RemainingUses > 0 then
            byKey[key] = byKey[key] or {}
            byKey[key][#byKey[key] + 1] = trait
        end
    end
    local result = {}
    -- A native temporary Hammer has no acquisition identity. Match live
    -- instances to the newest same-key planner rows; older absent rows are the
    -- expired acquisitions retained only for provenance.
    for index = #(expected or {}), 1, -1 do
        local row = expected[index]
        local candidates = byKey[row.traitKey]
        local trait = candidates and table.remove(candidates) or nil
        result[index] = {
            traitKey = row.traitKey,
            remainingUses = trait and trait.RemainingUses or 0,
            acquisitionIdentity = row.acquisitionIdentity,
            active = trait ~= nil,
        }
    end
    -- Native Hammer traits have no planner acquisition identity. Surplus live
    -- instances still need to remain visible so equality rejects the state.
    local extraKeys = {}
    for key, candidates in pairs(byKey) do
        if #candidates > 0 then extraKeys[#extraKeys + 1] = key end
    end
    table.sort(extraKeys)
    for _, key in ipairs(extraKeys) do
        local candidates = byKey[key]
        for nativeIndex, trait in ipairs(candidates) do
            result[#result + 1] = {
                traitKey = key,
                remainingUses = trait.RemainingUses,
                acquisitionIdentity = "native-unmatched:" .. key .. ":" .. nativeIndex,
                active = true,
            }
        end
    end
    return result
end

function conformance.read(run, gameState, expected)
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
    if expected.jeweledPom ~= nil and not json.isNull(expected.jeweledPom) then
        local trait = findTrait(run, conformanceBindings.keepsakeTraits.jeweledPom)
        local active = type(gameState) == "table" and gameState.FatedStatus == "Fated"
        local granted = active and findGrantedTrait(run) or nil
        result.jeweledPom = {
            -- While active, the granted trait is mutable native state. Once
            -- Fated cleanup has removed it, the key is retained provenance.
            grantedTraitKey = active and (traitKey(granted) or "")
                or expected.jeweledPom.grantedTraitKey,
            active = active,
            levels = type(trait) == "table" and (trait.FatedBoonLevelBonus or 0) or 0,
            acquisitionIdentity = expected.jeweledPom.acquisitionIdentity,
        }
    end
    result.experimentalHammers = activeExperimentalHammers(run, expected.experimentalHammers)
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
    if expected.phial ~= nil and not json.isNull(expected.phial) then
        local key = conformanceBindings.keepsakeTraits.phial
        local trait = findTrait(run, key)
        local pending = type(trait) == "table" and type(trait.Uses) == "number" and trait.Uses > 0
        result.phial = { status = pending and "pending" or "consumed" }
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
    if expected.stone ~= nil and not json.isNull(expected.stone) then
        local key = conformanceBindings.keepsakeTraits.stone
        local trait = findTrait(run, key)
        local pending = type(trait) == "table" and type(trait.Uses) == "number" and trait.Uses > 0
        result.stone = {
            origin = expected.stone.origin,
            status = pending and "pending" or "consumed",
            rank = type(trait) == "table" and trait.Rarity or nil,
        }
    end
    if expected.transcendentEmbryo ~= nil and not json.isNull(expected.transcendentEmbryo) then
        local source = findTrait(run, conformanceBindings.keepsakeTraits.transcendentEmbryo)
        local blessing
        for _, trait in pairs(traits(run) or {}) do
            if type(trait) == "table" and trait.FromChaosKeepsake then blessing = trait; break end
        end
        result.transcendentEmbryo = {
            origin = expected.transcendentEmbryo.origin,
            rarity = type(source) == "table" and source.Rarity or nil,
            progress = type(source) == "table" and (source.CurrentRoom or 0) or 0,
            markedBlessingKey = blessing and traitKey(blessing) or "",
            markedBlessingValues = blessing and chaos.blessingValues(blessing, traitKey(blessing)) or {},
            markedBlessingAcquisitionIdentity =
                expected.transcendentEmbryo.markedBlessingAcquisitionIdentity,
        }
    end
    return result
end

return conformance
