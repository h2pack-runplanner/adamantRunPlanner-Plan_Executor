-- Native contacts for planner-published level acquisitions.  This module
-- steers the native Pom menu and direct room-reward Nectar effect; it never
-- mutates a trait itself.
local levels = {}

local visibleNames = {
    StackUpgrade = true,
    StackUpgradeBig = true,
    StackUpgradeTriple = true,
}

function levels.isVisibleCarrier(value)
    return type(value) == "table" and visibleNames[value.Name or value.ItemName or value.LootName] == true
end

function levels.isDirectCarrier(value)
    return type(value) == "table" and (value.Name or value.ItemName or value.LootName) == "GiftDrop"
end

local function resolution(payload)
    local detail = payload and payload.detail
    return detail and detail.levelResolution or nil
end

function levels.isNormalPayload(payload)
    local detail = payload and payload.detail
    return type(detail) == "table" and detail.disposition == "normal"
end

local function heroTraits()
    local hero = _G.CurrentRun and _G.CurrentRun.Hero
    return type(hero) == "table" and hero.Traits or nil
end

local function findTrait(key)
    for _, trait in pairs(heroTraits() or {}) do
        if type(trait) == "table" and (trait.Name == key or trait.TraitName == key) then return trait end
    end
    return nil
end

local function copy(value)
    local result = {}
    for key, nested in pairs(value or {}) do result[key] = nested end
    return result
end

function levels.prepareVisible(row, loot)
    local effect = resolution(row)
    if effect == nil or type(loot) ~= "table" then return false end
    local installed = {}
    local existing = loot.UpgradeOptions or {}
    for index, target in ipairs(effect.offeredTargets or {}) do
        local option = copy(existing[index])
        option.ItemName = target
        installed[index] = option
    end
    loot.StackOnly = true
    -- The published count is final.  The surrounding screen adapter masks
    -- the native FatedPomLevelBonus query during this row build so that the
    -- same final count remains available to native eligibility checks.
    loot.StackNum = effect.levelCount
    loot.UpgradeOptions = installed
    return true
end

function levels.verify(row, selected, before, traits)
    local effect = resolution(row)
    if effect == nil or effect.selectedTarget ~= selected then return false end
    if selected == nil then return true end
    for _, trait in pairs(traits or {}) do
        if type(trait) == "table" and (trait.Name == selected or trait.TraitName == selected) then
            return type(before) == "number" and trait.StackNum == before + effect.levelCount
        end
    end
    return false
end

local function snapshot(traits)
    local result = {}
    for _, trait in pairs(traits or {}) do
        if type(trait) == "table" and (trait.Name or trait.TraitName) ~= nil then
            local key = trait.Name or trait.TraitName
            result[key] = trait.StackNum or 1
        end
    end
    return result
end

local function unchanged(before, traits)
    local after = snapshot(traits)
    for key, value in pairs(before) do if after[key] ~= value then return false end end
    for key in pairs(after) do if before[key] == nil then return false end end
    return true
end

local function upgradeableTargets(stackNum)
    if type(_G.GetAllUpgradeableGodTraits) ~= "function" then return nil, false end
    return _G.GetAllUpgradeableGodTraits(stackNum or 1) or {}, true
end

local function markedArguments(source, args)
    if type(source) == "table" and source.__runPlannerTimelineHandle ~= nil then return source end
    if type(args) == "table" and args.__runPlannerTimelineHandle ~= nil then return args end
    return nil
end

local function clearAdapterTransport(arguments)
    if type(arguments) ~= "table" then return end
    arguments.__runPlannerTimelineHandle = nil
end

local function carrier(state, room, native)
    local current = room.current(state)
    if current == nil then return nil end
    local handle = room.bound(state, current, native)
    if handle == nil or type(room.peek) ~= "function" then return nil end
    local payload = room.peek(state, handle)
    return handle, payload
end

local function directLevelRole(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        if role.gameName == contact.gameName
            and role.disposition == "normal"
            and role.levelResolution ~= nil then
            return role
        end
    end
    return nil
end

function levels.visibleRole(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        if role.gameName == contact.gameName and role.disposition == "normal"
            and role.levelResolution ~= nil then
            return role
        end
    end
    return nil
end

function levels.attach(module, session, getState, report, room)
    local roomCoordinator = room
    local suppressFatedPomBonus = 0
    local begunVisible = setmetatable({}, { __mode = "k" })
    local activeDirectUses = setmetatable({}, { __mode = "k" })

    local function forwardDirect(scope)
        if scope.forwarded or scope.handle == nil then return end
        local forwarded = {}
        for key, value in pairs(scope.originalArgs or {}) do forwarded[key] = value end
        forwarded.__runPlannerTimelineHandle = scope.handle
        scope.item.UseFunctionArgs = forwarded
        scope.forwarded = true
    end

    local function withoutFatedPomBonus(callback)
        suppressFatedPomBonus = suppressFatedPomBonus + 1
        local ok, result = pcall(callback)
        suppressFatedPomBonus = suppressFatedPomBonus - 1
        if not ok then error(result, 0) end
        return result
    end

    module.hooks.wrap("GetTotalHeroTraitValue", "run-planner-level-fated-bonus", function(_, _, base,
        propertyName, args)
        if propertyName == "FatedPomLevelBonus" and suppressFatedPomBonus > 0 then return 0 end
        return base(propertyName, args)
    end)

    module.hooks.wrap("UseLoot", "run-planner-level-use-loot", function(_, runtime, base, usee, args, user)
        if not levels.isVisibleCarrier(usee) then return base(usee, args, user) end
        local state = getState(runtime)
        local _, payload = carrier(state, roomCoordinator, usee)
        if payload ~= nil and not levels.isNormalPayload(payload) then
            return base(usee, args, user)
        end
        if resolution(payload) == nil then return base(usee, args, user) end
        local prior = usee.__runPlannerLevelCarrier
        usee.__runPlannerLevelCarrier = true
        local ok, result = pcall(base, usee, args, user)
        usee.__runPlannerLevelCarrier = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("HandleLootPickup", "run-planner-level-begin-loot", function(_, runtime, base,
        currentRun, loot, args)
        if not levels.isVisibleCarrier(loot) then return base(currentRun, loot, args) end
        local state = getState(runtime)
        local handle, payload = carrier(state, roomCoordinator, loot)
        local current = roomCoordinator.current(state)
        if handle ~= nil and not levels.isNormalPayload(payload) then
            return base(currentRun, loot, args)
        end
        if handle == nil and current ~= nil and type(roomCoordinator.claimReady) == "function" then
            handle, payload = roomCoordinator.claimReady(state, current, {
                kind = "visibleLevel", gameName = loot.Name or loot.ItemName or loot.LootName,
            }, loot, levels.visibleRole)
        end
        if resolution(payload) == nil then return base(currentRun, loot, args) end
        local started = roomCoordinator.begin(state, handle)
        if started == nil then return base(currentRun, loot, args) end
        begunVisible[handle] = true
        local prior = loot.__runPlannerLevelCarrier
        loot.__runPlannerLevelCarrier = true
        local ok, result = pcall(base, currentRun, loot, args)
        loot.__runPlannerLevelCarrier = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("CreateBoonLootButtons", "run-planner-level-screen", function(_, runtime, base,
        screen, loot, reroll, args)
        if not levels.isVisibleCarrier(loot) then return base(screen, loot, reroll, args) end
        local state = getState(runtime)
        local handle, payload = carrier(state, roomCoordinator, loot)
        if handle ~= nil and not levels.isNormalPayload(payload) then
            return base(screen, loot, reroll, args)
        end
        if resolution(payload) == nil or not begunVisible[handle] then
            return base(screen, loot, reroll, args)
        end
        local initial = reroll ~= true
        if initial then levels.prepareVisible(payload, loot) end
        loot.__runPlannerLevelCarrier = true
        if initial then
            return withoutFatedPomBonus(function()
                return base(screen, loot, reroll, args)
            end)
        end
        return base(screen, loot, reroll, args)
    end)

    module.hooks.wrap("HandleUpgradeChoiceSelection", "run-planner-level-selection", function(_, runtime, base,
        screen, button, args)
        local loot = button and button.LootData
        if not levels.isVisibleCarrier(loot) then return base(screen, button, args) end
        if type(args) == "table" and args.DoubleBoonChance then return base(screen, button, args) end
        local state = getState(runtime)
        local handle, payload = carrier(state, roomCoordinator, loot)
        if handle ~= nil and not levels.isNormalPayload(payload) then
            return base(screen, button, args)
        end
        local effect = resolution(payload)
        if effect == nil then return base(screen, button, args) end
        if not begunVisible[handle] then return base(screen, button, args) end
        local selected = button and button.Data and button.Data.Name
        local trait = findTrait(selected)
        local before = trait and (trait.StackNum or 1) or nil
        local prior = loot.__runPlannerLevelCarrier
        loot.__runPlannerLevelCarrier = true
        local ok, result = pcall(base, screen, button, args)
        loot.__runPlannerLevelCarrier = prior
        if not ok then error(result, 0) end
        session.complete(state, handle, levels.verify(payload, selected, before, heroTraits()), effect, selected)
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseConsumableItem", "run-planner-level-use-consumable", function(_, runtime, base,
        item, args, user)
        if not levels.isDirectCarrier(item) then return base(item, args, user) end
        local state = getState(runtime)
        local handle, payload = carrier(state, roomCoordinator, item)
        if handle ~= nil and not levels.isNormalPayload(payload) then
            return base(item, args, user)
        end
        if handle ~= nil and resolution(payload) == nil then return base(item, args, user) end

        local scope = {
            state = state, current = room.current(state), handle = handle, payload = payload,
            item = item, originalArgs = item.UseFunctionArgs, accepted = false,
        }
        activeDirectUses[item] = scope
        local prior = item.__runPlannerLevelCarrier
        item.__runPlannerLevelCarrier = true
        if resolution(payload) ~= nil then forwardDirect(scope) end
        local ok, result = pcall(base, item, args, user)
        if scope.forwarded then item.UseFunctionArgs = scope.originalArgs end
        item.__runPlannerLevelCarrier = prior
        if activeDirectUses[item] == scope then activeDirectUses[item] = nil end
        if not ok then error(result, 0) end
        if scope.accepted then report(runtime) end
        return result
    end)

    module.hooks.wrap("ConsumableUsedPresentation", "run-planner-level-direct-accepted", function(_, runtime, base,
        currentRun, item, args)
        local result = base(currentRun, item, args)
        local scope = activeDirectUses[item]
        if scope ~= nil and not scope.accepted and result ~= false then
            if scope.handle == nil and type(roomCoordinator.claimReady) == "function" then
                scope.handle, scope.payload = roomCoordinator.claimReady(scope.state, scope.current, {
                    kind = "directLevel", gameName = "GiftDrop",
                }, item, directLevelRole)
            end
            if scope.handle == nil or resolution(scope.payload) == nil then return result end
            scope.accepted = true
            forwardDirect(scope)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("UseStoreRewardRandomStack", "run-planner-level-direct-entry", function(_, runtime, base,
        source, args)
        -- CallFunctionName passes UseFunctionArgs first and the consumable
        -- object second. The object is not the carrier; the first argument is.
        local directArgs = markedArguments(source, args)
        if directArgs == nil then return base(source, args) end
        local handle = directArgs.__runPlannerTimelineHandle
        local state = getState(runtime)
        local payload = roomCoordinator.begin(state, handle)
        local effect = resolution(payload)
        if effect == nil then
            clearAdapterTransport(directArgs)
            return base(source, args)
        end
        return base(source, args)
    end)

    module.hooks.wrap("AddStackToTraits", "run-planner-level-direct-terminal", function(_, runtime, base,
        source, args)
        local directArgs = markedArguments(source, args)
        if directArgs == nil then return base(source, args) end
        local handle = directArgs.__runPlannerTimelineHandle
        local state = getState(runtime)
        local payload = roomCoordinator.begin(state, handle)
        local effect = resolution(payload)
        if effect == nil then
            clearAdapterTransport(directArgs)
            return base(source, args)
        end

        local target = type(effect.selectedTarget) == "string" and effect.selectedTarget or nil
        -- UseStoreRewardRandomStack has already applied the native fated
        -- addition by this point. The published levelCount is the final
        -- effect, so restore that exact count before native eligibility and
        -- mutation rather than applying the bonus a second time.
        local stackNum = effect.levelCount
        local eligible, canReadEligibility = upgradeableTargets(stackNum)
        local original = {
            NumStacks = directArgs.NumStacks,
            TraitName = directArgs.TraitName,
            NumTraits = directArgs.NumTraits,
        }
        if target ~= nil then
            local trait = findTrait(target)
            if trait == nil or (canReadEligibility and not eligible[target]) then
                session.complete(state, handle, false, effect, target)
                directArgs.NumStacks = original.NumStacks
                directArgs.TraitName = original.TraitName
                directArgs.NumTraits = original.NumTraits
                clearAdapterTransport(directArgs)
                report(runtime)
                return base(source, args)
            end
            directArgs.NumStacks = stackNum
            directArgs.TraitName = target
            directArgs.NumTraits = 1
        else
            if not canReadEligibility or next(eligible) ~= nil then
                session.complete(state, handle, false, effect, eligible)
                directArgs.NumStacks = original.NumStacks
                directArgs.TraitName = original.TraitName
                directArgs.NumTraits = original.NumTraits
                clearAdapterTransport(directArgs)
                report(runtime)
                return base(source, args)
            end
            directArgs.NumStacks = stackNum
            directArgs.TraitName = nil
            directArgs.NumTraits = 0
        end

        local threadedDispatch = directArgs.Thread == true
        local before = target and (findTrait(target).StackNum or 1) or nil
        local unchangedBefore = target == nil and snapshot(heroTraits()) or nil
        local result = base(source, args)
        if not threadedDispatch then
            local proof = target ~= nil
                and levels.verify(payload, target, before, heroTraits())
                or unchanged(unchangedBefore or {}, heroTraits())
            session.complete(state, handle, proof, effect, target)
            report(runtime)
        end
        return result
    end)
end

return levels
