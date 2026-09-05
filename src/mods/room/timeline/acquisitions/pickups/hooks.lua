-- Exact-object lifecycle for acquisitions consumed directly from the world.
-- Native UseConsumableItem owns every effect; this adapter only recognizes an
-- accepted interaction and closes the published owner after native settlement.
local pickups = {}
local seaStar = type(import) == "function" and import("mods/room/timeline/acquisitions/sea_star.lua")
    or require("mods.room.timeline.acquisitions.sea_star")

local function detail(payload)
    return type(payload) == "table" and type(payload.detail) == "table" and payload.detail or nil
end

function pickups.isDirectCarrier(item, payload)
    local role = detail(payload)
    local transaction = type(payload) == "table" and payload.transaction or nil
    if role == nil or type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return false end
    if role.disposition ~= "normal" or (role.kind ~= "consumable" and role.kind ~= "resource") then
        return false
    end
    if role.traitOffer ~= nil or role.levelResolution ~= nil then return false end
    if type(item) ~= "table" or item.UseFunctionName ~= nil or item.ReplaceWithRandomLoot ~= nil then
        return false
    end
    return true
end

local function nativeName(item)
    return type(item) == "table" and (item.Name or item.ItemName or item.LootName) or nil
end

local function directPickupRole(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        if role.gameName == contact.gameName
            and role.disposition == "normal" and (role.kind == "consumable" or role.kind == "resource")
            and role.traitOffer == nil and role.levelResolution == nil then
            return role
        end
    end
    return nil
end

function pickups.attach(module, session, getState, report, room)
    local activeUses = setmetatable({}, { __mode = "k" })

    module.hooks.wrap("UseConsumableItem", "run-planner-direct-pickup-use", function(_, runtime, base,
        item, args, user)
        local state = getState(runtime)
        local current = room.current(state)
        local handle = current and room.bound(state, current, item) or nil
        local payload = handle and room.peek(state, handle) or nil
        if handle ~= nil and not pickups.isDirectCarrier(item, payload) then
            return base(item, args, user)
        end
        if handle == nil and (type(item) ~= "table" or item.UseFunctionName ~= nil
            or item.ReplaceWithRandomLoot ~= nil) then
            return base(item, args, user)
        end

        local scope = {
            state = state, current = current, handle = handle, item = item, accepted = false,
            seaStar = seaStar.scope(state, payload),
        }
        activeUses[item] = scope
        local ok, result = pcall(function()
            return seaStar.call(scope.seaStar, function() return base(item, args, user) end,
                session.mismatch)
        end)
        if activeUses[item] == scope then activeUses[item] = nil end
        if not ok then error(result, 0) end

        if scope.accepted then
            if scope.payload ~= nil then
                local expected = scope.payload.detail.gameName
                local observed = nativeName(item)
                if expected ~= observed then
                    session.mismatch(state, "direct-pickup", expected, observed)
                else
                    if seaStar.requireConsumed(scope.seaStar, session.mismatch) then
                        session.complete(state, scope.handle)
                        scope.completed = true
                    end
                    if scope.completed and scope.seaStar.result and scope.seaStar.result.kind == "proc" then
                        room.releaseCompletedBinding(state, scope.current, scope.handle, item)
                    end
                end
            end
            report(runtime)
        end
        return result
    end)

    module.hooks.wrap("ConsumableUsedPresentation", "run-planner-direct-pickup-accepted",
        function(_, _, base, currentRun, item, args)
            local result = base(currentRun, item, args)
            local scope = activeUses[item]
            if scope ~= nil and not scope.accepted and result ~= false then
                if scope.handle == nil and type(room.claimReady) == "function" then
                    local contact = {
                        kind = "directPickup", gameName = nativeName(item),
                    }
                    scope.handle, scope.payload = room.claimReady(scope.state, scope.current,
                        contact, item, directPickupRole)
                end
                if scope.handle == nil then return result end
                scope.accepted = true
                scope.payload = room.begin(scope.state, scope.handle)
                seaStar.activate(scope.seaStar, scope.payload)
            end
            return result
        end)
end

return pickups
