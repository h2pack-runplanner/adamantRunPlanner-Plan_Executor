-- Path of Stars accepts only its exact native consumable, then leaves all
-- point accounting, node choice, and closure to the writable Talent screen.
local path = {}
local seaStar = type(import) == "function" and import("mods/room/timeline/acquisitions/sea_star.lua")
    or require("mods.room.timeline.acquisitions.sea_star")

local pathNames = {
    MinorTalentDrop = true,
    TalentDrop = true,
    TalentBigDrop = true,
    SpellDrop = true,
}

local function nativeName(item)
    return type(item) == "table" and (item.Name or item.ItemName or item.LootName) or nil
end

local function pathRole(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        if role.disposition == "normal" and role.gameName == contact.gameName
            and pathNames[role.gameName] and role.traitOffer == nil and role.levelResolution == nil then
            return role
        end
    end
    return nil
end

local function boundScope(room, state, item, claimReady)
    local current = room.current(state)
    local handle = current and room.bound(state, current, item) or nil
    local payload = handle and room.peek(state, handle) or nil
    if handle ~= nil and pathRole(payload and payload.transaction, { gameName = nativeName(item) }) == nil then
        return nil
    end
    if handle == nil and claimReady == true and current ~= nil and type(room.claimReady) == "function" then
        handle = room.claimReady(state, current, {
            kind = "pathOfStars", gameName = nativeName(item),
        }, item, pathRole)
    end
    if handle == nil then return nil end
    return { state = state, current = current, handle = handle, item = item }
end

function path.attach(module, session, getState, report, room)
    local acceptedUses = setmetatable({}, { __mode = "k" })
    local routedSpellDrops = setmetatable({}, { __mode = "k" })

    local function completeAfterScreen(runtime, scope, base, args, item, context)
        if scope == nil then return base(args, item, context) end
        local payload = room.begin(scope.state, scope.handle)
        if payload == nil then return base(args, item, context) end
        local ok, result = pcall(base, args, item, context)
        if not ok then error(result, 0) end
        if seaStar.requireConsumed(scope.seaStar, session.mismatch) then
            session.complete(scope.state, scope.handle)
            scope.completed = true
        end
        if scope.completed and scope.seaStar and scope.seaStar.result and scope.seaStar.result.kind == "proc" then
            room.releaseCompletedBinding(scope.state, scope.current, scope.handle, item)
        end
        acceptedUses[item], routedSpellDrops[item] = nil, nil
        report(runtime)
        return result
    end

    module.hooks.wrap("UseConsumableItem", "run-planner-path-use", function(_, runtime, base, item, args, user)
        if not pathNames[nativeName(item)] or nativeName(item) == "SpellDrop" then
            return base(item, args, user)
        end
        local scope = boundScope(room, getState(runtime), item, false)
        if scope == nil then
            scope = { state = getState(runtime), current = room.current(getState(runtime)), item = item }
        end
        acceptedUses[item] = scope
        scope.seaStar = seaStar.scope(scope.state, scope.handle and room.peek(scope.state, scope.handle) or nil)
        local ok, result = pcall(function()
            return seaStar.call(scope.seaStar, function() return base(item, args, user) end, session.mismatch)
        end)
        if acceptedUses[item] == scope then
            acceptedUses[item] = nil
            if scope.accepted and not scope.screenOpened then
                session.mismatch(scope.state, "path-talent-screen", "OpenTalentScreen", "missing")
            end
        end
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("ConsumableUsedPresentation", "run-planner-path-accepted", function(_, _, base,
        currentRun, item, args)
        local result = base(currentRun, item, args)
        local scope = acceptedUses[item]
        if scope ~= nil and result == false then
            acceptedUses[item] = nil
        elseif scope ~= nil then
            local claimed = scope.handle == nil and boundScope(room, scope.state, item, true) or scope
            if claimed == nil then
                acceptedUses[item] = nil
            else
                -- Keep the enclosing Sea Star scope alive: generated Talent
                -- claims occur here, but the native chance follows later in
                -- this same UseConsumableItem call.
                scope.handle, scope.current = claimed.handle, claimed.current
                scope.accepted = true
                seaStar.activate(scope.seaStar, room.peek(scope.state, scope.handle))
                acceptedUses[item] = scope
            end
        end
        return result
    end)

    module.hooks.wrap("OpenSpellScreen", "run-planner-aspect-path-route", function(_, runtime, base,
        spellItem, args, user)
        if nativeName(spellItem) ~= "SpellDrop" then return base(spellItem, args, user) end
        local scope = boundScope(room, getState(runtime), spellItem, true)
        if scope == nil then return base(spellItem, args, user) end
        routedSpellDrops[spellItem] = scope
        local ok, result = pcall(base, spellItem, args, user)
        if routedSpellDrops[spellItem] == scope then
            routedSpellDrops[spellItem] = nil
            if not scope.screenOpened then
                session.mismatch(scope.state, "aspect-path-screen", "OpenTalentScreen", "missing")
            end
        end
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("OpenTalentScreen", "run-planner-path-screen-return", function(_, runtime, base,
        args, spellItem, context)
        local scope = acceptedUses[spellItem] or routedSpellDrops[spellItem]
        if scope ~= nil and scope.accepted ~= true and routedSpellDrops[spellItem] == nil then
            return base(args, spellItem, context)
        end
        if scope == nil then return base(args, spellItem, context) end
        scope.screenOpened = true
        return completeAfterScreen(runtime, scope, base, args, spellItem, context)
    end)
end

return path
