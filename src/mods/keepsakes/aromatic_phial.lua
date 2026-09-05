-- Aromatic Phial's exact fountain-rarity selector. UseHealthFountain remains
-- the lifecycle and mutation owner; this scope survives its threaded native
-- AddRarityToTraits contact and constrains only the Phial source.
local phial = {}

local function traitKey(value)
    return type(value) == "table" and (value.Name or value.TraitName) or value
end

local function findTrait(run, key)
    local hero = type(run) == "table" and run.Hero or nil
    for _, trait in pairs(type(hero) == "table" and hero.Traits or {}) do
        if traitKey(trait) == key then return trait end
    end
    return nil
end

function phial.attach(module, options)
    local active

    module.hooks.wrap("AddRarityToTraits", "run-planner-aromatic-phial-target", function(_, runtime,
        base, source, args)
        local scope = active
        if scope == nil or traitKey(source) ~= options.phialTraitKey then
            return base(source, args)
        end
        local state = options.getState(runtime)
        if state ~= scope.state or state.state ~= "synchronized"
            or options.room.current(state) ~= scope.room then
            active = nil
            return base(source, args)
        end

        active = nil
        local target = findTrait(_G.CurrentRun, scope.target)
        if target == nil then
            options.session.mismatch(state, "aromatic-phial-target", scope.target, "missing trait")
            options.report(runtime)
            return base(source, args)
        end
        local forced = {}
        for key, value in pairs(args or {}) do forced[key] = value end
        forced.ForceUpgrade = { target }
        local ok, result = pcall(base, source, forced)
        if not ok then error(result, 0) end
        if traitKey(result) ~= scope.target then
            options.session.mismatch(state, "aromatic-phial-target", scope.target, traitKey(result))
        else
            options.session.complete(state, scope.handle)
        end
        options.report(runtime)
        return result
    end)

    return {
        begin = function(state, room, handle, payload)
            local transaction = payload and payload.transaction
            local target = transaction and transaction.aromaticPhialTarget
            if target == nil then return nil end
            local scope = { state = state, room = room, handle = handle, target = target }
            active = scope
            return scope
        end,
        cancel = function(scope)
            if active == scope then active = nil end
        end,
    }
end

return phial
