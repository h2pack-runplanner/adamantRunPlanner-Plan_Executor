--[[
  JSON decoder derived from rxi/json.lua v0.1.2.

  Upstream: https://github.com/rxi/json.lua/tree/v0.1.2
  Upstream license: MIT (Copyright (c) 2016 rxi).
  This module is intentionally decoder-only and keeps the upstream parser's
  small, dependency-free implementation style. The bounds and duplicate-key
  checks below are Plan Executor safety additions.

  MIT License

  Copyright (c) 2016 rxi

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
]]

local json = {}

-- Keep object/array identity explicit. Lua tables otherwise erase the JSON
-- distinction, which would let an array or null pass an object validator.
local objectMeta = { __json_object = true }
local arrayMeta = { __json_array = true }
local nullMeta = { __json_null = true }

json.null = setmetatable({}, nullMeta)

function json.isObject(value)
    local meta = type(value) == "table" and getmetatable(value) or nil
    return meta and meta.__json_object == true or false
end

function json.isArray(value)
    local meta = type(value) == "table" and getmetatable(value) or nil
    return meta and meta.__json_array == true or false
end

function json.isNull(value)
    local meta = type(value) == "table" and getmetatable(value) or nil
    return meta and meta.__json_null == true or false
end

local DEFAULT_MAX_DEPTH = 128
local DEFAULT_MAX_NODES = 250000

local function utf8(code)
    if code <= 0x7f then
        return string.char(code)
    elseif code <= 0x7ff then
        return string.char(0xc0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code <= 0xffff then
        return string.char(
            0xe0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40
        )
    elseif code <= 0x10ffff then
        return string.char(
            0xf0 + math.floor(code / 0x40000),
            0x80 + math.floor(code / 0x1000) % 0x40,
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40
        )
    end
    return nil
end

local function fail(state, message)
    error(string.format("json error at byte %d: %s", state.index, message), 0)
end

local function decodeString(state)
    local text = state.text
    local index = state.index + 1
    local start = index
    local chunks = {}
    local chunkStart = index
    while index <= state.length do
        local byte = string.byte(text, index)
        if byte == 0x22 then
            chunks[#chunks + 1] = string.sub(text, chunkStart, index - 1)
            state.index = index + 1
            return table.concat(chunks)
        elseif byte == 0x5c then
            chunks[#chunks + 1] = string.sub(text, chunkStart, index - 1)
            local escape = string.sub(text, index + 1, index + 1)
            local replacements = {
                ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
            }
            if replacements[escape] then
                chunks[#chunks + 1] = replacements[escape]
                index = index + 2
            elseif escape == "u" then
                local hex = string.sub(text, index + 2, index + 5)
                if not hex:match("^%x%x%x%x$") then
                    fail(state, "invalid unicode escape")
                end
                local code = tonumber(hex, 16)
                if code >= 0xd800 and code <= 0xdbff then
                    local nextEscape = string.sub(text, index + 6, index + 11)
                    local low = nextEscape:match("^\\u(%x%x%x%x)$")
                    if low then
                        local lowCode = tonumber(low, 16)
                        if lowCode >= 0xdc00 and lowCode <= 0xdfff then
                            code = 0x10000 + (code - 0xd800) * 0x400 + (lowCode - 0xdc00)
                            index = index + 6
                        else
                            fail(state, "invalid unicode surrogate")
                        end
                    else
                        fail(state, "missing unicode surrogate")
                    end
                elseif code >= 0xdc00 and code <= 0xdfff then
                    fail(state, "unexpected unicode surrogate")
                end
                local encoded = utf8(code)
                if not encoded then
                    fail(state, "invalid unicode code point")
                end
                chunks[#chunks + 1] = encoded
                index = index + 6
            else
                fail(state, "invalid escape")
            end
            chunkStart = index
        elseif byte < 0x20 then
            fail(state, "control character in string")
        else
            index = index + 1
        end
    end
    state.index = start
    fail(state, "unterminated string")
end

local parseValue

local function decodeArray(state, depth)
    state.index = state.index + 1
    local result = setmetatable({}, arrayMeta)
    local count = 0
    state.skipWhitespace()
    if string.sub(state.text, state.index, state.index) == "]" then
        state.index = state.index + 1
        return result
    end
    while true do
        count = count + 1
        if count > state.maxArray then
            fail(state, "array exceeds bound")
        end
        result[count] = parseValue(state, depth + 1)
        state.skipWhitespace()
        local separator = string.sub(state.text, state.index, state.index)
        if separator == "]" then
            state.index = state.index + 1
            return result
        elseif separator ~= "," then
            fail(state, "expected ',' or ']'")
        end
        state.index = state.index + 1
        state.skipWhitespace()
        if string.sub(state.text, state.index, state.index) == "]" then
            fail(state, "trailing comma")
        end
    end
end

local function decodeObject(state, depth)
    state.index = state.index + 1
    local result = setmetatable({}, objectMeta)
    local count = 0
    state.skipWhitespace()
    if string.sub(state.text, state.index, state.index) == "}" then
        state.index = state.index + 1
        return result
    end
    while true do
        count = count + 1
        if count > state.maxObject then
            fail(state, "object exceeds bound")
        end
        if string.sub(state.text, state.index, state.index) ~= '"' then
            fail(state, "object key must be a string")
        end
        local key = decodeString(state)
        if result[key] ~= nil then
            fail(state, "duplicate object key")
        end
        state.skipWhitespace()
        if string.sub(state.text, state.index, state.index) ~= ":" then
            fail(state, "expected ':'")
        end
        state.index = state.index + 1
        state.skipWhitespace()
        result[key] = parseValue(state, depth + 1)
        state.skipWhitespace()
        local separator = string.sub(state.text, state.index, state.index)
        if separator == "}" then
            state.index = state.index + 1
            return result
        elseif separator ~= "," then
            fail(state, "expected ',' or '}'")
        end
        state.index = state.index + 1
        state.skipWhitespace()
        if string.sub(state.text, state.index, state.index) == "}" then
            fail(state, "trailing comma")
        end
    end
end

local function decodeNumber(state)
    local remaining = string.sub(state.text, state.index)
    local integerPart = remaining:match("^(%-?%d+)")
    if not integerPart then
        fail(state, "invalid number")
    end
    local unsignedInteger = integerPart:gsub("^-", "")
    if #unsignedInteger > 1 and unsignedInteger:sub(1, 1) == "0" then
        fail(state, "leading zero in number")
    end
    local suffix = string.sub(remaining, #integerPart + 1)
    local fraction = ""
    if suffix:sub(1, 1) == "." then
        fraction = suffix:match("^(%.%d+)")
        if not fraction then
            fail(state, "invalid fractional number")
        end
        suffix = suffix:sub(#fraction + 1)
    end
    local exponent = ""
    if suffix:sub(1, 1) == "e" or suffix:sub(1, 1) == "E" then
        exponent = suffix:match("^([eE][+-]?%d+)")
        if not exponent then
            fail(state, "invalid exponent")
        end
    end
    local token = integerPart .. fraction .. exponent
    local nextByte = string.byte(remaining, #token + 1)
    if nextByte and ((nextByte >= 0x30 and nextByte <= 0x39)
        or (nextByte >= 0x41 and nextByte <= 0x5a)
        or (nextByte >= 0x61 and nextByte <= 0x7a)
        or nextByte == 0x2e or nextByte == 0x2b or nextByte == 0x2d or nextByte == 0x5f) then
        fail(state, "invalid number")
    end
    state.index = state.index + #token
    local value = tonumber(token)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        fail(state, "number is not finite")
    end
    return value
end

parseValue = function(state, depth)
    if depth > state.maxDepth then
        fail(state, "maximum nesting depth exceeded")
    end
    state.nodes = state.nodes + 1
    if state.nodes > state.maxNodes then
        fail(state, "value count exceeds bound")
    end
    state.skipWhitespace()
    local byte = string.byte(state.text, state.index)
    if byte == 0x22 then
        return decodeString(state)
    elseif byte == 0x7b then
        return decodeObject(state, depth)
    elseif byte == 0x5b then
        return decodeArray(state, depth)
    elseif byte == 0x2d or (byte and byte >= 0x30 and byte <= 0x39) then
        return decodeNumber(state)
    elseif string.sub(state.text, state.index, state.index + 3) == "true" then
        state.index = state.index + 4
        return true
    elseif string.sub(state.text, state.index, state.index + 4) == "false" then
        state.index = state.index + 5
        return false
    elseif string.sub(state.text, state.index, state.index + 3) == "null" then
        state.index = state.index + 4
        return json.null
    end
    fail(state, "unexpected value")
end

function json.decode(text, opts)
    if type(text) ~= "string" then
        return nil, "json input must be a string"
    end
    opts = opts or {}
    local state = {
        text = text,
        index = 1,
        length = #text,
        maxDepth = opts.maxDepth or DEFAULT_MAX_DEPTH,
        maxNodes = opts.maxNodes or DEFAULT_MAX_NODES,
        maxArray = opts.maxArray or 100000,
        maxObject = opts.maxObject or 100000,
        nodes = 0,
    }
    function state.skipWhitespace()
        while state.index <= state.length do
            local byte = string.byte(state.text, state.index)
            if byte == 0x20 or byte == 0x09 or byte == 0x0a or byte == 0x0d then
                state.index = state.index + 1
            else
                return
            end
        end
    end
    local ok, value = pcall(parseValue, state, 0)
    if not ok then
        return nil, value
    end
    state.skipWhitespace()
    if state.index <= state.length then
        return nil, string.format("json error at byte %d: trailing data", state.index)
    end
    return value
end

return json
