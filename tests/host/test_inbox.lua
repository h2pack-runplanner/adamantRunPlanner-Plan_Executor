local lu = require("luaunit")
local lfs = require("lfs")
local inbox = require("mods/host/inbox")
local protocol = require("mods.protocol.decoder")
local fixtures = require("tests/harness/fixture_loader")
local json = require("mods/protocol/json")

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

function TestInbox.testOnlyTheSelectedFixedSlotIsRead()
    local root = temporaryDirectory()
    write(root .. "/other.json", fixtures.raw())
    write(root .. "/slot-1.runplanner.json", fixtures.raw())
    write(root .. "/slot-2.runplanner.json", fixtures.raw())
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertEquals(runtime.activeSlot(), 1)
    lu.assertTrue(runtime.load(2))
    lu.assertEquals(runtime.status().slot, 2)
    lu.assertEquals(runtime.status().file, "present")
    write(root .. "/slot-2.runplanner.json", string.rep("x", inbox.MAX_BYTES + 1))
    lu.assertFalse(runtime.load())
    lu.assertEquals(runtime.status().error.code, "plan-too-large")
    lu.assertFalse(runtime.load(7))
    lu.assertEquals(runtime.status().error.code, "invalid-slot")
    removeDirectory(root)
end

function TestInbox.testFreshReaderDoesNotInspectUntilAsked()
    local root = temporaryDirectory()
    write(root .. "/slot-1.runplanner.json", fixtures.raw())
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertEquals(runtime.status().inspection, "not-inspected")
    lu.assertNil(runtime.plan())
    lu.assertTrue(runtime.load())
    lu.assertEquals(runtime.status().inspection, "inspected")
    removeDirectory(root)
end

function TestInbox.testMissingSlotIsInactiveAndDoesNotEnumerateAlternatives()
    local root = temporaryDirectory()
    write(root .. "/slot-2.runplanner.json", fixtures.raw())
    local runtime = inbox.create(root, decoder, pathApi)
    lu.assertFalse(runtime.load())
    lu.assertEquals(runtime.status().error.code, "not-published")
    lu.assertEquals(runtime.status().error.message, "published plan slot 1 is not present")
    removeDirectory(root)
end

function TestInbox.testMalformedPlanRetainsTheDecoderReason()
    local root = temporaryDirectory()
    write(root .. "/slot-3.runplanner.json", "not a plan")
    local runtime = inbox.create(root, function() return nil, "specific decoder rejection" end, pathApi)
    lu.assertFalse(runtime.load(3))
    lu.assertEquals(runtime.status().error, {
        code = "malformed-plan",
        message = "specific decoder rejection",
    })
    removeDirectory(root)
end

function TestInbox.testAllSixSlotsUseTheClosedFileMapping()
    for slot = 1, inbox.SLOT_COUNT do
        lu.assertEquals(inbox.slotFileName(slot), "slot-" .. tostring(slot) .. ".runplanner.json")
    end
    lu.assertNil(inbox.slotFileName(0))
    lu.assertNil(inbox.slotFileName(7))
    lu.assertNil(inbox.slotFileName(1.5))
end

return TestInbox
