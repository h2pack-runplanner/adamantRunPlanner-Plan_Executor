-- Strict v14 decoder for the bounded run-start contract.
local p = type(import) == "function" and import("mods/protocol_primitives.lua")
    or require("mods/protocol_primitives")

local protocol = {}

local function ranks(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    for key, rank in pairs(record) do
        if type(key) ~= "string" or key == "" or type(rank) ~= "number" or rank < 0 or rank % 1 ~= 0 then
            return p.fail(label .. " has invalid rank")
        end
    end
    return record
end

function protocol.decode(value)
    local record, errorMessage = p.exact(value,
        { "weaponKey", "aspectKey", "arcana", "fear" }, { "startingHex" },
        "execution plan.startingLoadout")
    if not record then return nil, errorMessage end
    if not p.str(record.weaponKey, "execution plan.startingLoadout.weaponKey")
        or not p.str(record.aspectKey, "execution plan.startingLoadout.aspectKey") then
        return p.fail("execution plan has invalid starting loadout")
    end
    if record.aspectKey == "SuitHexAspect" and record.startingHex == nil then
        return p.fail("execution plan.startingHex is required for SuitHexAspect")
    end
    local arcana, arcanaError = p.arr(record.arcana, "execution plan.startingLoadout.arcana")
    if not arcana then return nil, arcanaError end
    local seen = {}
    for index, entry in ipairs(arcana) do
        local row, rowError = p.exact(entry, { "key", "origin", "rarity" }, {},
            "execution plan.startingLoadout.arcana[" .. index .. "]")
        if not row then return nil, rowError end
        if not p.str(row.key, "execution plan.startingLoadout.arcana[" .. index .. "].key")
            or (row.origin ~= "manual" and row.origin ~= "automatic")
            or (row.rarity ~= "Common" and row.rarity ~= "Rare" and row.rarity ~= "Epic" and row.rarity ~= "Heroic")
            or seen[row.key] then
            return p.fail("execution plan has invalid starting Arcana")
        end
        seen[row.key] = true
    end
    local fear, fearError = p.exact(record.fear, { "configuredRanks", "effectiveRanks" }, {},
        "execution plan.startingLoadout.fear")
    if not fear then return nil, fearError end
    local _, configuredError = ranks(fear.configuredRanks, "execution plan.startingLoadout.fear.configuredRanks")
    if configuredError then return nil, configuredError end
    local _, effectiveError = ranks(fear.effectiveRanks, "execution plan.startingLoadout.fear.effectiveRanks")
    if effectiveError then return nil, effectiveError end
    if record.startingHex ~= nil then
        if record.aspectKey ~= "SuitHexAspect" then return p.fail("execution plan.startingHex requires SuitHexAspect") end
        local hex, hexError = p.exact(record.startingHex,
            { "spellTraitKey", "layoutKey", "rareTalentKeys", "epicTalentKeys" }, { "godSent" },
            "execution plan.startingLoadout.startingHex")
        if not hex then return nil, hexError end
        if hex.spellTraitKey ~= "SpellMoonBeamTrait" or not p.str(hex.layoutKey,
                "execution plan.startingLoadout.startingHex.layoutKey") then
            return p.fail("execution plan has invalid starting Hex")
        end
        local rare, rareError = p.strings(hex.rareTalentKeys,
            "execution plan.startingLoadout.startingHex.rareTalentKeys")
        local epic, epicError = p.strings(hex.epicTalentKeys,
            "execution plan.startingLoadout.startingHex.epicTalentKeys")
        if rareError then return nil, rareError end
        if epicError then return nil, epicError end
        local seenNodes = {}
        for _, key in ipairs(rare) do if seenNodes[key] then return p.fail("execution plan has duplicate starting Hex node") end; seenNodes[key] = true end
        for _, key in ipairs(epic) do if seenNodes[key] then return p.fail("execution plan has duplicate starting Hex node") end; seenNodes[key] = true end
        if hex.godSent ~= nil then
            local godSent, godSentError = p.exact(hex.godSent,
                { "olympianTalentKey", "lineageTalentKey" }, {},
                "execution plan.startingLoadout.startingHex.godSent")
            if not godSent then return nil, godSentError end
            if not p.str(godSent.olympianTalentKey, "execution plan.startingLoadout.startingHex.godSent.olympianTalentKey")
                or not p.str(godSent.lineageTalentKey, "execution plan.startingLoadout.startingHex.godSent.lineageTalentKey")
                or godSent.olympianTalentKey == godSent.lineageTalentKey
                or seenNodes[godSent.olympianTalentKey] or seenNodes[godSent.lineageTalentKey] then
                return p.fail("execution plan has invalid starting Hex God Sent")
            end
        end
    end
    return record
end

return protocol
