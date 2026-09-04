-- Producer-agnostic execution boundary for Mystery Box acquisitions. Native
-- use and trait effects remain authoritative; this adapter only claims an
-- accepted box, forces the published provider, and retains one owner handle.
local mystery = {}

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function nativeName(value)
    return type(value) == "table" and (value.Name or value.ItemName or value.LootName) or nil
end

local function lifecycleRole(payload, point)
    for _, role in ipairs(payload and payload.transaction and payload.transaction.roles or {}) do
        if role.lifecyclePoint == point then return role end
    end
    return nil
end

function mystery.attach(module, session, getState, report, room)
    local boxUses = setmetatable({}, { __mode = "k" })
    local unwrapScope

    module.hooks.wrap("CreateLoot", "run-planner-mystery-provider-bind", function(_, _, base, args)
        local result = base(args)
        local scope = unwrapScope
        if scope ~= nil and type(result) == "table"
            and nativeName(result) == scope.forcedName then
            if room.bind(scope.state, scope.current, scope.handle, result) == nil
                and type(session.mismatch) == "function" then
                session.mismatch(scope.state, "timeline-binding", "published Mystery provider", nativeName(result))
            end
        end
        return result
    end)

    local function boundScope(state, item)
        local current = room.current(state)
        local handle = current and room.bound(state, current, item) or nil
        local payload = handle and room.peek(state, handle) or nil
        local transaction = payload and payload.transaction
        local box
        for _, role in ipairs(transaction and transaction.roles or {}) do
            if role.role == "box" then box = role; break end
        end
        local hidden = lifecycleRole(payload, "afterUnwrap")
        if transaction == nil or box == nil or box.role ~= "box"
            or box.gameName ~= nativeName(item) or hidden == nil
            or hidden.role ~= "hiddenSource" or hidden.gameName == nil then
            return nil
        end
        return {
            state = state, current = current, handle = handle, item = item,
            payload = payload, accepted = false,
        }
    end

    local function acquisitionRole(transaction, contact)
        if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
        for _, role in ipairs(transaction.roles or {}) do
            if role.role == "box" and role.gameName == contact.gameName then
                return role
            end
        end
        return nil
    end

    module.hooks.wrap("UseConsumableItem", "run-planner-mystery-use", function(_, runtime, base,
        item, args, user)
        local state = getState(runtime)
        local scope = boundScope(state, item)
        if scope == nil and nativeName(item) == "BlindBoxLoot" then
            scope = { state = state, current = room.current(state), handle = nil,
                item = item, payload = nil, accepted = false }
        end
        if scope == nil then return base(item, args, user) end
        boxUses[item] = scope
        local ok, result = pcall(base, item, args, user)
        if not ok then
            boxUses[item] = nil
            error(result, 0)
        end
        if not scope.accepted then boxUses[item] = nil end
        if scope.accepted then report(runtime) end
        return result
    end)

    module.hooks.wrap("ConsumableUsedPresentation", "run-planner-mystery-accepted", function(_, _, base,
        currentRun, item, args)
        local result = base(currentRun, item, args)
        local scope = boxUses[item]
        if scope ~= nil and not scope.accepted and result ~= false then
            if scope.handle == nil and type(room.claimReady) == "function" then
                scope.handle, scope.payload = room.claimReady(scope.state, scope.current, {
                    kind = "mysteryBox", gameName = nativeName(item),
                }, item, acquisitionRole)
            end
            if scope.handle == nil then return result end
            scope.payload = room.begin(scope.state, scope.handle)
            if scope.payload ~= nil then scope.accepted = true end
        end
        return result
    end)

    module.hooks.wrap("UnwrapRandomLoot", "run-planner-mystery-unwrap", function(_, runtime, base, source)
        local scope = boxUses[source]
        if scope == nil or scope.payload == nil then return base(source) end
        local hidden = lifecycleRole(scope.payload, "afterUnwrap")
        if hidden == nil then return base(source) end
        local prior = unwrapScope
        unwrapScope = {
            state = scope.state, current = scope.current, handle = scope.handle,
            lifecyclePoint = "afterUnwrap", forcedName = hidden.gameName,
        }
        local ok, result = pcall(base, source)
        unwrapScope = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("GiveLoot", "run-planner-mystery-provider", function(_, _, base, args)
        if unwrapScope == nil or unwrapScope.forcedName == nil then return base(args) end
        local forcedArgs = copy(args)
        forcedArgs.ForceLootName = unwrapScope.forcedName
        return base(forcedArgs)
    end)
end

return mystery
