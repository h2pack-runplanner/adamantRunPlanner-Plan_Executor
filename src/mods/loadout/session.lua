local native = type(import) == "function" and import("mods/loadout/native.lua") or require("mods.loadout.native")
local session = {}

local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not same(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function keys(values)
    local result = {}
    for key, value in pairs(values or {}) do
        if type(key) == "number" and type(value) == "string" then result[value] = true
        elseif value == true or type(value) == "table" then result[key] = true end
    end
    return result
end

local function sameSet(expected, observed)
    if #expected ~= #observed then return false end
    local byKey = {}
    for _, row in ipairs(observed) do byKey[row.key] = row end
    for _, row in ipairs(expected) do
        local actual = byKey[row.key]
        if actual == nil or actual.rarity ~= row.rarity or actual.origin ~= row.origin then return false end
    end
    return true
end

local function sameKeys(expected, observed)
    if #expected ~= #observed then return false end
    local found = keys(observed)
    for _, key in ipairs(expected) do if not found[key] then return false end end
    return true
end

function session.verifyPreStart(state, mismatch)
    local expected = state.plan and state.plan.startingLoadout
    if not expected then return mismatch(state, "starting-loadout", "published loadout", nil) end
    local observed = native.readLoadout()
    if observed.weaponKey ~= expected.weaponKey then return mismatch(state, "starting-weapon", expected.weaponKey, observed.weaponKey) end
    if observed.aspectKey ~= expected.aspectKey then return mismatch(state, "starting-aspect", expected.aspectKey, observed.aspectKey) end
    local configuredArcana = native.activeArcana()
    local expectedManual, observedManual = {}, {}
    for _, row in ipairs(expected.arcana) do if row.origin == "manual" then expectedManual[#expectedManual + 1] = row end end
    for _, row in ipairs(configuredArcana) do if row.origin == "manual" then observedManual[#observedManual + 1] = row end end
    if not sameSet(expectedManual, observedManual) then return mismatch(state, "starting-arcana", expectedManual, observedManual) end
    local startingKeepsake = state.plan.startingKeepsake.keepsakeKey
    if ((_G.GameState or {}).LastAwardTrait or (_G.GameState or {}).EquippedKeepsake) ~= startingKeepsake then
        return mismatch(state, "starting-keepsake", startingKeepsake, (_G.GameState or {}).LastAwardTrait)
    end
    if not same(expected.fear.configuredRanks, native.configuredFearRanks(expected.fear.configuredRanks)) then
        return mismatch(state, "starting-fear", expected.fear.configuredRanks, native.configuredFearRanks(expected.fear.configuredRanks))
    end
    return true
end

function session.verifyPostStart(state, mismatch)
    local expected = state.plan and state.plan.startingLoadout
    if not expected then return false end
    if not native.hasTrait(expected.aspectKey) then return mismatch(state, "starting-aspect", expected.aspectKey, nil) end
    local observedArcana = native.activeArcana()
    if not sameSet(expected.arcana, observedArcana) then return mismatch(state, "starting-arcana", expected.arcana, observedArcana) end
    local effective = native.fearRanks(expected.fear.effectiveRanks)
    if not same(expected.fear.effectiveRanks, effective) then return mismatch(state, "effective-fear", expected.fear.effectiveRanks, effective) end
    if expected.startingHex then
        if not native.hasTrait(expected.startingHex.spellTraitKey) then
            return mismatch(state, "starting-hex-spell", expected.startingHex.spellTraitKey, nil)
        end
        if native.treeLayoutKey() ~= expected.startingHex.layoutKey then
            return mismatch(state, "starting-hex-layout", expected.startingHex.layoutKey, native.treeLayoutKey())
        end
        local special = native.treeSpecialTalentKeys()
        if not sameKeys(expected.startingHex.rareTalentKeys, special.rare)
            or not sameKeys(expected.startingHex.epicTalentKeys, special.epic) then
            return mismatch(state, "starting-hex-tree", expected.startingHex, special)
        end
        if expected.startingHex.godSent then
            if not sameKeys({ expected.startingHex.godSent.olympianTalentKey, expected.startingHex.godSent.lineageTalentKey }, special.godSent) then
                return mismatch(state, "starting-hex-god-sent", expected.startingHex.godSent, special.godSent)
            end
        elseif #special.godSent ~= 0 then
            return mismatch(state, "starting-hex-god-sent", nil, special.godSent)
        end
    end
    return true
end

function session.beginKeepsake(state, key, mismatch)
    local expected = state.plan and state.plan.startingKeepsake
    if not expected then return nil end
    if key ~= expected.keepsakeKey then return mismatch(state, "starting-keepsake", expected.keepsakeKey, key) end
    state.startingLoadout = state.startingLoadout or {}
    state.startingLoadout.keepsake = { active = true, expected = expected, results = {} }
    return expected
end

function session.recordKeepsakeResult(state, kind, value)
    local pending = state.startingLoadout and state.startingLoadout.keepsake
    if pending and pending.active then pending.results[kind] = value end
end

function session.finishKeepsake(state, mismatch)
    local pending = state.startingLoadout and state.startingLoadout.keepsake
    if not pending or not pending.active then return mismatch(state, "starting-keepsake", "EquipKeepsake contact", nil) end
    for kind, expected in pairs(pending.expected.equipResults or {}) do
        local actual = pending.results[kind]
        local matches = same(expected, actual)
        if kind == "jeweledPom" and expected.runtimeFallbacks then
            matches = false
            if actual ~= nil then for _, fallback in ipairs(expected.runtimeFallbacks) do
            if (actual.traitKey == fallback.preferredKey or actual.traitKey == fallback.fallbackKey)
                and actual.rarity == expected.rarity then matches = true; break end
            end
            end
        end
        if not matches then
            return mismatch(state, "starting-keepsake:" .. kind, expected, pending.results[kind])
        end
    end
    pending.active = false
    return true
end

return session
