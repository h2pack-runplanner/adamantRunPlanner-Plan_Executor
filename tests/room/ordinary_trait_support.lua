local binding = require("mods.room.timeline.acquisitions.binding")
local seaStar = require("mods.room.timeline.acquisitions.sea_star").create()
local hooks = require("mods.room.timeline.acquisitions.traits.hooks")

local support = {}

function support.payload(offer, disposition)
    return { detail = { traitOffer = offer, disposition = disposition or "normal" }, transaction = {} }
end

function support.attached(offer, disposition, carrierName, adapters)
    local callbacks, bound, begins, completed, mismatches = {}, setmetatable({}, { __mode = "k" }), 0, 0, {}
    local activePayload
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    local producer, materialized = {}, {}
    local active = { occurrence = {
        overview = { incomingReward = { producerLifecycleKey = "incoming", rewardType = "Boon" } },
    } }
    local state = { state = "synchronized" }
    local function resolvedPayload()
        local value = support.payload(offer or { kind = "traits", selected = "option1", options = {
            { key = "ApolloAttack", rarity = "Rare" },
        } }, disposition)
        for key, nested in pairs((adapters and adapters.detail) or {}) do value.detail[key] = nested end
        return value
    end
    local room = {
        current = function() return active end,
        resolve = function(_, _, contact)
            if contact.kind == "producer" then return producer end
            if contact.kind == "materialized" and contact.source == producer
                and contact.gameName == (carrierName or "ApolloUpgrade") then return materialized end
            return nil
        end,
        bind = function(_, _, value, native) bound[native] = value; return value end,
        bound = function(_, _, native) return bound[native] end,
        peek = function(_, value)
            if value ~= materialized then return nil end
            if activePayload == nil then activePayload = resolvedPayload() end
            return activePayload
        end,
        begin = function(_, value)
            if state.state ~= "synchronized" then return nil end
            if value ~= materialized then return nil end
            begins = begins + 1
            if activePayload == nil then activePayload = resolvedPayload() end
            return activePayload
        end,
    }
    local session = {
        complete = function() completed = completed + 1 end,
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = { checkpoint = checkpoint, expected = expected, observed = observed }
        end,
    }
    binding.attach(module, session, function() return state end, function() end, room)
    local traitHooks = adapters and adapters.traits or hooks
    local seaStarAdapter = adapters and adapters.seaStar or seaStar
    traitHooks.attach(module, session, function() return state end, function() end, room, seaStarAdapter)
    if adapters and adapters.seaStar then seaStarAdapter.attach(module) end
    return callbacks, function() return begins end, function() return completed end,
        function() return mismatches end, function(value) active = value end
end

return support
