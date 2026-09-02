-- Closed-shape primitives shared by the v10 fact-family decoders.
local json = type(import) == "function" and import("mods/json.lua") or require("mods/json")

local primitives = { MAX_ITEMS = 256, MAX_STRING = 512, json = json }

function primitives.fail(message) return nil, message end
function primitives.obj(value, label)
    if not json.isObject(value) then return primitives.fail(label .. " must be an object") end
    return value
end
function primitives.arr(value, label, max)
    if not json.isArray(value) or #value > (max or primitives.MAX_ITEMS) then
        return primitives.fail(label .. " must be a bounded array")
    end
    return value
end
function primitives.str(value, label, max)
    if type(value) ~= "string" or value == "" or #value > (max or primitives.MAX_STRING) then
        return primitives.fail(label .. " must be a bounded non-empty string")
    end
    return value
end
function primitives.num(value, label, min)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
        or (min and value < min) then return primitives.fail(label .. " must be finite") end
    return value
end
function primitives.int(value, label, min)
    if not primitives.num(value, label, min) or value ~= math.floor(value) then
        return primitives.fail(label .. " must be an integer")
    end
    return value
end
function primitives.bool(value, label)
    if type(value) ~= "boolean" then return primitives.fail(label .. " must be a boolean") end
    return true
end
function primitives.exact(value, required, optional, label)
    local record, errorMessage = primitives.obj(value, label)
    if not record then return nil, errorMessage end
    local allowed = {}
    for _, key in ipairs(required) do
        allowed[key] = true
        if value[key] == nil then return primitives.fail(label .. " is missing " .. key) end
    end
    for _, key in ipairs(optional or {}) do allowed[key] = true end
    for key in pairs(value) do
        if not allowed[key] then return primitives.fail(label .. " has unknown field " .. tostring(key)) end
    end
    return value
end
function primitives.one(value, allowed, label)
    if not allowed[value] then return primitives.fail(label .. " is unsupported") end
    return value
end
function primitives.strings(value, label, max)
    local items, errorMessage = primitives.arr(value, label, max)
    if not items then return nil, errorMessage end
    for index, item in ipairs(items) do
        if not primitives.str(item, label .. "[" .. index .. "]") then return nil, "invalid string" end
    end
    return items
end
function primitives.recordNumbers(value, label)
    local record, errorMessage = primitives.obj(value, label)
    if not record then return nil, errorMessage end
    for key, item in pairs(record) do
        if not primitives.str(key, label .. " key") or not primitives.num(item, label .. "." .. key) then
            return nil, label .. " has invalid number"
        end
    end
    return record
end
function primitives.roomRef(value, label)
    local record = primitives.exact(value, { "id", "biomeKey", "gameName" }, {}, label)
    if not record
        or not primitives.str(record.id, label, 256)
        or not primitives.str(record.biomeKey, label)
        or not primitives.str(record.gameName, label) then
        return primitives.fail(label .. " malformed room reference")
    end
    return record
end
local function stable(value)
    if json.isNull(value) then return "null" end
    if type(value) == "string" then return string.format("%q", value):gsub("\\\n", "\\n") end
    if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
    if json.isArray(value) then
        local parts = {}; for index, item in ipairs(value) do parts[index] = stable(item) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end; table.sort(keys)
    for index, key in ipairs(keys) do keys[index] = stable(key) .. ":" .. stable(value[key]) end
    return "{" .. table.concat(keys, ",") .. "}"
end
function primitives.fingerprint(value)
    local text, hash = stable(value), 2166136261
    for index = 1, #text do
        hash = bit32.bxor(hash, text:byte(index))
        local low, high = hash % 65536, math.floor(hash / 65536)
        hash = (low * 403 + ((low * 256 + high * 403) % 65536) * 65536) % 4294967296
    end
    return string.format("%08x", hash)
end
return primitives
