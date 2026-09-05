-- One owner-agnostic native Hex-tree realization seam. Owners provide a
-- resolved tree; this module scopes only the native random construction.
local tree = {}
local pending, active

local function mismatch(scope, checkpoint, expected, observed)
    if scope and scope.mismatch then scope.mismatch(checkpoint, expected, observed) end
end
local function keys(values)
    local result = {}
    for _, key in ipairs(values or {}) do result[key] = true end
    return result
end
local function removeExpected(values, remaining)
    for index, value in ipairs(values or {}) do
        if remaining[value] then remaining[value] = nil; return table.remove(values, index) end
    end
end

function tree.prepare(expected, mismatchCallback)
    local scope = {
        prior = pending, expected = expected, mismatch = mismatchCallback,
        rare = keys(expected.rareTalentKeys), epic = keys(expected.epicTalentKeys),
        godSent = expected.godSent and expected.godSent.olympianTalentKey,
    }
    pending = scope
    return scope
end
function tree.clear(scope)
    if pending ~= scope then return end
    pending = scope.prior
    if not scope.created then mismatch(scope, "hex-tree-contact", "CreateTalentTree", "missing") end
end
function tree.realize(expected, mismatchCallback, action)
    local scope = tree.prepare(expected, mismatchCallback)
    local ok, result = pcall(action)
    tree.clear(scope)
    if not ok then error(result, 0) end
    return result
end

function tree.attach(module)
    module.hooks.wrap("CreateTalentTree", "run-planner-hex-tree", function(_, _, base, spellData)
        local scope = pending
        if not scope then return base(spellData) end
        scope.created = true
        local prior = active; active = scope
        local ok, result = pcall(base, spellData)
        active = prior
        if not ok then error(result, 0) end
        for key in pairs(scope.rare) do mismatch(scope, "hex-tree-rare", key, "missing") end
        for key in pairs(scope.epic) do mismatch(scope, "hex-tree-epic", key, "missing") end
        if scope.godSent then mismatch(scope, "hex-tree-god-sent", scope.godSent, "missing") end
        return result
    end)
    module.hooks.wrap("GetRandomValue", "run-planner-hex-layout", function(_, _, base, values, ...)
        if active and type(values) == "table" then
            for _, value in ipairs(values) do
                if type(value) == "table" and value.Name == active.expected.layoutKey then return value end
            end
            mismatch(active, "hex-tree-layout", active.expected.layoutKey, "native-ineligible")
        end
        return base(values, ...)
    end)
    module.hooks.wrap("IsGameStateEligible", "run-planner-hex-god-sent-absence",
        function(_, _, base, source, requirements, ...)
        if active and active.expected.godSent == nil and _G.SpellTalentData
            and requirements == _G.SpellTalentData.ServeDuoGameRequirements then return false end
        return base(source, requirements, ...)
        end)
    module.hooks.wrap("RemoveRandomValue", "run-planner-hex-special-talents", function(_, _, base, values, ...)
        if active and type(values) == "table" then
            local selected = removeExpected(values, active.rare) or removeExpected(values, active.epic)
            if selected then return selected end
            if active.godSent then
                for index, value in ipairs(values) do
                    if value == active.godSent then active.godSent = nil; return table.remove(values, index) end
                end
            end
        end
        return base(values, ...)
    end)
end
return tree
