-- Protocol-v10 native hook composition. Each hook group owns one concrete
-- native fact family; the route/room coordinator owns only session state.
local logic = {}

local function traitKey(value)
    return type(value) == "table" and (value.Name or value.TraitName) or value
end

function logic.bind(data, root)
    if type(root) ~= "string" or root == "" then error("executor config path is required", 2) end
    local json = import("mods/json.lua")
    local protocol = import("mods/protocol.lua")
    data.inbox = import("mods/inbox.lua").create(root, function(raw)
        local value, errorMessage = json.decode(raw)
        if value == nil then return nil, "malformed-json: " .. tostring(errorMessage) end
        return protocol.decode(value)
    end, rom.path)
    data.session = import("mods/runtime_session.lua")
    return logic
end

function logic.attach(module, data)
    data.session.defineCache(module)
    local adapter = import("mods/native_timeline_adapters.lua")
    local nativeFacts = import("mods/native_fact_bindings.lua")
    local roomHooks = import("mods/hooks_rooms.lua")
    local timelineHooks = import("mods/hooks_timeline.lua")
    local featureHooks = import("mods/hooks_features.lua")
    local startDepth = 0
    local equipScope

    local function getState(runtime) return data.session.get(runtime) end
    local function ensureStarted(_, state)
        if not state.initialized then data.session.start(state, data.inbox) end
        return state.state == "synchronized"
    end
    local function diagnosticValue(value, depth)
        depth = depth or 0
        if depth >= 2 then return "…" end
        if type(value) ~= "table" then return tostring(value) end
        local parts, count = {}, 0
        for key, nested in pairs(value) do
            count = count + 1
            if count > 6 then parts[#parts + 1] = "…"; break end
            parts[#parts + 1] = tostring(key) .. "=" .. diagnosticValue(nested, depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    local function report(runtime)
        local state = getState(runtime)
        if runtime.status and runtime.status.write then
            local status = data.session.status(state)
            runtime.status.write("ExecutionSessionStatus", status.state .. ": " .. status.reason)
        end
        if state.firstMismatch and state.loggedMismatch ~= state.firstMismatch then
            state.loggedMismatch = state.firstMismatch
            if rom and rom.log and rom.log.info then
                local mismatch = state.firstMismatch
                rom.log.info("[RunPlanner] first-mismatch checkpoint="
                    .. tostring(mismatch.checkpoint or mismatch.kind) .. " expected="
                    .. diagnosticValue(mismatch.expected) .. " observed="
                    .. diagnosticValue(mismatch.observed))
            end
        end
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
        return nil
    end

    local function recordEquipResult(runtime, kind, result)
        if equipScope == nil or equipScope.expected[kind] == nil then return end
        local observed = selectedResult(kind, result)
        equipScope.observed[kind] = observed
        if startDepth > 0 then data.session.recordStartingKeepsakeResult(getState(runtime), kind, observed) end
    end

    local function expectedEquip(state, keepsakeKey)
        if startDepth > 0 then
            return state.plan and state.plan.startingKeepsake.equipResults
        end
        local current = data.session.current(state)
        local row = current and adapter.lookup(current.bindings, "keepsake", keepsakeKey)
        return row and row.node.equipResults, row
    end

    local function wrapEquipResult(functionName, hookId, kind)
        module.hooks.wrap(functionName, hookId, function(_, runtime, base, ...)
            local expected = equipScope and equipScope.expected and equipScope.expected[kind]
            if expected == nil then return base(...) end
            equipScope.kind = kind
            local result = base(...)
            if kind == "jeweledPom" then recordEquipResult(runtime, kind, traitWithKey(expected.traitKey)) end
            return result
        end)
    end

    wrapEquipResult(nativeFacts.keepsakeEquipContacts.experimentalHammer,
        "execution-v10-equip-hammer", "experimentalHammer")
    wrapEquipResult(nativeFacts.keepsakeEquipContacts.jeweledPom,
        "execution-v10-equip-pom", "jeweledPom")
    wrapEquipResult(nativeFacts.keepsakeEquipContacts.transcendentEmbryo,
        "execution-v10-equip-embryo", "transcendentEmbryo")

    module.hooks.wrap("AddRandomHammer", "execution-v10-equip-hammer-result", function(_, runtime, base, args)
        local result = base(args)
        recordEquipResult(runtime, "experimentalHammer", result)
        return result
    end)

    module.hooks.wrap("AddRandomChaosBlessing", "execution-v10-equip-embryo-result", function(_, runtime, base, rarity)
        local result = base(rarity)
        recordEquipResult(runtime, "transcendentEmbryo", result)
        return result
    end)

    module.hooks.wrap("GetRandomArrayValue", "execution-v10-equip-selection", function(_, runtime, base, values, rng)
        local expected = equipScope and equipScope.kind and equipScope.expected[equipScope.kind]
        local key = expected and (expected.traitKey or expected.blessingKey)
        if expected and expected.runtimeFallbacks and expected.runtimeFallbacks[1] then
            local fallback = expected.runtimeFallbacks[1]
            local function available(candidate)
                local declaration = _G.TraitData and _G.TraitData[candidate]
                return declaration ~= nil and (type(_G.IsTraitEligible) ~= "function"
                    or _G.IsTraitEligible(declaration) == true)
            end
            key = available(fallback.preferredKey) and fallback.preferredKey
                or available(fallback.fallbackKey) and fallback.fallbackKey or nil
            if key == nil then
                data.session.mismatch(getState(runtime), "availability:traitEligibility", fallback, "neither")
                report(runtime)
            end
        end
        if key and type(values) == "table" then
            for _, value in ipairs(values) do if traitKey(value) == key then return value end end
        end
        return base(values, rng)
    end)

    module.hooks.wrap("StartNewRun", "execution-v10-start", function(_, runtime, base, previousRun, args)
        startDepth = startDepth + 1
        local ok, result = pcall(base, previousRun, args)
        startDepth = startDepth - 1
        if not ok then error(result, 0) end
        local state = getState(runtime)
        if not state.initialized then data.session.start(state, data.inbox) end
        data.session.finishStartingKeepsake(state)
        report(runtime)
        return result
    end)

    module.hooks.wrap("EquipKeepsake", "execution-v10-equip-keepsake", function(_, runtime, base, hero,
        keepsakeKey, args)
        local state = getState(runtime)
        if startDepth > 0 and not state.initialized then data.session.start(state, data.inbox) end
        local key = keepsakeKey or (_G.GameState and _G.GameState.LastAwardTrait)
        if startDepth > 0 then data.session.beginStartingKeepsake(state, key) end
        local expected, row = expectedEquip(state, key)
        local prior = equipScope
        equipScope = { expected = expected or {}, observed = {}, row = row, key = key }
        local ok, result = pcall(base, hero, keepsakeKey, args)
        local completed = equipScope
        equipScope = prior
        if not ok then error(result, 0) end
        if startDepth == 0 and row ~= nil then
            state.lastKeepsakeEquip = completed
        end
        report(runtime)
        return result
    end)

    roomHooks.attach(module, data.session, getState, report, ensureStarted)
    timelineHooks.attach(module, data.session, getState, report)
    featureHooks.attach(module, data.session, getState, report)
end

return logic
