local navigation = require("mods.navigation.hooks")
local featureInventory = require("mods.room.features.inventory.attach")
local commerceHooks = require("mods.room.timeline.commerce.hooks")
local interactionHooks = require("mods.room.timeline.interactions.hooks")

local M = {}

function M.capture()
    local names, callbacks = {}, {}
    return {
        hooks = {
            wrap = function(name, id, callback)
                names[name] = names[name] or {}
                names[name][id] = true
                callbacks[name] = callback
            end,
        },
    }, names, callbacks
end

local fakePayloads = setmetatable({}, { __mode = "k" })
local fakeHandles = setmetatable({}, { __mode = "k" })

local function fakeHandle(row)
    if row == nil or fakePayloads[row] ~= nil then return row end
    local handle = fakeHandles[row]
    if handle == nil then
        handle = {}
        fakeHandles[row] = handle
        fakePayloads[handle] = {
            transaction = row.transaction,
            detail = row.detail,
        }
    end
    return handle
end

function M.fakePayload(handle)
    return fakePayloads[handle]
end

function M.stub()
    return {
        current = function() end,
        expectedOccurrence = function() end,
        proveOverview = function() end,
        additionalRoom = function() end,
        feature = function() end,
        mismatch = function() end,
        bound = function(_, context, native)
            return context and context.bound and context.bound(native) or nil
        end,
        sourceRole = function(_, context, handle, gameName)
            return context and context.sourceRole and context.sourceRole(M.fakePayload(handle), gameName) or nil
        end,
        resolve = function(_, context, contact)
            return context and context.resolve and context.resolve(contact) or nil
        end,
        bind = function(_, context, handle, native)
            return context and context.bind and context.bind(handle, native) or handle
        end,
        begin = function(_, handle)
            return M.fakePayload(handle)
        end,
        activePhase = function() return nil end,
        peek = function(_, handle) return M.fakePayload(handle) end,
    }
end

-- This composition harness intentionally knows no Timeline contact namespaces.
-- Each witness supplies its one expected opaque handle relation explicitly.
function M.opaque(active, resolve, initial)
    local native = {}
    for value, handle in pairs(initial or {}) do native[value] = fakeHandle(handle) end
    active.resolve = function(contact)
        local forwarded = contact
        if contact and contact.source then
            forwarded = {}
            for key, value in pairs(contact) do forwarded[key] = value end
            forwarded.source = M.fakePayload(contact.source)
        end
        return fakeHandle(resolve(forwarded))
    end
    active.bound = function(value) return native[value] end
    active.bind = function(handle, value)
        handle = fakeHandle(handle)
        if handle ~= nil and value ~= nil then native[value] = handle end
        return handle
    end
    active.sourceRole = function(payload, gameName)
        for _, role in ipairs(payload and payload.transaction and payload.transaction.roles or {}) do
            if role.gameName == gameName then return role.role end
        end
    end
    active.bindingFor = function(value) return native[value] end
    return active
end

M.navigationEntryStub = {
    realizeIncomingReward = function(_, nativeRoom) return nativeRoom end,
    proveIncomingReward = function() return true end,
}

function M.attachRewardHooks(module, session, getState, report)
    navigation.attach(module, session, getState, report,
        { reportDestination = function() return true end }, session)
end

function M.attachFeatureHooks(module, session, getState, report, room, route)
    local inventoryBindings = featureInventory.attach(module, session, getState, report, room, route)
    commerceHooks.attach(module, session, getState, report, room, inventoryBindings)
    interactionHooks.attach(module, session, getState, report, room)
    return inventoryBindings
end

return M
