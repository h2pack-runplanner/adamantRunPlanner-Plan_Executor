-- Private correlation index for published Timeline contacts. Hooks use only
-- descriptors through coordinator.lua; they never see these index namespaces.
local bindings = {}

local function add(index, namespace, key, transaction, detail)
    if key == nil then return true end
    local rows, prior = index[namespace], index[namespace][key]
    if prior ~= nil and prior.transaction ~= transaction then
        return nil, { checkpoint = "timeline-binding", expected = "unique " .. namespace, observed = key }
    end
    rows[key] = { transaction = transaction, detail = detail }
    return true
end

function bindings.index(occurrence)
    local index = {
        owner = {}, producer = {}, offer = {}, generation = {}, wellPurchase = {}, wellRefill = {}, source = {},
        slot = {}, keepsake = {}, automatic = {}, encounterInteraction = {}, interaction = {}, produced = {},
        materialized = {}, keepsakeReplay = {},
    }
    for owner, transaction in pairs(occurrence.transactionsByOwner or {}) do
        index.owner[owner] = { transaction = transaction }
        local ok, errorValue
        -- Well inventory has two distinct contacts for the same generated
        -- offer: realizing the refill and optionally purchasing the replacement
        -- item.  Their published generation/offer payload is intentionally the
        -- same, so keep those carriers in separate namespaces rather than
        -- making a same-contact refill impossible to bind.
        if transaction.kind == "wellPurchase" then
            ok, errorValue = add(index, "wellPurchase", transaction.generationKey, transaction)
            if not ok then return nil, errorValue end
        elseif transaction.kind == "wellRefill" then
            ok, errorValue = add(index, "wellRefill", transaction.generationKey, transaction)
            if not ok then return nil, errorValue end
        else
            ok, errorValue = add(index, "offer", transaction.offerKey, transaction)
            if not ok then return nil, errorValue end
            ok, errorValue = add(index, "generation", transaction.generationKey, transaction)
            if not ok then return nil, errorValue end
        end
        if transaction.kind == "encounterInteraction" then
            ok, errorValue = add(index, "encounterInteraction", transaction.phaseKey, transaction)
            if not ok then return nil, errorValue end
        end
        ok, errorValue = add(index, "source", transaction.sourceOwner, transaction)
        if not ok then return nil, errorValue end
        if transaction.producerLifecycleKey and transaction.reward then
            ok, errorValue = add(index, "producer",
                transaction.producerLifecycleKey .. "\0" .. transaction.reward.rewardType, transaction)
            if not ok then return nil, errorValue end
        end
        ok, errorValue = add(index, "slot", transaction.slotKey, transaction)
        if not ok then return nil, errorValue end
        if transaction.kind == "keepsakeChange" then
            ok, errorValue = add(index, "keepsake", transaction.keepsakeKey, transaction)
            if not ok then return nil, errorValue end
        elseif transaction.kind == "keepsakeReplay" then
            ok, errorValue = add(index, "keepsakeReplay", transaction.keepsakeKey, transaction)
            if not ok then return nil, errorValue end
        end
        ok, errorValue = add(index, "interaction", transaction.interactionKey, transaction)
        if not ok then return nil, errorValue end
        if transaction.kind == "automatic" then
            ok, errorValue = add(index, "automatic", transaction.effect .. "\0" .. transaction.phaseKey,
                transaction)
            if not ok then return nil, errorValue end
        end
        for _, role in ipairs(transaction.roles or {}) do
            if role.producer then
                ok, errorValue = add(index, "produced", role.producer.sourceOwner .. "\0" .. role.producer.sourceRole,
                    transaction, role)
                if not ok then return nil, errorValue end
            end
        end
    end
    return index
end

local function indexed(index, namespace, key)
    return index and index[namespace] and index[namespace][key] or nil
end

function bindings.resolve(index, contact, source)
    if type(contact) ~= "table" then
        return nil, { checkpoint = "timeline-contact", expected = "published contact descriptor", observed = contact }
    end
    if contact.kind == "offer" then return indexed(index, "offer", contact.offerKey)
    elseif contact.kind == "generation" then return indexed(index, "generation", contact.generationKey)
    elseif contact.kind == "wellPurchase" then return indexed(index, "wellPurchase", contact.generationKey)
    elseif contact.kind == "wellRefill" then return indexed(index, "wellRefill", contact.generationKey)
    elseif contact.kind == "source" then return indexed(index, "source", contact.sourceOwner)
    elseif contact.kind == "encounterInteraction" then
        return indexed(index, "encounterInteraction", contact.phaseKey)
    elseif contact.kind == "slot" then return indexed(index, "slot", contact.slotKey)
    elseif contact.kind == "keepsake" then return indexed(index, "keepsake", contact.keepsakeKey)
    elseif contact.kind == "keepsakeReplay" then
        return indexed(index, "keepsakeReplay", contact.keepsakeKey)
    elseif contact.kind == "interaction" then return indexed(index, "interaction", contact.interactionKey)
    elseif contact.kind == "automatic" then
        return indexed(index, "automatic", contact.effect .. "\0" .. contact.phaseKey)
    elseif contact.kind == "producer" then
        return indexed(index, "producer", contact.producerLifecycleKey .. "\0" .. contact.rewardType)
    elseif contact.kind == "produced" then
        local transaction = source and source.transaction
        if transaction == nil then return nil end
        return indexed(index, "produced", (transaction.sourceOwner or transaction.owner) .. "\0" .. contact.role)
    elseif contact.kind == "materialized" then
        local transaction = source and source.transaction
        if transaction == nil then return nil end
        local matching
        for _, role in ipairs(transaction.roles or {}) do
            if role.gameName == contact.gameName then
                if matching ~= nil then
                    return nil, {
                        checkpoint = "timeline-binding", expected = "one materialized role",
                        observed = contact.gameName,
                    }
                end
                matching = role
            end
        end
        if matching == nil then return nil end
        local key = transaction.owner .. "\0" .. matching.role .. "\0" .. matching.gameName
        local row = indexed(index, "materialized", key)
        if row == nil then
            row = { transaction = transaction, detail = matching }
            index.materialized[key] = row
        end
        return row
    end
    return nil, { checkpoint = "timeline-contact", expected = "published contact kind", observed = contact.kind }
end

function bindings.sourceRole(row, gameName)
    if row == nil or row.transaction == nil then return nil end
    if row.detail and row.detail.role then return row.detail.role end
    for _, role in ipairs(row.transaction.roles or {}) do
        if role.gameName == gameName then return role.role end
    end
    return nil
end

function bindings.payload(row)
    if row == nil then return nil end
    return { transaction = row.transaction, detail = row.detail }
end

return bindings
