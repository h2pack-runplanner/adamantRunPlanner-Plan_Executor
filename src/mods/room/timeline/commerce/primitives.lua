-- Shared mechanics for Timeline-owned commerce contacts.
local primitives = {}

function primitives.shopBinding(payload, bindingKey)
    local transaction = payload and payload.transaction
    if transaction == nil or transaction.kind ~= "shopPurchase" then return false end
    -- The authored offer slot and materialized carrier can have different
    -- native identities (for example BlindBoxLoot carries a Boon offer).
    return transaction.offerKey == bindingKey
end

function primitives.completesAtPurchase(node)
    if node and node.anvilResult ~= nil then return false end
    if node and node.twistResultKey ~= nil then return false end
    for _, role in ipairs(node and node.roles or {}) do
        if role.lifecyclePoint ~= "purchase" or role.traitOffer ~= nil or role.levelResolution ~= nil then
            return false
        end
    end
    return true
end

function primitives.materializedHandle(state, active, room, root, itemKey)
    if root == nil or itemKey == nil then return root end
    return room.resolve(state, active, {
        kind = "materialized", source = root, gameName = itemKey,
    }) or root
end

function primitives.storeButtonIndex(button, item)
    if type(button) == "table" and type(button.Index) == "number" then return button.Index end
    if type(item) == "table" and type(item.Index) == "number" then return item.Index end
    local options = _G.CurrentRun and _G.CurrentRun.CurrentRoom
        and _G.CurrentRun.CurrentRoom.Store and _G.CurrentRun.CurrentRoom.Store.StoreOptions
    for index, option in pairs(options or {}) do
        if option == item then return index end
    end
    return nil
end

return primitives
