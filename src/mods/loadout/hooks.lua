-- Run-start and keepsake native contacts.  Room hooks are deliberately absent.
local hooks = {}

local function traitKey(value) return type(value) == "table" and (value.Name or value.TraitName) or value end

function hooks.attach(module, data, getState, report)
    local adapter = import("mods/native_timeline_adapters.lua")
    local nativeFacts = import("mods/native_fact_bindings.lua")
    local startDepth, equipScope, hexScope, treeScope = 0, nil, nil, nil

    local function enforcing(runtime)
        local state = getState(runtime)
        return state ~= nil and (state.state == "synchronized" or (startDepth > 0 and state.state == "starting"))
    end

    local function selectedResult(kind, result)
        if kind == "experimentalHammer" then
            local key = traitKey(result)
            return key and { kind = "selected", traitKey = key } or { kind = "exhausted" }
        end
        if kind == "jeweledPom" then
            return { traitKey = traitKey(result), rarity = type(result) == "table" and result.Rarity or nil }
        end
        return { blessingKey = traitKey(result) }
    end
    local function traitWithKey(key)
        for _, trait in pairs((_G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.Traits) or {}) do
            if traitKey(trait) == key then return trait end
        end
    end
    local function traitSnapshot()
        local result = {}
        for _, trait in pairs((_G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.Traits) or {}) do
            result[traitKey(trait)] = true
        end
        return result
    end
    local function newlyAddedTrait(before)
        for _, trait in pairs((_G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.Traits) or {}) do
            if not before[traitKey(trait)] then return trait end
        end
    end
    local function recordEquipResult(runtime, kind, result)
        if equipScope == nil or equipScope.expected[kind] == nil then return end
        local observed = selectedResult(kind, result)
        equipScope.observed[kind] = observed
        if startDepth > 0 then
            local state = getState(runtime)
            data.loadout.recordKeepsakeResult(state, kind, observed)
        end
    end
    local function expectedEquip(state, keepsakeKey)
        if startDepth > 0 then return state.plan and state.plan.startingKeepsake.equipResults end
        local current = data.session.current(state)
        local row = current and adapter.lookup(current.bindings, "keepsake", keepsakeKey)
        return row and row.node.equipResults, row
    end
    local function wrapEquipResult(functionName, hookId, kind)
        module.hooks.wrap(functionName, hookId, function(_, runtime, base, ...)
            if not enforcing(runtime) then return base(...) end
            local expected = equipScope and equipScope.expected and equipScope.expected[kind]
            if expected == nil then return base(...) end
            local priorKind = equipScope.kind
            equipScope.kind = kind
            local ok, result = pcall(base, ...)
            equipScope.kind = priorKind
            if not ok then error(result, 0) end
            if kind == "jeweledPom" then
                local observed = traitWithKey(equipScope and equipScope.selectedKey)
                    or newlyAddedTrait(equipScope and equipScope.traitsBefore or {})
                recordEquipResult(runtime, kind, observed)
            end
            return result
        end)
    end
    wrapEquipResult(nativeFacts.keepsakeEquipContacts.experimentalHammer, "execution-v11-equip-hammer", "experimentalHammer")
    wrapEquipResult(nativeFacts.keepsakeEquipContacts.jeweledPom, "execution-v11-equip-pom", "jeweledPom")
    wrapEquipResult(nativeFacts.keepsakeEquipContacts.transcendentEmbryo, "execution-v11-equip-embryo", "transcendentEmbryo")
    module.hooks.wrap("AddRandomHammer", "execution-v11-equip-hammer-result", function(_, runtime, base, args)
        local result = base(args); recordEquipResult(runtime, "experimentalHammer", result); return result
    end)
    module.hooks.wrap("AddRandomChaosBlessing", "execution-v11-equip-embryo-result", function(_, runtime, base, rarity)
        local result = base(rarity); recordEquipResult(runtime, "transcendentEmbryo", result); return result
    end)
    module.hooks.wrap("GetRandomArrayValue", "execution-v11-equip-selection", function(_, runtime, base, values, rng)
        if not enforcing(runtime) then return base(values, rng) end
        local expected = equipScope and equipScope.kind and equipScope.expected[equipScope.kind]
        local key = expected and (expected.traitKey or expected.blessingKey)
        if expected and expected.runtimeFallbacks and expected.runtimeFallbacks[1] then
            local fallback = expected.runtimeFallbacks[1]
            local function available(candidate)
                local declaration = _G.TraitData and _G.TraitData[candidate]
                return declaration ~= nil and (type(_G.IsTraitEligible) ~= "function" or _G.IsTraitEligible(declaration) == true)
            end
            key = available(fallback.preferredKey) and fallback.preferredKey
                or available(fallback.fallbackKey) and fallback.fallbackKey or nil
            if key == nil then
                if startDepth > 0 then return base(values, rng) end
                data.session.mismatch(getState(runtime), "availability:traitEligibility", fallback, "neither")
                return base(values, rng)
            end
        end
        if key and type(values) == "table" then
            for _, value in ipairs(values) do if traitKey(value) == key then equipScope.selectedKey = key; return value end end
            if startDepth > 0 then return base(values, rng) end
            data.session.mismatch(getState(runtime), "availability:traitEligibility", key, "missing candidate")
            return base(values, rng)
        end
        return base(values, rng)
    end)
    module.hooks.wrap("CreateTalentTree", "execution-v11-selene-tree", function(_, runtime, base, spellData)
        if not enforcing(runtime) then return base(spellData) end
        local prior = treeScope
        treeScope = hexScope
        local ok, tree = pcall(base, spellData)
        treeScope = prior
        if not ok then error(tree, 0) end
        return tree
    end)
    module.hooks.wrap("GetRandomValue", "execution-v11-selene-layout", function(_, runtime, base, values, ...)
        if not enforcing(runtime) then return base(values, ...) end
        if treeScope and type(values) == "table" then
            for _, value in ipairs(values) do if type(value) == "table" and value.Name == treeScope.layoutKey then return value end end
        end
        return base(values, ...)
    end)
    module.hooks.wrap("RemoveRandomValue", "execution-v11-selene-god-sent", function(_, runtime, base, values, ...)
        if not enforcing(runtime) then return base(values, ...) end
        if treeScope and type(values) == "table" then
            local candidates = {}
            for _, key in ipairs(treeScope.rareTalentKeys) do candidates[#candidates + 1] = key end
            for _, key in ipairs(treeScope.epicTalentKeys) do candidates[#candidates + 1] = key end
            if treeScope.godSent then candidates[#candidates + 1] = treeScope.godSent.olympianTalentKey end
            for _, expected in ipairs(candidates) do
                for index, value in ipairs(values) do
                    if value == expected then return table.remove(values, index) end
                end
            end
        end
        return base(values, ...)
    end)
    module.hooks.wrap("StartNewRun", "execution-v11-start", function(_, runtime, base, previousRun, args)
        startDepth = startDepth + 1
        local ok, result = pcall(base, previousRun, args)
        startDepth, hexScope = startDepth - 1, nil
        if not ok then error(result, 0) end
        local state = getState(runtime)
        if state ~= nil and state.state == "starting" then
            data.loadout.verifyCompleted(state, data.session.mismatch)
        end
        report(runtime)
        return result
    end)
    module.hooks.wrap("CreateNewHero", "execution-v11-session-start", function(_, runtime, base, previousRun, args)
        if startDepth <= 0 then return base(previousRun, args) end
        local state = getState(runtime)
        if not state.initialized then data.session.start(state, data.inbox, "starting") end
        if state.state == "starting" then
            local expected = state.plan and state.plan.startingLoadout
            hexScope = expected and expected.startingHex or nil
        end
        local ok, result = pcall(base, previousRun, args)
        if not ok then error(result, 0) end
        return result
    end)
    module.hooks.wrap("EquipKeepsake", "execution-v11-equip-keepsake", function(_, runtime, base, hero, keepsakeKey, args)
        local state = getState(runtime)
        if state == nil then return base(hero, keepsakeKey, args) end
        local key = keepsakeKey or (_G.GameState and _G.GameState.LastAwardTrait)
        if startDepth > 0 then
            local expectedStarting = data.loadout.beginKeepsake(state, key)
            if expectedStarting == nil then
                local result = base(hero, keepsakeKey, args)
                report(runtime)
                return result
            end
            if state.state ~= "starting" then
                local result = base(hero, keepsakeKey, args)
                report(runtime)
                return result
            end
        end
        local expected, row = expectedEquip(state, key)
        local prior = equipScope
        equipScope = {
            expected = expected or {}, observed = {}, row = row, key = key,
            traitsBefore = traitSnapshot(),
        }
        local ok, result = pcall(base, hero, keepsakeKey, args)
        local completed = equipScope; equipScope = prior
        if not ok then error(result, 0) end
        if startDepth == 0 and row ~= nil then
            data.session.complete(state, row, adapter.verifyKeepsake(row, key, completed.observed), row.node, key)
        end
        report(runtime); return result
    end)
end

return hooks
