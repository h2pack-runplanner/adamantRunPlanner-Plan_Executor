local lu = require("luaunit")
local lfs = require("lfs")
local inbox = require("mods/inbox")
local protocol = require("mods/protocol")
local fixtures = require("tests/harness/fixture_loader")
local json = require("mods/json")

TestInbox = {}

local function temporaryDirectory()
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

local function removeDirectory(path)
    for filename in lfs.dir(path) do
        if filename ~= "." and filename ~= ".." then os.remove(path .. "/" .. filename) end
    end
    lfs.rmdir(path)
end

local pathApi = { combine = function(root, file) return root .. "/" .. file end }

local function decoder(raw)
    local value, errorMessage = json.decode(raw)
    if value == nil then return nil, "malformed-json: " .. tostring(errorMessage) end
    return protocol.decode(value)
end

function TestInbox.testOnlyTheBoundedFixedSlotIsRead()
    local root = temporaryDirectory()
    write(root .. "/other.json", fixtures.raw())
    write(root .. "/active.runplanner.json", fixtures.raw())
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertTrue(runtime.load())
    lu.assertEquals(runtime.status().slot, "present")
    write(root .. "/active.runplanner.json", string.rep("x", inbox.MAX_BYTES + 1))
    lu.assertFalse(runtime.load())
    lu.assertEquals(runtime.status().error.code, "plan-too-large")
    removeDirectory(root)
end

function TestInbox.testFreshReaderDoesNotInspectUntilAsked()
    local root = temporaryDirectory()
    write(root .. "/active.runplanner.json", fixtures.raw())
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertEquals(runtime.status().inspection, "not-inspected")
    lu.assertNil(runtime.plan())
    lu.assertTrue(runtime.load())
    lu.assertEquals(runtime.status().inspection, "inspected")
    removeDirectory(root)
end

function TestInbox.testMissingSlotIsInactiveAndDoesNotEnumerateAlternatives()
    local root = temporaryDirectory()
    write(root .. "/other.runplanner.json", fixtures.raw())
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertFalse(runtime.load())
    lu.assertEquals(runtime.status().error.code, "not-published")
    removeDirectory(root)
end

return TestInbox
