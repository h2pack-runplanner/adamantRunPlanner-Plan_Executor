local native = type(import) == "function" and import("mods/loadout/native.lua") or require("mods.loadout.native")
local session = {}

local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) == "number" then return math.abs(left - right) < 0.0000001 end
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

function session.verifyCompleted(state, mismatch)
    local expected = state.plan and state.plan.startingLoadout
    if not expected then return mismatch(state, "starting-loadout", "published loadout", nil) end
    local observedLoadout = native.readLoadout()
    if observedLoadout.weaponKey ~= expected.weaponKey then
        return mismatch(state, "starting-weapon", expected.weaponKey, observedLoadout.weaponKey)
    end
    if observedLoadout.aspectKey ~= expected.aspectKey or not native.hasTrait(expected.aspectKey) then
        return mismatch(state, "starting-aspect", expected.aspectKey, observedLoadout.aspectKey)
    end
    local observedArcana = native.activeArcana()
    if not sameSet(expected.arcana, observedArcana) then return mismatch(state, "starting-arcana", expected.arcana, observedArcana) end
    local configured = native.configuredFearRanks(expected.fear.configuredRanks)
    if not same(expected.fear.configuredRanks, configured) then
        return mismatch(state, "starting-fear", expected.fear.configuredRanks, configured)
    end
    local effective = native.fearRanks(expected.fear.effectiveRanks)
    if not same(expected.fear.effectiveRanks, effective) then return mismatch(state, "effective-fear", expected.fear.effectiveRanks, effective) end
    local startingKeepsake = state.plan.startingKeepsake.keepsakeKey
    local observedKeepsake = (_G.GameState or {}).LastAwardTrait or (_G.GameState or {}).EquippedKeepsake
    if observedKeepsake ~= startingKeepsake then
        return mismatch(state, "starting-keepsake", startingKeepsake, observedKeepsake)
    end
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
    state.state, state.reason = "synchronized", "ready"
    return true
end

function session.beginKeepsake(state, key)
    local expected = state.plan and state.plan.startingKeepsake
    if not expected then return nil end
    -- Startup validation is deliberately deferred until native StartNewRun
    -- returns. A wrong carrier must not desynchronize the provisional session
    -- or suppress the other native startup contacts. Equip-result effects are
    -- steered at their native contacts and are not re-proved here.
    if key ~= expected.keepsakeKey then return nil end
    return expected
end

return session
