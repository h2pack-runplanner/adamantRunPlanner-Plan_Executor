-- SpellDrop owns its native screen and delegates only tree construction.
local hooks = {}
local function detail(payload) return type(payload) == "table" and payload.detail or nil end
local function offerFor(payload)
    local offer = detail(payload) and detail(payload).traitOffer
    return type(offer) == "table" and offer.kind == "traits" and offer.giver == "SpellDrop"
        and type(offer.hexTree) == "table" and offer or nil
end
local function spellRole(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        local offer = role.traitOffer
        if role.gameName == contact.gameName and role.disposition == "normal" and type(offer) == "table"
            and offer.kind == "traits" and offer.giver == "SpellDrop"
            and type(offer.hexTree) == "table" then return role end
    end
end
local function expected(scope, index) local row = scope.offer.options[index]; return row and row.key end
local function selectSpell(scope, values, phase)
    local cursor = scope[phase] or 0
    local wanted = expected(scope, cursor + 1)
    for index, spellName in ipairs(values or {}) do
        local spell = _G.SpellData and _G.SpellData[spellName]
        if wanted and spell and spell.TraitName == wanted then
            scope[phase] = cursor + 1; return table.remove(values, index)
        end
    end
end
function hooks.attach(module, session, getState, report, room, tree)
    assert(type(tree) == "table", "spell acquisition Hex Tree instance is required")
    local scopesByLoot = setmetatable({}, { __mode = "k" })
    local randomScope, randomPhase
    local function mismatchFor(state)
        return function(checkpoint, expectedValue, observed)
            session.mismatch(state, checkpoint, expectedValue, observed)
        end
    end
    local function resolveScope(runtime, spellItem)
        local scope = spellItem and scopesByLoot[spellItem] or nil
        if scope then return scope end
        local state = getState(runtime); local current = room.current(state)
        local handle = current and room.bound(state, current, spellItem) or nil
        local payload = handle and room.peek(state, handle) or nil
        if not handle and current and type(room.claimReady) == "function" then
            handle, payload = room.claimReady(state, current,
                { kind = "spell", gameName = spellItem and spellItem.Name }, spellItem, spellRole)
        end
        local offer = offerFor(payload)
        if not handle or not offer then return nil end
        scope = { state = state, handle = handle, offer = offer, pregeneration = 0, buttons = 0 }
        scopesByLoot[spellItem] = scope
        return scope
    end
    local function clearScope(item, scope)
        if item and scopesByLoot[item] == scope then scopesByLoot[item] = nil end
    end
    module.hooks.wrap("RemoveRandomValue", "run-planner-spell-offer-order", function(_, _, base, values, ...)
        if randomScope and type(values) == "table" and (randomScope[randomPhase] or 0) < #randomScope.offer.options then
            local selected = selectSpell(randomScope, values, randomPhase)
            if selected then return selected end
            randomScope.failed = true
            mismatchFor(randomScope.state)("spell-offer-option",
                expected(randomScope, (randomScope[randomPhase] or 0) + 1), "native-ineligible")
        end
        return base(values, ...)
    end)
    module.hooks.wrap("CreateSpellButtons", "run-planner-spell-offer-buttons", function(_, _, base, screen)
        local scope = screen and screen.Source and scopesByLoot[screen.Source] or nil
        if not scope then return base(screen) end
        local priorScope, priorPhase = randomScope, randomPhase
        randomScope, randomPhase = scope, "buttons"
        local ok, result = pcall(base, screen)
        randomScope, randomPhase = priorScope, priorPhase
        if not ok then error(result, 0) end
        if scope.buttons ~= #scope.offer.options then
            scope.failed = true; mismatchFor(scope.state)("spell-offer-contact", #scope.offer.options, scope.buttons)
        end
        return result
    end)
    module.hooks.wrap("PregenerateSpells", "run-planner-spell-offer-pregeneration", function(_, runtime, base, screen)
        local scope = resolveScope(runtime, screen)
        if not scope then return base(screen) end
        local priorScope, priorPhase = randomScope, randomPhase
        randomScope, randomPhase = scope, "pregeneration"
        local ok, result = pcall(base, screen)
        randomScope, randomPhase = priorScope, priorPhase
        if not ok then clearScope(screen, scope); error(result, 0) end
        if scope.pregeneration ~= #scope.offer.options then
            scope.failed = true
            mismatchFor(scope.state)("spell-pregeneration-contact", #scope.offer.options, scope.pregeneration)
        end
        return result
    end)
    module.hooks.wrap("OpenSpellScreen", "run-planner-spell-begin", function(_, runtime, base, spellItem, args, user)
        local scope = resolveScope(runtime, spellItem)
        if not scope then return base(spellItem, args, user) end
        if not room.begin(scope.state, scope.handle) then return base(spellItem, args, user) end
        local ok, result = pcall(base, spellItem, args, user)
        if not ok then
            clearScope(spellItem, scope)
            error(result, 0)
        end
        if scopesByLoot[spellItem] == scope then
            session.mismatch(scope.state, "spell-selection-terminal", "AcceptAndCloseSpellScreen", "missing")
            clearScope(spellItem, scope)
        end
        report(runtime); return result
    end)
    module.hooks.wrap("AcceptAndCloseSpellScreen", "run-planner-spell-selection",
        function(_, runtime, base, screen, button)
        local item = screen and screen.Source
        local scope = item and scopesByLoot[item] or nil
        if not scope then return base(screen, button) end
        local index = tonumber(type(scope.offer.selected) == "string" and scope.offer.selected:match("(%d+)$"))
        local wanted, observed = index and expected(scope, index), button and button.TraitName
        if scope.failed or not wanted or observed ~= wanted then
            session.mismatch(scope.state, "spell-selection", wanted, observed)
            local ok, result = pcall(base, screen, button)
            clearScope(item, scope)
            if not ok then error(result, 0) end
            return result
        end
        local ok, result = pcall(function()
            return tree.realize(scope.offer.hexTree, mismatchFor(scope.state),
                function() return base(screen, button) end)
        end)
        if not ok then clearScope(item, scope); error(result, 0) end
        session.complete(scope.state, scope.handle); clearScope(item, scope)
        report(runtime); return result
        end)
end
return hooks
