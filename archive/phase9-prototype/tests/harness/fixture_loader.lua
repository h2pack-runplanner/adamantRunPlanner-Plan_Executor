-- Test-only loader for producer vectors. Runtime code never imports this file.

local json = require("mods/json")

local loader = {}
loader.fixtureDir = "archive/phase9-prototype/test/fixtures/profile-bundles"

local function quoteShell(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

local function manifest()
    local value, err = json.decode(read(loader.fixtureDir .. "/positive-vectors.json"))
    assert(value, err)
    return value
end

local function manifestEntry(name)
    for _, entry in ipairs(manifest().vectors) do
        if entry.name == name then return entry end
    end
    error("unknown positive fixture " .. tostring(name), 2)
end

local function manifestEntryByFile(fileName)
    for _, entry in ipairs(manifest().vectors) do
        if entry.file == fileName then return entry end
    end
    error("unknown positive fixture file " .. tostring(fileName), 2)
end

local function negativeManifest()
    local value, err = json.decode(read(loader.fixtureDir .. "/negative-vectors.json"))
    assert(value, err)
    return value
end

local function negativeEntry(name)
    for _, entry in ipairs(negativeManifest().vectors) do
        if entry.name == name then return entry end
    end
    error("unknown negative fixture " .. tostring(name), 2)
end

local function sha256(content)
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
    local process = assert(io.popen("sha256sum " .. quoteShell(path), "r"))
    local output = process:read("*l") or ""
    process:close()
    os.remove(path)
    return output:match("^(%x+)")
end

function loader.raw(name)
    local entry = manifestEntry(name)
    return loader.rawFile(entry.file), entry
end

function loader.rawFile(fileName)
    local entry = manifestEntryByFile(fileName)
    local path = loader.fixtureDir .. "/" .. entry.file
    local process = assert(io.popen("gzip -dc -- " .. quoteShell(path), "r"))
    local raw = process:read("*a")
    local ok, reason = process:close()
    assert(ok ~= false, reason or "gzip decompression failed")
    assert(#raw == entry.rawBytes,
        string.format("%s raw size changed: expected %d, got %d", fileName, entry.rawBytes, #raw))
    assert(sha256(raw) == entry.sha256, fileName .. " raw SHA-256 does not match manifest")
    return raw, entry
end

function loader.decode(name)
    local raw, entry = loader.raw(name)
    local value, err = json.decode(raw)
    assert(value, err)
    return value, entry
end

function loader.materializeMissingReference()
    local recipe = negativeEntry("missing-reference")
    local value = loader.decode(manifestEntryByFile(recipe.baseFile).name)
    local routeIndex = recipe.mutation.routeIndex + 1
    value.execution.routes[routeIndex].entryInstructionId = recipe.mutation.instructionId
    return value
end

function loader.materializeBoundedRead()
    local recipe = negativeEntry("bounded-size")
    local raw = loader.rawFile(recipe.baseFile)
    local limit = 1048576
    local targetSize = limit + recipe.mutation.excessBytes
    return raw .. string.rep(" ", targetSize - #raw), targetSize
end

return loader
