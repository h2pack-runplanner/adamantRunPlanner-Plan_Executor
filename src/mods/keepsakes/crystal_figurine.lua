-- Native Arcana result selection shared by Judgment and Crystal Figurine.
-- Boss lifecycle and phase resolution remain owned by encounters/boss.lua;
-- this module only owns the bounded result queue consumed by native callbacks.
local figurine = {}

local function contains(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then return true end
    end
    return false
end

function figurine.begin(transaction)
    local keys = transaction.arcanaKeys or {}
    return {
        keys = keys,
        index = 1,
        admitCastCount = contains(keys, "CastCount"),
    }
end

function figurine.admitCastCount(queue)
    if queue and queue.admitCastCount and not queue.castCountAdmissionConsumed and queue.index == 1 then
        queue.castCountAdmissionConsumed = true
        return true
    end
    return nil
end

function figurine.select(queue, values)
    if queue and queue.keys[queue.index] then
        local key = queue.keys[queue.index]
        for index, value in ipairs(values or {}) do
            if value == key then
                table.remove(values, index)
                queue.index = queue.index + 1
                return value
            end
        end
    end
    return nil
end

function figurine.complete(queue)
    return queue ~= nil and queue.index > #(queue.keys or {})
end

return figurine
