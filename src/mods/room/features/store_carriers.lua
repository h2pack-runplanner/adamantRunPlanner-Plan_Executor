-- Native Store carrier operations shared by inventory generation and the
-- later Timeline interaction that acquires one generated item.
local carriers = {}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, nested in pairs(value) do result[key] = copy(nested) end
    return result
end

local function carrier(key)
    local traits = _G.TraitData or {}
    local consumables = _G.ConsumableData or {}
    if traits[key] ~= nil then return traits[key], "Trait" end
    if consumables[key] ~= nil then return consumables[key], "Consumable" end
    return nil
end

function carriers.eligible(key, args, purchase)
    local data, kind = carrier(key)
    if data == nil then return false end
    if kind == "Trait" then
        return _G.IsTraitEligible(data, args) == true
    end
    if not _G.StoreItemEligible(data, args or {}) then
        return false
    end
    return not purchase or data.PurchaseRequirements == nil
        or _G.IsGameStateEligible(data, data.PurchaseRequirements) == true
end

local function availableIn(value, key, seen)
    if type(value) ~= "table" then return value == key end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    if value.Name == key or value.ItemName == key then return true end
    for _, nested in pairs(value) do if availableIn(nested, key, seen) then return true end end
    return false
end

local function namedEntry(value, key, seen)
    if type(value) ~= "table" then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    if value.Name == key or value.ItemName == key then return value end
    for _, nested in pairs(value) do
        local found = namedEntry(nested, key, seen)
        if found ~= nil then return found end
    end
    return nil
end

function carriers.available(storeData, key, args)
    if not availableIn(storeData, key) then return false end
    local entry = namedEntry(storeData, key)
    if entry and entry.AdditionalRequirements
        and not _G.IsGameStateEligible(entry, entry.AdditionalRequirements) then return false end
    if entry and entry.ReplaceRequirements then
        return _G.IsGameStateEligible(entry, entry.ReplaceRequirements) == true
    end
    if entry and entry.SkipRequirements then return true end
    return carriers.eligible(key, args, false)
end

function carriers.materialize(item, key)
    local data, kind = carrier(key)
    if type(item) ~= "table" or data == nil then return nil end
    local retained = {
        __runPlannerOfferKey = item.__runPlannerOfferKey,
        __runPlannerGenerationKey = item.__runPlannerGenerationKey,
        __runPlannerTwistResultKey = item.__runPlannerTwistResultKey,
        Index = item.Index, ObjectId = item.ObjectId,
    }
    for field in pairs(item) do item[field] = nil end
    for field, value in pairs(data) do item[field] = copy(value) end
    item.Name, item.Type = key, kind
    for field, value in pairs(retained) do if value ~= nil then item[field] = value end end
    return item
end

return carriers
