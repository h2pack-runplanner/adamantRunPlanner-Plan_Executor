-- Echo keeps its native outer menu and native effects. Only the two authored
-- volatile results persist beyond that outer selection: the nested prior-run
-- Boon menu and Pom's greatest-level target.
local json = type(import) == "function" and import("mods/protocol/json.lua") or require("mods.protocol.json")

local echo = {}

local function optionIndex(key)
    return type(key) == "string" and tonumber(key:match("(%d+)$")) or nil
end

local function nestedOffer(scope)
    local option = scope and scope.selectedOption
    return type(option) == "table" and option.echoLastRunBoon or nil
end

local function nestedSelected(offer)
    local index = offer and optionIndex(offer.selected)
    return index and offer.options and offer.options[index] or nil
end

local function executionOffer(offer)
    local options = {}
    for _, row in ipairs(offer.options or {}) do
        options[#options + 1] = {
            key = row.key,
            rarity = row.rarity,
            lootHistorySource = row.lootHistorySource,
            targetTraitKey = row.targetTraitKey,
            naturalSelectionTargets = row.naturalSelectionTargets,
            allTogetherResult = row.allTogetherResult,
        }
    end
    local selected = nestedSelected(offer)
    return {
        kind = "traits",
        giver = selected and selected.giver or "Echo",
        options = options,
        selected = offer.selected,
    }
end

local function consequencePayload(scope, offer)
    return {
        transaction = scope.payload.transaction,
        detail = { disposition = "normal", traitOffer = executionOffer(offer) },
    }
end

local function rowsAvailable(offer)
    for _, row in ipairs(offer.options or {}) do
        if _G.TraitData[row.key] == nil then return false end
    end
    return true
end

function echo.attach(module, session, report, npcScope, traitScopes)
    local pendingBoon
    local activeBoon
    local boonMenus = setmetatable({}, { __mode = "k" })
    local pendingPom
    local activePom
    local activeLootHistorySource

    npcScope.observeSelection("EchoLastRunBoon", function(scope)
        if nestedOffer(scope) == nil then return false end
        pendingBoon = scope
        return true
    end)
    npcScope.observeSelection("EchoDoubleLevelBoon", function(scope)
        if scope.selectedOption.echoPomTarget == nil then return false end
        pendingPom = scope
        return true
    end)

    module.hooks.wrap("EchoLastRunBoon", "run-planner-echo-last-run-menu", function(_, runtime,
        base, args, sourceTraitData)
        local scope = pendingBoon
        if scope == nil then return base(args, sourceTraitData) end
        pendingBoon = nil
        activeBoon = scope
        local ok, result = pcall(base, args, sourceTraitData)
        activeBoon = nil
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("OpenUpgradeChoiceMenu", "run-planner-echo-last-run-rows", function(_, _,
        base, source, args)
        local scope = activeBoon
        local offer = nestedOffer(scope)
        if offer == nil then return base(source, args) end
        if not rowsAvailable(offer) then
            session.mismatch(scope.state, "echo-last-run-availability", "authored native rows", nil)
            return base(source, args)
        end
        source.UpgradeOptions = {}
        for index, row in ipairs(offer.options) do
            source.UpgradeOptions[index] = {
                Type = "Trait", ItemName = row.key, Rarity = row.rarity,
            }
        end
        boonMenus[source] = scope
        return base(source, args)
    end)

    module.hooks.wrap("SelectEchoBoon", "run-planner-echo-last-run-selection", function(_, runtime,
        base, screen, button, args)
        local source = screen and screen.Source
        local scope = source and boonMenus[source] or nil
        local offer = nestedOffer(scope)
        local expected = nestedSelected(offer)
        if expected == nil then return base(screen, button, args) end
        local observed = button and button.Data and button.Data.Name
        if observed ~= expected.key then
            local result = base(screen, button, args)
            boonMenus[source] = nil
            session.mismatch(scope.state, "echo-last-run-selection", expected.key, observed)
            report(runtime)
            return result
        end
        local payload = consequencePayload(scope, offer)
        local priorLootHistorySource = activeLootHistorySource
        activeLootHistorySource = expected.lootHistorySource and {
            key = expected.key, source = expected.lootHistorySource,
        } or nil
        local ok, result = pcall(traitScopes.runExternalSelection, runtime, payload, expected.key,
            scope.handle, scope.current, function() return base(screen, button, args) end)
        activeLootHistorySource = priorLootHistorySource
        if not ok then error(result, 0) end
        boonMenus[source] = nil
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetLootSourceName", "run-planner-echo-last-run-loot-history", function(_, _, base,
        traitName, args)
        local source = activeLootHistorySource
        if source ~= nil and traitName == source.key then return source.source end
        return base(traitName, args)
    end)

    module.hooks.wrap("EchoDoubleLevelBoon", "run-planner-echo-pom-target", function(_, runtime,
        base, ...)
        local scope = pendingPom
        if scope == nil then return base(...) end
        pendingPom = nil
        local target = scope.selectedOption.echoPomTarget
        activePom = { scope = scope, target = target, contacted = false }
        local ok, result = pcall(base, ...)
        local completed = activePom
        activePom = nil
        if not ok then error(result, 0) end
        if not json.isNull(target) and not completed.contacted then
            session.mismatch(scope.state, "echo-pom-target", target, "missing native selection")
        else
            session.complete(scope.state, scope.handle)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetRandomKey", "run-planner-echo-pom-selection", function(_, _, base,
        values, ...)
        local scope = activePom
        if scope == nil or json.isNull(scope.target) then return base(values, ...) end
        if type(values) == "table" and values[scope.target] ~= nil then
            scope.contacted = true
            return scope.target
        end
        return base(values, ...)
    end)
end

return echo
