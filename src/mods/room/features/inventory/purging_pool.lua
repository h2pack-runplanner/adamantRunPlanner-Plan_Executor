-- Purging Pool menu steering over the native legal trait candidate set.
local poolInventory = {}

function poolInventory.steer(occurrence, nativeRoom)
    local pool = occurrence and occurrence.overview.purgingPool
    if pool == nil or not pool.interacted or type(nativeRoom) ~= "table" then return true end
    if type(nativeRoom.SellValues) ~= "table" then
        return nil, { checkpoint = "purging-pool-inventory", expected = "native SellValues", observed = nil }
    end
    local available = {}
    for key, option in pairs(nativeRoom.SellValues) do available[key] = option end
    -- GenerateSellTraitShop removes random selections from SellValues after
    -- placing them in SellOptions. Together they are one legal candidate set.
    for _, option in ipairs(nativeRoom.SellOptions or {}) do
        if type(option) == "table" and option.Name ~= nil then available[option.Name] = option end
    end
    local selected = {}
    for _, slot in ipairs(pool.traits or {}) do
        if slot.traitKey ~= nil then
            local option = available[slot.traitKey]
            if option == nil then
                return nil, { checkpoint = "purging-pool-inventory",
                    expected = slot.traitKey, observed = nil }
            end
            selected[#selected + 1] = option
        end
    end
    nativeRoom.SellOptions = selected
    return true
end

return poolInventory
