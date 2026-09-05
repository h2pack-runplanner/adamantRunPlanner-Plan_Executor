-- Concave Stone's bounded secondary trait-screen state. The ordinary trait
-- carrier still owns the outer offer and menu terminal; this module owns only
-- the Stone roll, its residual button, and the native callbacks that bridge
-- those two screens.
local stoneModule = {}

function stoneModule.create(options)
    local pendingByHandle = {}
    local failedHandles = {}
    local active

    local function scopeIsCurrent(state, pending)
        return pending ~= nil and pending.context == options.room.current(state)
            and state.state == "synchronized"
    end

    local function discard(pending)
        if pending == nil then return end
        pendingByHandle[pending.handle] = nil
        if pending.failed then failedHandles[pending.handle] = true end
        if active == pending then active = nil end
    end

    local function completeOuter(state, handle)
        if failedHandles[handle] then return end
        local pending = pendingByHandle[handle]
        if pending ~= nil then
            if pending.failed or not pending.outerReturned or not pending.rollConsumed then return end
            if pending.result.kind == "proc" and not pending.residualReturned then return end
            failedHandles[handle] = nil
            discard(pending)
        end
        options.session.complete(state, handle)
    end

    local function steerResidual(runtime, base, candidates, rng)
        local pending = active
        if pending == nil or pending.result.kind ~= "proc" or not pending.rollConsumed
            or pending.residualButton ~= nil then
            return base(candidates, rng)
        end
        local state = options.getState(runtime)
        if not scopeIsCurrent(state, pending) then
            pending.failed = true
            discard(pending)
            return base(candidates, rng)
        end
        local expected = options.ordinary.optionForOptionKey(pending.payload, pending.result.optionKey)
        local expectedKey = expected and expected.key or nil
        local sawButton, selected = false, nil
        for _, candidate in pairs(candidates or {}) do
            if type(candidate) == "table" and type(candidate.Data) == "table" then
                sawButton = true
                if candidate.Data.Name == expectedKey then selected = candidate end
            end
        end
        if not sawButton then return base(candidates, rng) end
        if selected == nil then
            pending.failed = true
            discard(pending)
            options.session.mismatch(state, "concave-stone-residual", expectedKey, "native-ineligible")
            return base(candidates, rng)
        end
        pending.residualButton = selected
        return selected
    end

    local function installHooks(module)
        module.hooks.wrap("HasHeroTraitValue", "run-planner-scope-concave-stone-roll", function(_, runtime, base,
            traitName, ...)
            local result = base(traitName, ...)
            local pending = active
            if pending == nil or traitName ~= "DoubleBoonChance" then return result end
            local state = options.getState(runtime)
            if not scopeIsCurrent(state, pending) then
                pending.failed = true
                discard(pending)
            else
                pending.rollTraitObserved = true
            end
            return result
        end)

        module.hooks.wrap("RandomChance", "run-planner-steer-concave-stone-roll", function(_, runtime, base,
            chance, args)
            local pending = active
            if pending == nil or not pending.rollTraitObserved or pending.rollConsumed then
                return base(chance, args)
            end
            local state = options.getState(runtime)
            if not scopeIsCurrent(state, pending) then
                pending.failed = true
                discard(pending)
                return base(chance, args)
            end
            pending.rollConsumed = true
            return pending.result.kind == "proc"
        end)
    end

    installHooks(options.module)

    return {
        active = function() return active end,
        begin = function(handle, context, payload, result)
            local pending = {
                handle = handle,
                context = context,
                payload = payload,
                result = result,
                outerReturned = false,
                rollTraitObserved = false,
                rollConsumed = false,
                residualReturned = result.kind == "noProc",
            }
            pendingByHandle[handle] = pending
            failedHandles[handle] = nil
            active = pending
            return pending
        end,
        discard = discard,
        completeOuter = completeOuter,
        steerResidual = steerResidual,
        validateResidual = function(state, button, selected)
            local pending = active
            if pending == nil then return nil, nil end
            if not scopeIsCurrent(state, pending) then
                pending.failed = true
                discard(pending)
                return false, pending
            end
            local expected = pending.result.kind == "proc"
                and options.ordinary.optionForOptionKey(pending.payload, pending.result.optionKey) or nil
            if pending.failed or not pending.rollConsumed or expected == nil
                or button ~= pending.residualButton or selected ~= expected.key then
                pending.failed = true
                discard(pending)
                options.session.mismatch(state, "concave-stone-residual", expected and expected.key or nil, selected)
                return false, pending
            end
            return true, pending
        end,
        markResidualReturned = function(pending)
            pending.residualReturned = true
        end,
        finishOuter = function(state, pending)
            if pending == nil then return end
            if active == pending then active = nil end
            pending.outerReturned = true
            if not pending.rollConsumed then
                pending.failed = true
                discard(pending)
                options.session.mismatch(state, "concave-stone-roll", pending.result.kind, "missing")
            elseif pending.result.kind == "proc" and not pending.residualReturned then
                pending.failed = true
                discard(pending)
                local expected = options.ordinary.optionForOptionKey(pending.payload, pending.result.optionKey)
                options.session.mismatch(state, "concave-stone-residual", expected and expected.key or nil, "missing")
            end
        end,
    }
end

return stoneModule
