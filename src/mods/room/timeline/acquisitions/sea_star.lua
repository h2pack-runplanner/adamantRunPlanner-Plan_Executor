-- Sea Star is a source-role collaborator, not a duplicate-object binder.
-- Each acquisition carrier supplies its bounded native call; this module
-- merely forces the one already-published chance branch and verifies it ran.
local seaStar = {}

local active

local function resultFor(payload)
    local detail = type(payload) == "table" and payload.detail or nil
    local result = type(detail) == "table" and detail.seaStarResult or nil
    if type(result) ~= "table" or (result.kind ~= "proc" and result.kind ~= "noProc") then return nil end
    return result
end

function seaStar.scope(state, payload)
    return { state = state, result = resultFor(payload), chanceConsumed = false, traitRead = false }
end

-- An unbound generated object can become a planner carrier only after native
-- accepted-use presentation.  It still shares this enclosing native call.
function seaStar.activate(scope, payload)
    if scope ~= nil and scope.result == nil then scope.result = resultFor(payload) end
    return scope
end

function seaStar.call(scope, invoke, mismatch)
    -- A generated object is unbound at call entry. Its accepted native
    -- presentation can claim the ready source and activate this scope before
    -- the game's chance contact later in the same call.
    if scope == nil then return invoke() end
    local prior = active
    active = scope
    local ok, result = pcall(invoke)
    active = prior
    if not ok then error(result, 0) end
    seaStar.requireConsumed(scope, mismatch)
    return result
end

-- Some native carriers settle an inner screen/function before their enclosing
-- native call returns.  They must invoke this immediately before completion.
function seaStar.requireConsumed(scope, mismatch)
    if scope == nil or scope.result == nil or scope.chanceConsumed then return true end
    if not scope.reportedMissing then
        scope.reportedMissing = true
        mismatch(scope.state, "sea-star-chance", scope.result.kind, "missing")
    end
    return false
end

function seaStar.attach(module)
    module.hooks.wrap("GetTotalHeroTraitValue", "run-planner-sea-star-chance-gate", function(_, _, base,
        propertyName, args)
        if active ~= nil and active.result ~= nil and propertyName == "DoubleRewardChance" then
            active.traitRead = true
            -- Keep the native chance path live for both authored outcomes;
            -- RandomChance below supplies the exact branch.
            return 1
        end
        return base(propertyName, args)
    end)

    module.hooks.wrap("RandomChance", "run-planner-sea-star-chance-result", function(_, _, base, chance, args)
        if active ~= nil and active.result ~= nil and active.traitRead and not active.chanceConsumed then
            active.chanceConsumed = true
            return active.result.kind == "proc"
        end
        return base(chance, args)
    end)
end

return seaStar
