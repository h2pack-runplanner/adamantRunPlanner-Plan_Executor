-- luacheck: globals TestInbox

local lu = require("luaunit")
local lfs = require("lfs")
local json = require("mods/json")
local protocol = require("mods/protocol")
local inbox = require("mods/inbox")
local fixtures = require("tests/harness/fixture_loader")

TestInbox = {}

local function makeTempDir()
    local path = os.tmpname()
    os.remove(path)
    assert(lfs.mkdir(path))
    return path
end

local function write(path, content)
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
end

local function decoder(raw)
    local value, jsonError = json.decode(raw)
    if not value then return nil, "malformed-json: " .. tostring(jsonError) end
    return protocol.decode(value)
end

local pathApi = {
    combine = function(root, filename)
        return root .. "/" .. filename
    end,
}

local function cleanup(path)
    for filename in lfs.dir(path) do
        if filename ~= "." and filename ~= ".." then os.remove(path .. "/" .. filename) end
    end
    lfs.rmdir(path)
end

function TestInbox.testOnlyTheFixedActiveSlotIsRead()
    local root = makeTempDir()
    write(root .. "/other.runplanner.json", "{}")
    write(root .. "/active.runplanner.json.gz", "gzip")
    assert(lfs.mkdir(root .. "/nested"))
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertFalse(runtime.load())
    lu.assertEquals(runtime.status().slot, "not-published")
    write(root .. "/active.runplanner.json", fixtures.raw("representative-f"))
    lu.assertTrue(runtime.load())
    lu.assertEquals(runtime.status().slot, "present")
    lfs.rmdir(root .. "/nested")
    cleanup(root)
end

function TestInbox.testReaderResolvesRootAndFixedSlotThroughRuntimePathApi()
    local root = makeTempDir()
    local seen
    local raw = fixtures.raw("representative-f")
    write(root .. "/active.runplanner.json", raw)
    local readerPathApi = { combine = function(folder, filename)
        seen = { folder, filename }
        return folder .. "/" .. filename
    end }
    local received = assert(inbox.readBinary(root, readerPathApi))
    lu.assertEquals(received, raw)
    lu.assertEquals(seen, { root, "active.runplanner.json" })
    cleanup(root)
end

function TestInbox.testProductionReaderHasNoLfsOrDirectoryDiscoveryDependency()
    local file = assert(io.open("src/mods/inbox.lua", "rb"))
    local source = file:read("*a")
    file:close()
    lu.assertNil(source:find("require%(", 1, false))
    lu.assertNil(source:find("lfs", 1, true))
    lu.assertNil(source:find("%.dir", 1, false))
    lu.assertNotNil(source:find('ACTIVE_SLOT = "active.runplanner.json"', 1, true))
end

function TestInbox.testFailedLoadDoesNotRetainPriorPlan()
    local root = makeTempDir()
    write(root .. "/active.runplanner.json", fixtures.raw("representative-f"))
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertTrue(runtime.load())
    lu.assertNotNil(runtime.plan())
    local status = runtime.status()
    lu.assertEquals(status.protocol, "ready")
    lu.assertEquals(status.routeAvailability, "Underworld")
    write(root .. "/active.runplanner.json", "{}")
    lu.assertFalse(runtime.load())
    lu.assertNil(runtime.plan())
    lu.assertEquals(runtime.status().protocol, "error")
    cleanup(root)
end

function TestInbox.testProjectOnlyIsExplicitlyInactive()
    local root = makeTempDir()
    write(root .. "/active.runplanner.json", fixtures.raw("project-only"))
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertTrue(runtime.load())
    local status = runtime.status()
    lu.assertEquals(status.protocol, "project-only")
    lu.assertEquals(status.routeAvailability, "none")
    cleanup(root)
end

function TestInbox.testLargestPositivePassesAndBoundedRecipeFailsBeforeDecode()
    local root = makeTempDir()
    local raw = fixtures.raw("two-route-stress")
    write(root .. "/active.runplanner.json", raw)
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertTrue(runtime.load())
    local bounded, expectedSize = fixtures.materializeBoundedRead()
    lu.assertEquals(#bounded, expectedSize)
    write(root .. "/active.runplanner.json", bounded)
    lu.assertFalse(runtime.load())
    lu.assertEquals(runtime.status().error.code, "bundle-too-large")
    cleanup(root)
end

return TestInbox
