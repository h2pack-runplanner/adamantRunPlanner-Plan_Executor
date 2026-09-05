-- Run-start and keepsake native contacts.  Room hooks are deliberately absent.
local hooks = {}

local function traitKey(value) return type(value) == "table" and (value.Name or value.TraitName) or value end

function hooks.attach(module, data, getState, report, room)
    local nativeFacts = import("mods/native_fact_bindings.lua")
    local chaos = import("mods/chaos.lua")
    local hexTree = import("mods/hex/tree.lua")
    local roomCoordinator = room
    local startDepth, equipScope, embryoContext, startingHexScope = 0, nil, nil, nil

    local function enforcing(runtime)
        local state = getState(runtime)
        return state ~= nil and (state.state == "synchronized" or (startDepth > 0 and state.state == "starting"))
    end

    local function expectedEquip(state, keepsakeKey)
        if startDepth > 0 then return state.plan and state.plan.startingKeepsake.equipResults end
        local current = roomCoordinator.current(state)
        local handle = current and roomCoordinator.resolve(state, current,
            { kind = "keepsake", keepsakeKey = keepsakeKey })
        local payload = handle and roomCoordinator.begin(state, handle) or nil
        return payload and payload.transaction.equipResults, handle, payload
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
            return result
        end)
    end
    wrapEquipResult(nativeFacts.keepsakeEquipContacts.experimentalHammer,
        "run-planner-equip-hammer", "experimentalHammer")
    wrapEquipResult(nativeFacts.keepsakeEquipContacts.jeweledPom,
        "run-planner-equip-pom", "jeweledPom")
    wrapEquipResult(nativeFacts.keepsakeEquipContacts.transcendentEmbryo,
        "run-planner-equip-embryo", "transcendentEmbryo")
    module.hooks.wrap("AddRandomChaosBlessing", "run-planner-equip-embryo-result", function(_, _, base, rarity)
        local expected = equipScope and equipScope.expected and equipScope.expected.transcendentEmbryo
        local prior = embryoContext
        if expected ~= nil then
            embryoContext = {
                target = expected.blessingKey,
                rarity = rarity,
                blessingValues = expected.blessingValues,
            }
        end
        local ok, result = pcall(base, rarity)
        embryoContext = prior
        if not ok then error(result, 0) end
        return result
    end)
    module.hooks.wrap("GetProcessedTraitData", "run-planner-equip-embryo-values", function(_, _, base, args)
        local result = base(args)
        if type(args) ~= "table" or type(result) ~= "table" or embryoContext == nil then return result end
        if args.TraitName ~= embryoContext.target then return result end
        result.Rarity = embryoContext.rarity
        return chaos.applyBlessing(result, embryoContext.target, embryoContext.blessingValues)
    end)
    module.hooks.wrap("GetRandomArrayValue", "run-planner-equip-selection", function(_, runtime, base, values, rng)
        if not enforcing(runtime) then return base(values, rng) end
        local expected = equipScope and equipScope.kind and equipScope.expected[equipScope.kind]
        local key = expected and (expected.traitKey or expected.blessingKey)
        if key and type(values) == "table" then
            for _, value in ipairs(values) do
                if traitKey(value) == key then return value end
            end
            data.session.mismatch(getState(runtime), "availability:traitEligibility", key, "missing candidate")
            return base(values, rng)
        end
        return base(values, rng)
    end)
    module.hooks.wrap("StartNewRun", "run-planner-start", function(_, runtime, base, previousRun, args)
        startDepth = startDepth + 1
        local ok, result = pcall(base, previousRun, args)
        startDepth = startDepth - 1
        if startDepth == 0 and startingHexScope ~= nil then
            hexTree.clear(startingHexScope)
            startingHexScope = nil
        end
        if not ok then error(result, 0) end
        local state = getState(runtime)
        if state ~= nil and state.state == "starting" then
            data.loadout.verifyCompleted(state, data.session.mismatch)
        end
        report(runtime)
        return result
    end)
    module.hooks.wrap("CreateNewHero", "run-planner-session-start", function(_, runtime, base, previousRun, args)
        if startDepth <= 0 then return base(previousRun, args) end
        local state = getState(runtime)
        if not state.initialized then data.session.start(state, data.inbox, "starting") end
        local expected = state.state == "starting" and state.plan and state.plan.startingLoadout
        local startingHex = expected and expected.startingHex or nil
        if startingHex ~= nil then
            startingHexScope = hexTree.prepare(startingHex, function(checkpoint, expectedValue, observed)
                data.session.mismatch(state, checkpoint, expectedValue, observed)
            end)
        end
        local ok, result = pcall(base, previousRun, args)
        if not ok then error(result, 0) end
        return result
    end)
    module.hooks.wrap("EquipKeepsake", "run-planner-equip-keepsake", function(_, runtime, base, hero,
        keepsakeKey, args)
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
        local expected, handle, payload = expectedEquip(state, key)
        local prior = equipScope
        equipScope = {
            expected = expected or {}, handle = handle, payload = payload,
        }
        local ok, result = pcall(base, hero, keepsakeKey, args)
        equipScope = prior
        if not ok then error(result, 0) end
        if startDepth == 0 and handle ~= nil and payload ~= nil then
            data.session.complete(state, handle)
        end
        report(runtime); return result
    end)
end

return hooks
