-- Run-start and keepsake native contacts.  Room hooks are deliberately absent.
local hooks = {}

function hooks.attach(module, data, getState, report, room)
    local nativeFacts = import("mods/native_fact_bindings.lua")
    local hexTree = import("mods/hex/tree.lua")
    local roomCoordinator = room
    local startDepth, startingHexScope = 0, nil

    local equipResults = import("mods/keepsakes/equip_results.lua").attach(module, {
        contacts = nativeFacts.keepsakeEquipContacts,
        enforcing = function(runtime)
            local state = getState(runtime)
            return state ~= nil and (state.state == "synchronized"
                or (startDepth > 0 and state.state == "starting"))
        end,
        state = getState,
        mismatch = data.session.mismatch,
    })

    local function expectedEquip(state, keepsakeKey)
        if startDepth > 0 then return state.plan and state.plan.startingKeepsake.equipResults end
        local current = roomCoordinator.current(state)
        local handle = current and roomCoordinator.resolve(state, current,
            { kind = "keepsake", keepsakeKey = keepsakeKey })
        local payload = handle and roomCoordinator.begin(state, handle) or nil
        return payload and payload.transaction.equipResults, handle, payload
    end
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
        local result = equipResults.run(runtime, expected, function()
            return base(hero, keepsakeKey, args)
        end)
        if startDepth == 0 and handle ~= nil and payload ~= nil then
            data.session.complete(state, handle)
        end
        report(runtime); return result
    end)
end

return hooks
