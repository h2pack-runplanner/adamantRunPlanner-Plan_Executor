-- Shared test doubles for required Hades II contacts. Production adapters call
-- these contacts directly; suites install only the native surface they use.
local nativeGame = {}

function nativeGame.install(bindings)
    local prior = {}
    for key, value in pairs(bindings) do
        prior[key] = _G[key]
        _G[key] = value
    end
    return function()
        for key in pairs(bindings) do _G[key] = prior[key] end
    end
end

function nativeGame.anyTraitDeclarations()
    return setmetatable({}, {
        __index = function(declarations, key)
            local declaration = { Name = key }
            rawset(declarations, key, declaration)
            return declaration
        end,
    })
end

function nativeGame.alwaysEligible()
    return true
end

function nativeGame.currentUpgradeableTraits()
    local result = {}
    for _, trait in ipairs(_G.CurrentRun and _G.CurrentRun.Hero and _G.CurrentRun.Hero.Traits or {}) do
        result[trait.Name] = true
    end
    return result
end

function nativeGame.noShrineUpgrades()
    return 0
end

return nativeGame
