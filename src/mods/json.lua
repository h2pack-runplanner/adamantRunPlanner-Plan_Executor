-- Small bounded JSON decoder used only at the fixed execution-plan boundary.
-- It returns tagged tables so protocol validation can distinguish arrays and
-- objects without accepting Lua tables produced by arbitrary callers.

local json = {}
local null = setmetatable({}, { __json_null = true })

local function fail(message)
    return nil, message
end

local function whitespace(source, index)
    local nextIndex = index
    while true do
        local character = source:sub(nextIndex, nextIndex)
        if character ~= " " and character ~= "\t" and character ~= "\r" and character ~= "\n" then
            return nextIndex
        end
        nextIndex = nextIndex + 1
    end
end

local function decodeString(source, index)
    local output = {}
    local nextIndex = index + 1
    while nextIndex <= #source do
        local character = source:sub(nextIndex, nextIndex)
        if character == '"' then return table.concat(output), nextIndex + 1 end
        if character == "\\" then
            local escaped = source:sub(nextIndex + 1, nextIndex + 1)
            local replacements = {
                ['"'] = '"', ['\\'] = "\\", ['/'] = '/', b = "\b", f = "\f",
                n = "\n", r = "\r", t = "\t",
            }
            if escaped == "u" then
                local digits = source:sub(nextIndex + 2, nextIndex + 5)
                if not digits:match("^%x%x%x%x$") then return fail("invalid unicode escape") end
                local code = tonumber(digits, 16)
                if code > 127 then return fail("non-ascii unicode escapes are unsupported") end
                output[#output + 1] = string.char(code)
                nextIndex = nextIndex + 6
            elseif replacements[escaped] ~= nil then
                output[#output + 1] = replacements[escaped]
                nextIndex = nextIndex + 2
            else
                return fail("invalid string escape")
            end
        else
            if character:byte() < 32 then return fail("unescaped control character") end
            output[#output + 1] = character
            nextIndex = nextIndex + 1
        end
    end
    return fail("unterminated string")
end

local function decodeValue(source, index)
    index = whitespace(source, index)
    local character = source:sub(index, index)
    if character == '"' then return decodeString(source, index) end
    if character == "{" then
        local value = setmetatable({}, { __json_object = true })
        local nextIndex = whitespace(source, index + 1)
        if source:sub(nextIndex, nextIndex) == "}" then return value, nextIndex + 1 end
        while true do
            if source:sub(nextIndex, nextIndex) ~= '"' then return fail("object key must be a string") end
            local key, afterKey = decodeString(source, nextIndex)
            if key == nil then return nil, afterKey end
            nextIndex = whitespace(source, afterKey)
            if source:sub(nextIndex, nextIndex) ~= ":" then return fail("object key missing colon") end
            local item, afterItem = decodeValue(source, nextIndex + 1)
            if item == nil then return nil, afterItem end
            if value[key] ~= nil then return fail("duplicate object key") end
            value[key] = item
            nextIndex = whitespace(source, afterItem)
            local separator = source:sub(nextIndex, nextIndex)
            if separator == "}" then return value, nextIndex + 1 end
            if separator ~= "," then return fail("object missing separator") end
            nextIndex = whitespace(source, nextIndex + 1)
        end
    end
    if character == "[" then
        local value = setmetatable({}, { __json_array = true })
        local nextIndex = whitespace(source, index + 1)
        if source:sub(nextIndex, nextIndex) == "]" then return value, nextIndex + 1 end
        while true do
            local item, afterItem = decodeValue(source, nextIndex)
            if item == nil then return nil, afterItem end
            value[#value + 1] = item
            nextIndex = whitespace(source, afterItem)
            local separator = source:sub(nextIndex, nextIndex)
            if separator == "]" then return value, nextIndex + 1 end
            if separator ~= "," then return fail("array missing separator") end
            nextIndex = whitespace(source, nextIndex + 1)
        end
    end
    local token = source:sub(index):match("^[%-%+%d%.eE]+")
    if token ~= nil then
        local cursor = 1
        local function isDigit(digitCharacter)
            return digitCharacter ~= "" and digitCharacter:match("^%d$") ~= nil
        end
        if token:sub(cursor, cursor) == "-" then cursor = cursor + 1 end
        local first = token:sub(cursor, cursor)
        if first == "0" then
            cursor = cursor + 1
            if isDigit(token:sub(cursor, cursor)) then return fail("invalid number") end
        elseif first:match("^[1-9]$") ~= nil then
            cursor = cursor + 1
            while isDigit(token:sub(cursor, cursor)) do cursor = cursor + 1 end
        else
            return fail("invalid number")
        end
        if token:sub(cursor, cursor) == "." then
            cursor = cursor + 1
            if not isDigit(token:sub(cursor, cursor)) then return fail("invalid number") end
            while isDigit(token:sub(cursor, cursor)) do cursor = cursor + 1 end
        end
        local exponent = token:sub(cursor, cursor)
        if exponent == "e" or exponent == "E" then
            cursor = cursor + 1
            local sign = token:sub(cursor, cursor)
            if sign == "+" or sign == "-" then cursor = cursor + 1 end
            if not isDigit(token:sub(cursor, cursor)) then return fail("invalid number") end
            while isDigit(token:sub(cursor, cursor)) do cursor = cursor + 1 end
        end
        if cursor <= #token then return fail("invalid number") end
        local number = tonumber(token)
        if number == nil or number ~= number or number == math.huge or number == -math.huge then
            return fail("invalid number")
        end
        return number, index + #token
    end
    if source:sub(index, index + 3) == "true" then return true, index + 4 end
    if source:sub(index, index + 4) == "false" then return false, index + 5 end
    if source:sub(index, index + 3) == "null" then return null, index + 4 end
    return fail("unexpected JSON value")
end

function json.decode(source)
    if type(source) ~= "string" then return fail("JSON input must be a string") end
    local value, nextIndex = decodeValue(source, 1)
    if value == nil then return nil, nextIndex end
    nextIndex = whitespace(source, nextIndex)
    if nextIndex <= #source then return fail("trailing JSON data") end
    return value
end

json.null = null
json.isObject = function(value)
    local meta = type(value) == "table" and getmetatable(value) or nil
    return meta ~= nil and meta.__json_object == true
end
json.isArray = function(value)
    local meta = type(value) == "table" and getmetatable(value) or nil
    return meta ~= nil and meta.__json_array == true
end
json.isNull = function(value) return value == null end

return json
